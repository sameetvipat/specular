import SwiftUI
import UniformTypeIdentifiers

/// Wraps the engine's video view (AetherPlayerView) so SwiftUI can layer controls over it.
struct VideoSurface: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Liquid Glass surfaces (the deployment target is macOS 27, so no fallback is needed).
extension View {
    func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
    func glassCapsule(interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
    }
    func glassCircle() -> some View {
        glassEffect(.regular.interactive(), in: .circle)
    }
}

/// Full-bleed player in the style of the Apple TV app: the picture edge to edge,
/// title + metadata badges over a bottom scrim, a thin capsule scrubber, round glass
/// transport buttons, and an "Audio & Subtitles" glass panel.
struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @AppStorage("statsForNerds") private var statsForNerds = false
    let surface: NSView

    var body: some View {
        ZStack {
            Color.black
            VideoSurface(view: surface)
                .onTapGesture(count: 2) { model.onToggleFullScreen() }
                .onTapGesture {
                    if model.showTrackPanel || model.showInfo || model.showKeyHelp {
                        model.showTrackPanel = false; model.showInfo = false; model.showKeyHelp = false
                    }
                    else { model.toggleControls() }     // a click shows/hides controls, never pauses
                }

            SubtitleOverlay(model: model)

            if model.showSpinner {                     // opening, rebuilding, switching, buffering
                ZStack {
                    Color.black.opacity(0.45)          // the last frame stays, dimmed
                    ProgressView().controlSize(.large).tint(.white)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            scrims
                .opacity(model.controlsVisible ? 1 : 0)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if model.ended { endBadge.frame(maxWidth: .infinity) }
                Spacer(minLength: 0)
                bottomChrome
            }
            .padding(.horizontal, 36)
            .padding(.top, 14)
            .padding(.bottom, 26)
            .opacity(model.controlsVisible ? 1 : 0)
            .offset(y: model.controlsVisible ? 0 : 14)
            .allowsHitTesting(model.controlsVisible && !model.placeholder)   // loading screen: shown but inert

            if let toast = model.toast {                // "Saved …" and the like
                Text(toast)
                    .font(.callout.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .glassCapsule()
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 52)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            // Skip Intro / Skip Credits and the Up Next card: bottom right, above the controls when they show.
            Group {
                if let up = model.upNext {
                    upNextCard(up)
                } else if let skip = model.skipButton {
                    Button { model.seek(to: skip.to) } label: {
                        Text(skip.label).font(.headline).padding(.horizontal, 20).padding(.vertical, 11)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(interactive: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 36).padding(.bottom, model.controlsVisible ? 230 : 40)
            .transition(.opacity)

            if model.showKeyHelp {
                KeyHelpOverlay()
                    .onTapGesture { model.showKeyHelp = false }
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()                              // picture under the title bar, edge to edge
        .animation(.smooth(duration: 0.35), value: model.controlsVisible)
        .animation(.easeOut(duration: 0.2), value: model.showKeyHelp)
        .animation(.easeOut(duration: 0.25), value: model.upNext == nil)
        .animation(.easeOut(duration: 0.25), value: model.skipButton?.label)
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.showSpinner)
        .onContinuousHover { phase in
            if case .active = phase { model.poke() }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let it = providers.first else { return false }
            _ = it.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { DispatchQueue.main.async { model.onDropFile(url.path) } }
            }
            return true
        }
        .preferredColorScheme(.dark)
    }

    // MARK: scrims (keep the chrome legible over bright HDR pictures)
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
            Spacer(minLength: 0)
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black.opacity(0.35), location: 0.45),
                                   .init(color: .black.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 300)
        }
    }

    // MARK: top (room on the left for the window buttons)
    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if model.hdrWarning, let hdr = model.hdrLabel {
                Label(hdr, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
            }
            Button { model.showInfo.toggle() } label: {
                Image(systemName: "info").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassCircle()
            .help("Playback info (I)")
        }
        .frame(height: 30)
        .overlay(alignment: .topTrailing) {
            if model.showInfo { infoPanel.offset(y: 40) }
        }
        .zIndex(1)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One grid for every section, so all labels share one column.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(model.infoSections(nerds: statsForNerds).enumerated()), id: \.offset) { i, section in
                    if i > 0 { Divider().padding(.vertical, 3) }
                    Text(section.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .gridCellColumns(2).padding(.bottom, 1)
                    infoRows(section.rows)
                }
            }
            .font(.system(size: 12).monospacedDigit())
            .textSelection(.enabled)
            Toggle("Stats for Nerds", isOn: $statsForNerds)
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11))
        }
        .padding(14)
        .glassPanel(cornerRadius: 16)
        .fixedSize()
    }

    private func infoRows(_ rows: [(label: String, value: String)]) -> some View {
        ForEach(rows, id: \.label) { row in
            GridRow {
                Text(row.label).foregroundStyle(.secondary)
                Text(row.value)
            }
        }
    }

    private func upNextCard(_ up: PlayerModel.UpNext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("UP NEXT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.dismissUpNext() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 20, height: 20).contentShape(Circle())
                }
                .buttonStyle(.plain).help("Hide")
            }
            Text(up.label).font(.headline).lineLimit(2)
            Button { model.playNextNow() } label: {
                Label(up.countdown.map { "Play Now · \($0)" } ?? "Play Now", systemImage: "play.fill")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .glassCapsule(interactive: true)
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .glassPanel(cornerRadius: 20)
    }

    private var endBadge: some View {
        Button { model.togglePlay() } label: {
            Label("Play Again", systemImage: "arrow.counterclockwise")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 22).padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .glassCapsule(interactive: true)
    }

    // MARK: bottom: metadata, title, scrubber, buttons
    private var bottomChrome: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let y = model.year { Text(y).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75)) }
                ForEach(model.badges, id: \.self) { MetaBadge(text: $0) }
            }
            Text(model.displayTitle)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.4), radius: 8)
            Scrubber(model: model)
            HStack(spacing: 14) {
                let back = Int(Settings.skipBackward), fwd = Int(Settings.skipForward)   // 5-60 s: SF Symbols has each
                RoundButton(system: "gobackward.\(back)", size: 42, help: "Back \(back) s (←)") { model.skip(forward: false) }
                RoundButton(system: model.isPaused || model.ended ? "play.fill" : "pause.fill", size: 54,
                            help: "Play / Pause (Space)") { model.togglePlay() }
                RoundButton(system: "goforward.\(fwd)", size: 42, help: "Forward \(fwd) s (→)") { model.skip(forward: true) }
                Spacer(minLength: 12)
                rightCluster
            }
        }
        .onHover { model.hoveringControls = $0 }
    }

    private var rightCluster: some View {
        HStack(spacing: 2) {
            VolumeControl(model: model)
            Divider().frame(height: 18).padding(.horizontal, 4)
            ClusterButton(system: model.currentSubtitle >= 0 ? "captions.bubble.fill" : "captions.bubble",
                          help: "Audio & Subtitles", active: model.showTrackPanel) {
                model.showTrackPanel.toggle()
            }
            .popover(isPresented: $model.showTrackPanel, arrowEdge: .top) {
                TrackPanel(model: model).preferredColorScheme(.dark)
            }
            moreMenu
            if model.canPiP {
                ClusterButton(system: model.pipActive ? "pip.exit" : "pip.enter", help: "Picture in Picture",
                              active: model.pipActive) { model.togglePiP() }
            }
            ClusterButton(system: "arrow.up.left.and.arrow.down.right", help: "Full Screen (F)") { model.onToggleFullScreen() }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .glassCapsule()
    }

    private var moreMenu: some View {
        Menu {
            Section("Playback Speed") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Toggle(speedText(r), isOn: Binding(get: { abs(model.rate - r) < 0.01 }, set: { if $0 { model.setRate(r) } }))
                }
            }
            Menu("Sleep Timer") {
                ForEach(PlayerModel.SleepTimer.choices, id: \.self) { t in
                    Toggle(t.title, isOn: Binding(get: { model.sleepTimer == t }, set: { if $0 { model.setSleepTimer(t) } }))
                }
            }
            Section {
                Button("Open…") { model.onOpen() }
                Button(model.showInfo ? "Hide Playback Info" : "Show Playback Info") { model.showInfo.toggle() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private func speedText(_ r: Double) -> String {
        r == 1 ? "Normal (1×)" : (r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r))
    }
}

// MARK: - pieces

struct MetaBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 3.5, style: .continuous).stroke(.white.opacity(0.55), lineWidth: 1))
    }
}

