import AppKit
import AVFoundation
import Metal
import QuartzCore
import AetherEngine

// HDR Colors = Specular (docs/tasks/bright-mode.md): Specular draws HDR itself, the way IINA does.
// AVPlayer keeps playing (clock, audio, seeks); an AVPlayerItemVideoOutput hands us its decoded 10-bit
// frames, AVPlayer's own picture is suppressed, and a Metal layer shows the PQ values in an EDR layer
// (itur_2100_PQ, RGBA16Float). Same pattern as AetherEngine's DualLayerOutputRoute, all public API.
// An output on the item also switches Apple's Dolby Vision processing off, which is what this mode wants:
// Profile 8.1 / 7 MEL show their base layer (identity reshaping on the files measured).

/// Which HDR path a film takes (bright-mode / settings-v2 routing table).
enum HDRRoute: Equatable {
    case apple, specular
    /// `xdr`: the screen's potential EDR headroom is about 8x or more (MacBook Pro XDR, Pro Display XDR).
    static func decide(hdrColors: String, format: VideoFormat, dvProfile: Int?, dolbyVision: Bool, xdr: Bool) -> HDRRoute {
        guard hdrColors == "specular" else { return .apple }
        switch format {
        case .hdr10, .hdr10Plus: return .specular
        case .dolbyVision:
            if dvProfile == 5 { return .apple }                        // IPT: needs Dolby reshaping
            if dolbyVision && xdr { return .apple }                    // the panel fits the master: Apple's Dolby Vision
            return .specular                                           // 8.1 / 8.4 / 7 MEL: base layer (7 FEL has no native layer)
        default: return .apple                                         // SDR, HLG (first version: PQ only)
        }
    }
}

@MainActor
final class BrightVideo: NSObject {
    private let engine: AetherEngine
    private let view = MetalHDRView(frame: .zero)
    private var output: AVPlayerItemVideoOutput?
    private weak var item: AVPlayerItem?
    private var link: CADisplayLink?
    private(set) var active = false
    var onChange: (Bool) -> Void = { _ in }
    private static let debug = ProcessInfo.processInfo.environment["PLAYER_DEBUG"] != nil
    private var lastLog = 0.0

