// edrplay: live side-by-side HDR test (docs/tasks/bright-mode.md, step 1).
// Left  = Reference: AVPlayer, as Specular plays today (Apple's HDR / Dolby Vision mapping).
// Right = Bright: the decoded 10-bit frames drawn by a Metal shader into an EDR layer set up the way
//         IINA does (itur_2100_PQ, RGBA16Float, wantsExtendedDynamicRangeContent): PQ kept, no tone mapping.
// Usage: edrplay <clip.mp4|mov>   (AVFoundation only, so MP4 / MOV; loops; Q quits)
import AppKit
import AVFoundation
import Metal
import QuartzCore

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
vertex V vmain(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);             // full-screen triangle
    V o; o.pos = float4(p * 2.0 - 1.0, 0, 1); o.uv = float2(p.x, 1.0 - p.y); return o;
}
// 10-bit video range, MSB-aligned in 16-bit planes. BT.2020 non-constant luminance. Output stays PQ.
fragment float4 fmain(V in [[stage_in]], texture2d<float> yT [[texture(0)]], texture2d<float> cT [[texture(1)]]) {
    constexpr sampler s(filter::linear);
    float y  = yT.sample(s, in.uv).r * 65535.0 / 64.0;
    float2 c = cT.sample(s, in.uv).rg * 65535.0 / 64.0;
    float Y = (y - 64.0) / 876.0, Cb = (c.x - 512.0) / 896.0, Cr = (c.y - 512.0) / 896.0;
    float3 rgb = float3(Y + 1.4746 * Cr, Y - 0.16455 * Cb - 0.57135 * Cr, Y + 1.8814 * Cb);
    return float4(clamp(rgb, 0.0, 1.0), 1.0);
}
"""

final class BrightView: NSView {
    let metal = CAMetalLayer()
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var pipeline: MTLRenderPipelineState!
    private var cache: CVMetalTextureCache?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metal.device = device
        metal.pixelFormat = .rgba16Float
        metal.wantsExtendedDynamicRangeContent = true
        metal.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        metal.framebufferOnly = true
        layer = metal
        let lib = try! device.makeLibrary(source: shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain"); d.fragmentFunction = lib.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }
    required init?(coder: NSCoder) { fatalError() }

    func draw(_ pb: CVPixelBuffer) {
        guard let cache, let drawable = metal.nextDrawable() else { return }
        func tex(_ plane: Int, _ fmt: MTLPixelFormat) -> MTLTexture? {
            var t: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, fmt, CVPixelBufferGetWidthOfPlane(pb, plane),
                                                      CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
            return t.flatMap(CVMetalTextureGetTexture)
        }
        guard let y = tex(0, .r16Unorm), let c = tex(1, .rg16Unorm), let cb = queue.makeCommandBuffer() else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture; rp.colorAttachments[0].loadAction = .dontCare
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pipeline); enc.setFragmentTexture(y, index: 0); enc.setFragmentTexture(c, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); enc.endEncoding()
        cb.present(drawable); cb.commit()
    }
}

final class App: NSObject, NSApplicationDelegate {
    let url: URL
    var window: NSWindow!
    let player: AVPlayer
    let bright = BrightView(frame: .zero)
    var timer: DispatchSourceTimer?
    var reader: AVAssetReader?, output: AVAssetReaderTrackOutput?
    var start = CACurrentMediaTime()

    init(url: URL) { self.url = url; player = AVPlayer(url: url); super.init() }

    func applicationDidFinishLaunching(_ n: Notification) {
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .video).first!
        let size = track.naturalSize, fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 24)
        let w = 900.0, h = w * size.height / size.width
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w * 2 + 8, height: h + 30), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "edrplay - Reference (left) | Bright (right) - \(url.lastPathComponent)"
        window.backgroundColor = .black
        let root = NSView(frame: window.contentLayoutRect)
        let ref = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h)); ref.wantsLayer = true
        let pl = AVPlayerLayer(player: player); pl.frame = ref.bounds; pl.videoGravity = .resizeAspect; ref.layer?.addSublayer(pl)
        bright.frame = NSRect(x: w + 8, y: 0, width: w, height: h)
        bright.metal.drawableSize = CGSize(width: size.width / 2, height: size.height / 2)
        for (label, x) in [("Reference (Apple, as Specular today)", 0.0), ("Bright (PQ into EDR, like IINA)", w + 8)] {
            let t = NSTextField(labelWithString: label); t.textColor = .white; t.frame = NSRect(x: x + 8, y: h + 6, width: w, height: 18)
            root.addSubview(t)
        }
        root.addSubview(ref); root.addSubview(bright)
        window.contentView = root; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in if e.charactersIgnoringModifiers == "q" { NSApp.terminate(nil) }; return e }

        restart(track: track)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / (fps * 2))
        t.setEventHandler { [weak self] in self?.tick(track: track) }
        t.resume(); timer = t
    }

    /// Both sides from the top together: the player seeks to 0, a new reader decodes from 0.
    func restart(track: AVAssetTrack) {
        reader?.cancelReading()
        let r = try! AVAssetReader(asset: track.asset!)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true])
        o.alwaysCopiesSampleData = false
        r.add(o); r.startReading()
        reader = r; output = o; pending = nil
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        start = CACurrentMediaTime()
    }

    var pending: CMSampleBuffer?
    func tick(track: AVAssetTrack) {
        let now = CACurrentMediaTime() - start
        while true {
            if pending == nil { pending = output?.copyNextSampleBuffer() }
            guard let sb = pending else { restart(track: track); return }      // end of clip: loop both
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            if pts > now { return }
            pending = nil
            let next = output?.copyNextSampleBuffer()                            // skip late frames, draw the newest due
            if let n = next, CMSampleBufferGetPresentationTimeStamp(n).seconds <= now { pending = n; continue }
            pending = next
            if let pb = CMSampleBufferGetImageBuffer(sb) { bright.draw(pb) }
            return
        }
    }
}

guard CommandLine.arguments.count > 1 else { print("usage: edrplay <clip.mp4>"); exit(2) }
let app = NSApplication.shared
let delegate = App(url: URL(fileURLWithPath: CommandLine.arguments[1]))
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
