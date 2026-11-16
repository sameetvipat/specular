import SwiftUI
import Combine
import AetherEngine
import SwiftAssRenderer

/// Styled ASS / SSA through libass (swift-ass-renderer), for the selected track when it is ASS.
/// Aether hands the raw event lines (`preserveASSMarkup`) and the track's header; we rebuild the
/// script with Aether's `ASSScriptBuilder`, feed it to libass, and move libass' clock with the
/// engine's `sourceTime`. Same contract AetherPlayer uses (AetherEngine#30).
@MainActor
final class ASSCoordinator {
    private(set) var renderer: AssSubtitlesRenderer?
    private let engine: AetherEngine
    private var builder: ASSScriptBuilder?
    private var subs = Set<AnyCancellable>()
    private var pending = false
    private var lastReload = Date.distantPast
    private var clock: Timer?
    var onChange: (AssSubtitlesRenderer?) -> Void = { _ in }

    init(engine: AetherEngine) { self.engine = engine }

    /// Start for a track with this ASS header (nil or empty: stay off, the text path draws it).
    func activate(header: String?, delay: @escaping () -> Double) {
        deactivate()
        guard let header, !header.isEmpty else { return }
        let fonts = ASSCoordinator.writeFonts(engine.fontAttachments)
        let r = AssSubtitlesRenderer(fontConfig: FontConfig(fontsPath: fonts, fontProvider: .coreText))
        renderer = r
        builder = ASSScriptBuilder(header: header)
        engine.$subtitleCues.receive(on: DispatchQueue.main)
            .sink { [weak self] cues in self?.consume(cues) }
            .store(in: &subs)
        // 30 Hz is plenty for subtitle timing; also flushes a batch that arrived between cue emits.
        clock = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderer?.setTimeOffset(self.engine.clock.sourceTime - delay())
                self.flush()
            }
        }
        onChange(r)
    }

    func deactivate() {
        subs.removeAll(); clock?.invalidate(); clock = nil
        renderer?.freeTrack(); renderer = nil; builder = nil; pending = false
        onChange(nil)
    }

    private func consume(_ cues: [SubtitleCue]) {
        guard let builder else { return }
        for cue in cues {
            if case .text(let raw) = cue.body, builder.add(rawEventText: raw, start: cue.startTime, end: cue.endTime) { pending = true }
        }
        flush()
    }

    /// Re-parse at most twice a second: each reload re-reads the whole script.
    private func flush() {
        guard pending, let builder, let renderer, Date().timeIntervalSince(lastReload) > 0.5 else { return }
        pending = false; lastReload = Date()
        renderer.reloadTrack(content: builder.script())
    }

    /// Fonts embedded in the file (MKV attachments), written once to a cache folder libass reads.
    private static func writeFonts(_ fonts: [FontAttachment]) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Specular/ass-fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in fonts {
            let name = (f.filename as NSString).lastPathComponent      // no path escapes from the container
            guard !name.isEmpty, name != ".." else { continue }
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try? f.data.write(to: url, options: .atomic) }
        }
        return dir
    }
}

/// libass' output for the current frame, drawn into a layer sized to the picture.
struct ASSLayerView: NSViewRepresentable {
    let renderer: AssSubtitlesRenderer
    func makeNSView(context: Context) -> ASSHostView { ASSHostView(renderer: renderer) }
    func updateNSView(_ view: ASSHostView, context: Context) {}
}

final class ASSHostView: NSView {
    private let renderer: AssSubtitlesRenderer
    private let imageLayer = CALayer()
    private var sub: AnyCancellable?

    init(renderer: AssSubtitlesRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isGeometryFlipped = true          // libass rects are top-left based
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
        sub = renderer.framesPublisher().receive(on: DispatchQueue.main).sink { [weak self] frame in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if let frame {
                self?.imageLayer.frame = frame.imageRect
                self?.imageLayer.contents = frame.image
                self?.imageLayer.isHidden = false
            } else {
                self?.imageLayer.isHidden = true
            }
            CATransaction.commit()
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        guard !bounds.isEmpty else { return }           // a 0x0 canvas renders nothing
        renderer.setCanvasSize(bounds.size, scale: window?.backingScaleFactor ?? 2)
    }
}