struct RoundButton: View {
    let system: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.4, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .help(help)
    }
}

struct ClusterButton: View {
    let system: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(active ? 0.22 : hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct VolumeControl: View {
    @ObservedObject var model: PlayerModel
    var body: some View {
        HStack(spacing: 6) {
            Button { model.muted.toggle() } label: {
                Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill"
                      : model.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 26, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Mute (M)")
            ThinSlider(value: Binding(get: { model.muted ? 0 : model.volume },
                                      set: { model.muted = false; model.volume = $0 }))
                .frame(width: 76)
        }
    }
}

/// White-on-translucent capsule slider (used for volume).
struct ThinSlider: View {
    @Binding var value: Double
    @State private var active = false
    var body: some View {
        GeometryReader { g in
            let h: CGFloat = active ? 7 : 5
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: max(h, g.size.width * value))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                value = min(1, max(0, v.location.x / g.size.width))
            })
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { active = h } }
        }
        .frame(height: 24)
    }
}

/// Apple TV-style scrubber: thin capsule that thickens on hover, a time bubble that
/// follows the pointer, elapsed time on the left and remaining time on the right.
struct Scrubber: View {
    @ObservedObject var model: PlayerModel
    @State private var hoverX: CGFloat?

    private var shown: Double { model.isScrubbing ? model.scrubValue : model.position }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                let w = max(g.size.width, 1)
                let frac = model.duration > 0 ? min(1, max(0, shown / model.duration)) : 0
                let active = hoverX != nil || model.isScrubbing
                let h: CGFloat = active ? 10 : 6
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    if let x = hoverX, !model.isScrubbing {         // hover preview fill
                        Capsule().fill(.white.opacity(0.25)).frame(width: max(h, x))
                    }
                    Capsule().fill(.white).frame(width: max(h, w * frac))
                    if model.duration > 0, model.chapters.count > 1 {   // chapter ticks
                        ForEach(model.chapters.indices, id: \.self) { i in
                            let cx = w * min(1, max(0, model.chapters[i].time / model.duration))
                            if cx > 2 && cx < w - 2 {
                                Capsule().fill(.black.opacity(0.55)).frame(width: 2, height: h)
                                    .offset(x: cx - 1)
                            }
                        }
                    }
                }
                .frame(height: h)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !model.isScrubbing { model.beginScrub() }
                        model.scrubValue = min(1, max(0, v.location.x / w)) * model.duration
                        hoverX = v.location.x
                        model.requestScrub(at: model.scrubValue)
                    }
                    .onEnded { _ in model.endScrub() })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverX = min(max(p.x, 0), w)
                        if !model.isScrubbing { model.requestScrub(at: Double(hoverX! / w) * model.duration) }
                    case .ended: hoverX = nil; model.clearScrub()
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let x = hoverX ?? (model.isScrubbing ? w * frac : nil) {
                        let t = model.isScrubbing ? model.scrubValue : Double(x / w) * model.duration
                        let half: CGFloat = model.scrubImage == nil ? 34 : 90   // keep the bubble inside the bar
                        VStack(spacing: 6) {
                            if let img = model.scrubImage {
                                Image(decorative: img, scale: 1)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.35), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.5), radius: 8)
                            }
                            Text(formatTime(t))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .glassCapsule()
                        }
                        .fixedSize()
                        .frame(height: 200, alignment: .bottom)             // grows upward from the time bubble
                        .position(x: min(max(x, half), w - half), y: -102)
                        .allowsHitTesting(false)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: active)
            }
            .frame(height: 22)
            HStack {
                if model.isLive {
                    // Live: how far behind the edge, and a LIVE badge that jumps back to it.
                    Text(model.behindLive > 2 ? "-" + formatTime(model.behindLive) : "")
                    Spacer()
                    Button { model.goLive() } label: {
                        HStack(spacing: 5) {
                            Circle().fill(model.behindLive > 2 ? Color.gray : Color.red).frame(width: 7, height: 7)
                            Text("LIVE").font(.system(size: 11, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain).help("Jump to live")
                } else {
                    Text(formatTime(shown))
                    Spacer()
                    Text("-" + formatTime(max(0, model.duration - shown)))
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// "Audio & Subtitles" popover — two columns of tracks with checkmarks, plus subtitle size,
/// delays and Add Subtitle File…, like the Apple TV app's panel.
struct TrackPanel: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            column("Audio") {
                if model.audioTracks.isEmpty { Text("None").foregroundStyle(.secondary).padding(.leading, 30) }
                ForEach(model.audioTracks.indices, id: \.self) { i in
                    TrackRow(name: model.audioTracks[i], selected: i == model.currentTrack) { model.selectTrack(i) }
                }
            }
            column("Subtitles") {
                TrackRow(name: "Off", selected: model.currentSubtitle < 0) { model.selectSubtitle(-1) }
                ForEach(model.subtitleTracks.indices, id: \.self) { i in
                    TrackRow(name: model.subtitleTracks[i], selected: i == model.currentSubtitle) { model.selectSubtitle(i) }
                }
                if !model.subtitleTracks.isEmpty {
                    Text("Size").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 10).padding(.leading, 30)
                    Picker("", selection: $model.subtitleScale) {
                        Text("Small").tag(0.8); Text("Medium").tag(1.0); Text("Large").tag(1.25)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.leading, 30)
                    .frame(maxWidth: 260)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            // Delays and an outside subtitle file, as in the Audio / Subtitles menus.
            HStack(alignment: .firstTextBaseline, spacing: 26) {
                delay("Audio Delay", model.audioDelay, model.nudgeAudioDelay, model.resetAudioDelay)
                VStack(alignment: .leading, spacing: 8) {
                    delay("Subtitle Delay", model.subtitleDelay, model.nudgeSubtitleDelay, model.resetSubtitleDelay)
                    Button("Add Subtitle File…") { addSubtitleFile() }.padding(.leading, 30)
                }
                .frame(width: 270, alignment: .leading)
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)   // hug the content
        .onHover { model.hoveringControls = $0 }
    }

    private func delay(_ title: String, _ value: Double, _ nudge: @escaping (Double) -> Void, _ reset: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button { nudge(-0.05) } label: { Image(systemName: "minus") }.help("−50 ms")
            Button(String(format: "%+.0f ms", value * 1000)) { reset() }
                .buttonStyle(.plain).monospacedDigit().frame(minWidth: 58).help("Reset")
            Button { nudge(0.05) } label: { Image(systemName: "plus") }.help("+50 ms")
        }
        .controlSize(.small)
        .padding(.leading, 30)
        .frame(width: 270, alignment: .leading)
    }

    private func addSubtitleFile() {
        model.showTrackPanel = false
        let p = NSOpenPanel()
        p.allowedContentTypes = PlayerModel.subtitleExts.compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let u = p.url { model.addSubtitleFile(u) }
    }

    private func column<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).padding(.leading, 30).padding(.bottom, 6)
            ScrollView { VStack(alignment: .leading, spacing: 2) { content() } }
                .scrollIndicators(.never)
                .frame(maxHeight: 330)
        }
        .frame(width: 270, alignment: .leading)
    }
}