    init(engine: AetherEngine, surface: NSView) {
        self.engine = engine
        super.init()
        view.frame = surface.bounds
        view.autoresizingMask = [.width, .height]
        view.alphaValue = 0                 // not isHidden: a hidden view's display link never fires
        surface.addSubview(view)
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    /// The route for what is playing now, on the screen the window is on.
    var route: HDRRoute {
        let xdr = (view.window?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1 >= 8
        return HDRRoute.decide(hdrColors: Settings.hdrColors, format: engine.sourceVideoFormat, dvProfile: engine.sourceDVProfile,
                               dolbyVision: Settings.dolbyVisionNow, xdr: xdr)
    }

    @objc private func tick() {
        let current = engine.nativePlayerLayer?.player?.currentItem       // nil: no native session (software route, P7 FEL)
        if BrightVideo.debug, CACurrentMediaTime() - lastLog > 1 {           // PLAYER_DEBUG=1: why it is on or off
            lastLog = CACurrentMediaTime()
            print("[bright] layer \(engine.nativePlayerLayer != nil) item \(current != nil) route \(route) format \(engine.sourceVideoFormat) P\(engine.sourceDVProfile ?? -1) hdrColors \(Settings.hdrColors) output \(output != nil)")
        }
        guard let current, route == .specular, !engine.pictureInPictureActive else { detach(); return }
        if current !== item { detach(); attach(current) }                 // a reload or an item swap: follow it
        guard let output else { return }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t), let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        view.draw(pb)
        if view.alphaValue == 0 { view.alphaValue = 1 }
    }

    private func attach(_ item: AVPlayerItem) {
        let o = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        o.suppressesPlayerRendering = true                                 // AVPlayer's own picture off; ours on
        item.add(o)
        output = o; self.item = item
        if !active { active = true; onChange(true) }
    }

    private func detach() {
        if let o = output, let i = item { i.remove(o) }
        output = nil; item = nil
        view.alphaValue = 0
        if active { active = false; onChange(false) }
    }
}

/// CAMetalLayer set up the way IINA sets up its HDR layer; the shader keeps PQ and only rolls off highlights the screen can't show.
final class MetalHDRView: NSView {
    private let metal = CAMetalLayer()
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 pos [[position]]; float2 uv; };
    vertex V vmain(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        V o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
    }
    constant float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
    float pqToLin(float e) { float p = pow(e, 1.0 / m2); return pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1); }
    float linToPQ(float l) { float y = pow(l, m1); return pow((c1 + c2 * y) / (1.0 + c3 * y), m2); }
    struct Roll { float knee, target, peak; };
    // 10-bit video range, MSB-aligned in 16-bit planes; BT.2020 non-constant luminance; output stays PQ.
    fragment float4 fmain(V in [[stage_in]], texture2d<float> yT [[texture(0)]], texture2d<float> cT [[texture(1)]],
                          constant Roll &r [[buffer(0)]]) {
        constexpr sampler s(filter::linear);
        float y  = yT.sample(s, in.uv).r * 65535.0 / 64.0;
        float2 c = cT.sample(s, in.uv).rg * 65535.0 / 64.0;
        float Y = (y - 64.0) / 876.0, Cb = (c.x - 512.0) / 896.0, Cr = (c.y - 512.0) / 896.0;
        float3 rgb = float3(Y + 1.4746 * Cr, Y - 0.16455 * Cb - 0.57135 * Cr, Y + 1.8814 * Cb);
        rgb = clamp(rgb, 0.0, 1.0);
        // Roll off on max(R,G,B) and scale all channels in linear light, so bright colours keep their hue.
        float m = max(rgb.r, max(rgb.g, rgb.b));
        if (r.peak > r.target && m > r.knee) {
            // Rational curve: slope 1 at the knee, still rising up to the source peak, which lands on target.
            float s = r.peak - r.knee, d = r.target - r.knee, x = m - r.knee;
            float mm = min(r.target, r.knee + x / (1.0 + x * (s - d) / (d * s)));
            rgb = float3(linToPQ(pqToLin(rgb.r) * pqToLin(mm) / pqToLin(m)), linToPQ(pqToLin(rgb.g) * pqToLin(mm) / pqToLin(m)),
                         linToPQ(pqToLin(rgb.b) * pqToLin(mm) / pqToLin(m)));
        }
        return float4(rgb, 1.0);
    }
    """

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metal.device = device
        metal.pixelFormat = .rgba16Float
        metal.wantsExtendedDynamicRangeContent = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        metal.contentsGravity = .resizeAspect
        metal.backgroundColor = NSColor.black.cgColor
        layer = metal
        if let lib = try? device.makeLibrary(source: Self.shader, options: nil) {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "fmain")
            d.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try? device.makeRenderPipelineState(descriptor: d)
        }
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }        // clicks go to the player view below

    /// knee, target and source peak in PQ; the shader leaves the frame alone when the peak fits under the target.
    /// Measured: in this itur_2100_PQ EDR layer, EDR 1.0 (SDR white) = 100 nits, so the screen shows headroom x 100 nits.
    static func roll(headroom: CGFloat) -> SIMD3<Float> {
        func pq(_ n: Double) -> Float {
            let y = pow(n / 10000, 0.1593017578125)
            return Float(pow((0.8359375 + 18.8515625 * y) / (1 + 18.6875 * y), 78.84375))
        }
        let target = Double(headroom) * 100
        // shortcut: AVPlayerItemVideoOutput buffers carry no ST 2086 attachment (measured), so assume a 1000-nit master; read the track's mastering metadata if 4000-nit films clip.
        let peak = 1000.0
        // Knee at 75% of the screen's peak: keeps the approved brightness, leaves a quarter of the range for the roll-off.
        return SIMD3(pq(target * 0.75), pq(target), pq(peak))
    }

    func draw(_ pb: CVPixelBuffer) {
        guard let cache, let pipeline else { return }
        // Drawable: the video's aspect, no bigger than the view's pixels (contentsGravity fits it).
        let w = Double(CVPixelBufferGetWidth(pb)), h = Double(CVPixelBufferGetHeight(pb))
        let px = bounds.size.applying(.init(scaleX: window?.backingScaleFactor ?? 2, y: window?.backingScaleFactor ?? 2))
        let k = min(1, px.width / w, px.height / h)
        let size = CGSize(width: max(1, (w * k).rounded()), height: max(1, (h * k).rounded()))
        if metal.drawableSize != size { metal.drawableSize = size }
        guard let drawable = metal.nextDrawable() else { return }
        func tex(_ plane: Int, _ fmt: MTLPixelFormat) -> MTLTexture? {
            var t: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, CVPixelBufferGetWidthOfPlane(pb, plane),
                                                      CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
            return t.flatMap(CVMetalTextureGetTexture)
        }
        guard let y = tex(0, .r16Unorm), let c = tex(1, .rg16Unorm), let cb = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline); enc.setFragmentTexture(y, index: 0); enc.setFragmentTexture(c, index: 1)
        var roll = Self.roll(headroom: window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        enc.setFragmentBytes(&roll, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
        cb.present(drawable); cb.commit()
    }
}