struct TrackRow: View {
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        // "English · Dolby TrueHD Atmos 7.1 · Commentary" -> "English" over the details
        let parts = name.components(separatedBy: " · ")
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(parts.first ?? name).font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    if parts.count > 1 {
                        Text(parts.dropFirst().joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "?" in the player: every hot key from HotKeys, grouped, in two columns on a glass panel.
struct KeyHelpOverlay: View {
    var body: some View {
        let groups = HotKeys.Group.allCases
        let half = (groups.count + 1) / 2
        ZStack {
            Color.black.opacity(0.35)
            VStack(alignment: .leading, spacing: 14) {
                Text("Keyboard Shortcuts").font(.title2.weight(.bold))
                let columns = HStack(alignment: .top, spacing: 36) {
                    column(Array(groups[..<half]))
                    column(Array(groups[half...]))
                }
                ViewThatFits(in: .vertical) { columns; ScrollView { columns }.scrollIndicators(.never) }   // small windows scroll
                Text("Change them in Settings > Hot Keys. Esc or ? closes.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .glassPanel(cornerRadius: 24)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 30)
        }
    }

    private func column(_ groups: [HotKeys.Group]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 3) {
            ForEach(groups, id: \.self) { g in
                Text(g.rawValue.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .gridCellColumns(2).padding(.top, g == groups.first ? 0 : 8)
                ForEach(HotKeys.Action.allCases.filter { $0.group == g }, id: \.self) { a in
                    GridRow {
                        Text(a.title).font(.system(size: 12))
                        Text(HotKeys.symbols(HotKeys.binding(for: a))).font(.system(size: 12, weight: .semibold).monospaced())
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }
}
