import Foundation
import AppKit
import IOKit.pwr_mgt
import AetherEngine
import SwiftAssRenderer

/// Observable bridge between AetherEngine and the SwiftUI controls. The engine is long-lived
/// (one per app, see AppDelegate); a model lives for one opened file.
@MainActor
final class PlayerModel: ObservableObject {
    let engine: AetherEngine
    let title: String
    private let path: String
    let displayTitle: String            // "Spider-Man Brand New Day"
    let year: String?
    let audioOnly: Bool                 // no video stream (music): controls stay up, display may sleep
    let videoWidth: Int, videoHeight: Int
    /// Loading stand-in: the player screen before the file has opened. No polling, controls inert.
    let placeholder: Bool
    private let fileBytes: Int64?       // local file size, for the whole-file average bitrate

    @Published var duration: Double = 0
    @Published var audioTracks: [String] = []
    @Published var subtitleTracks: [String] = []
    @Published var chapters: [(time: Double, title: String)] = []
    private var audioIDs: [Int] = [], subtitleIDs: [Int] = []      // TrackInfo.id behind each name

    /// Top-bar badge. HDR / Dolby Vision is presented by Apple's display stack.
    @Published var hdrLabel: String?
    @Published var hdrIsDolby = false
    @Published var hdrWarning = false
    @Published var showInfo = false

    @Published var position: Double = 0
    @Published var isPaused = false
    @Published var ended = false
    /// Spinner over a dimmed last frame while playback is opened, rebuilt, switched, seeks or buffers.
    @Published var showSpinner = false
    @Published var isLive = false       // live TV / IPTV: transport shows LIVE and behind-live
    @Published var behindLive: Double = 0
    @Published var liveRange: ClosedRange<Double>?   // seekable DVR window
    @Published var rate: Double = 1.0
    @Published var volume: Double = 1.0 { didSet { engine.volume = Float(muted ? 0 : volume) } }
    @Published var muted = false        { didSet { engine.volume = Float(muted ? 0 : volume) } }
    @Published var currentTrack: Int = -1
    @Published var isScrubbing = false
    @Published var scrubValue: Double = 0
    @Published var controlsVisible = true { didSet { if controlsVisible != oldValue { onControlsVisible(controlsVisible) } } }
    @Published var currentSubtitle: Int = -1
    @Published var showTrackPanel = false { didSet { poke() } }
    @Published var showKeyHelp = false           // "?" cheat sheet of every hot key
    @Published var subtitleScale: Double {     // drawn by our overlay (step 4)
        didSet { UserDefaults.standard.set(subtitleScale, forKey: "subtitleScale"); poke() }
    }
    @Published var subtitleDelay: Double = 0    // applied by SubtitleOverlay
    @Published var assActive = false            // styled ASS drawn by libass, not the text path
    @Published var assRenderer: AssSubtitlesRenderer?
    private lazy var ass: ASSCoordinator = {
        let c = ASSCoordinator(engine: engine)
        c.onChange = { [weak self] r in self?.assRenderer = r; self?.assActive = r != nil }
        return c
    }()
    private var assTrackID = -2                 // subtitle id the ASS renderer was set up for (-1 = off)
    @Published var audioDelay: Double = 0 { didSet { engine.setAudioDelay(audioDelay) } }
    func nudgeAudioDelay(_ d: Double) { audioDelay = (audioDelay + d).rounded(toPlaces: 3); poke() }
    func nudgeSubtitleDelay(_ d: Double) { subtitleDelay = (subtitleDelay + d).rounded(toPlaces: 3); poke() }
    func resetAudioDelay() { audioDelay = 0; poke() }
    func resetSubtitleDelay() { subtitleDelay = 0; poke() }
    func resetAdjustments() { audioDelay = 0; subtitleDelay = 0; setRate(1) }
    var onControlsVisible: (Bool) -> Void = { _ in }

    // Stills and Picture in Picture (Frames.swift, PiP.swift)
    @Published var scrubImage: CGImage?         // thumbnail above the scrubber
    @Published var toast: String?               // brief message over the picture
    var frames: FrameExtractor?
    var scrubTask: Task<Void, Never>?
    var pip: PiP?

    var onOpen: () -> Void = {}
    var onDropFile: (String) -> Void = { _ in }
    var onToggleFullScreen: () -> Void = {}
    var onEnded: () -> Void = {}                // played to the end (continuous playback)
    var onPlayNext: (String) -> Void = { _ in } // Up Next card: play this path now

    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    /// Seconds a still pointer waits before the controls fade.
    let autoHideInterval: Double = 2.5
    var hoveringControls = false { didSet { poke() } }

    /// `probe` is what `engine.load` returned for this file.
    init(engine: AetherEngine, path: String, probe: SourceProbe?, placeholder: Bool = false) {
        self.engine = engine
        self.title = (path as NSString).lastPathComponent
        self.path = path
        self.placeholder = placeholder
        videoWidth = Int(probe?.videoWidth ?? 0); videoHeight = Int(probe?.videoHeight ?? 0)
        audioOnly = videoWidth == 0 && !placeholder
        let attrs = path.contains("://") ? nil : try? FileManager.default.attributesOfItem(atPath: path)
        fileBytes = attrs?[.type] as? FileAttributeType == .typeRegular ? (attrs?[.size] as? NSNumber)?.int64Value : nil   // not a disc folder
        let saved = UserDefaults.standard.object(forKey: "subtitleScale") as? Double ?? 1
        subtitleScale = saved
        (displayTitle, year) = Library.shared.playerTitle(path) ?? cleanTitle(path)    // library title when known
        // The engine is still opening the file: touch nothing, just show the screen with a spinner.
        guard !placeholder else { showSpinner = true; return }
        engine.volume = 1
        if let d = Self.sleepDeadline, d <= .now { Self.sleepMode = .off; Self.sleepDeadline = nil; sleepTimer = .off }  // ran out with no film open

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        poke()
        resetObserver = NotificationCenter.default.addObserver(forName: .init("ResetAdjustments"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAdjustments() }
        }
    }

    /// Source format, not `engine.videoFormat`: a Dolby Vision file that also carries HDR10+
    /// is published as `.hdr10Plus` on a Mac even while Apple composes its Dolby Vision
    /// (docs/tasks/aether-migration.md, step 5). We always ask for the composition.
    private func updateHDRBadge() {
        (hdrLabel, hdrIsDolby) = Self.playedRange(engine)
    }

    /// What is on screen, not just what the file holds: Dolby Vision off plays the HDR10 / HLG base
    /// layer (Profile 5 has none and stays Dolby Vision). When the display has no HDR headroom
    /// (system HDR off or a non-HDR screen), the badge says "SDR" — what the user sees.
    static func playedRange(_ e: AetherEngine) -> (label: String?, dolby: Bool) {
        let source: String?
        var dolby = false
        switch e.sourceVideoFormat {
        case .dolbyVision:
            if Settings.dolbyVisionNow || e.sourceDVProfile == 5 {
                dolby = true
                source = e.sourceDVProfile.map { "DOLBY VISION · P\($0)" } ?? "DOLBY VISION"
            } else {
                source = (e.videoFormat == .hlg ? "HLG" : "HDR10") + " · DV OFF"
            }
        case .hdr10Plus: source = "HDR10+"
        case .hdr10:     source = "HDR10"
        case .hlg:       source = "HLG"
        default:         source = nil
        }
        guard let source else { return (nil, false) }
        // Display awareness: when the screen has no HDR headroom (EDR max ≤ 1.0),
        // macOS tone-maps everything to SDR. Show what the user actually sees.
        let headroom = NSApp.keyWindow?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue
                     ?? NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 2.0
        if headroom <= 1.0 { return ("SDR", false) }
        return (source, dolby)
    }

    private var screenHeadroom: CGFloat {
        (NSApp.keyWindow?.screen ?? NSScreen.main)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
    }

    /// Who draws the HDR picture; nil for SDR. Specular only counts when Aether gave us a native layer to read.
    private var hdrPath: HDRRoute? {
        guard engine.sourceVideoFormat != .sdr else { return nil }
        let r = HDRRoute.decide(hdrColors: Settings.hdrColors, format: engine.sourceVideoFormat, dvProfile: engine.sourceDVProfile,
                                dolbyVision: Settings.dolbyVisionNow, xdr: screenHeadroom >= 8)
        return r == .specular && engine.nativePlayerLayer != nil ? .specular : .apple
    }

    /// "Profile 8.1": the base-layer compatibility id is the number after the dot.
    private var dvProfileName: String {
        guard let p = engine.sourceDVProfile else { return "" }
        if let c = engine.sourceDVBLCompatID, c > 0, p == 8 { return "Profile 8.\(c)" }
        return "Profile \(p)"
    }

    /// Whole-file average for a local file (size over duration), nil for streams and disc folders.
    private var fileAverageMbps: Double? {
        guard let b = fileBytes, duration > 0 else { return nil }
        return Double(b) * 8 / duration / 1_000_000
    }

    /// One number format per unit, shared by every row.
    static func mbps(_ v: Double) -> String { String(format: "%.1f Mb/s", v) }

    typealias InfoRow = (label: String, value: String)

    /// The info panel: Video, Audio, Subtitles and File, each with plain rows; `nerds` (Stats for Nerds) adds
    /// that section's engineering rows under them. HDR facts come from the source, not `videoFormat`.
    func infoSections(nerds: Bool) -> [(title: String, rows: [InfoRow])] {
        var sections: [(String, [InfoRow])] = []
        let t = engine.liveTelemetry

        if !audioOnly {
            var v: [InfoRow] = []
            let fmt = engine.sourceVideoStreamFormat
            var res = "\(resolutionLabel(width: videoWidth, height: videoHeight)) · \(videoWidth)×\(videoHeight)"
            if engine.sourceVideoBitrate > 0 { res += " · " + Self.mbps(Double(engine.sourceVideoBitrate) / 1_000_000) }
            else if let f = fileAverageMbps { res += " · " + Self.mbps(f) + " (file average)" }
            v.append(("Resolution", res))
            // Every HDR format the file carries, not what plays (that is "Playing as" under Stats for Nerds).
            let dv = engine.sourceVideoFormat == .dolbyVision
            var hdr: String
            switch engine.sourceVideoFormat {
            case .dolbyVision:
                var f = ["Dolby Vision"]
                if engine.videoFormat == .hdr10Plus { f.append("HDR10+") }      // Aether quirk: DV + HDR10+ reports .hdr10Plus
                switch engine.sourceDVBLCompatID ?? 0 {
                case 1, 6: f.append("HDR10")
                case 4:    f.append("HLG")
                default:   if engine.sourceDVProfile == 7 { f.append("HDR10") }  // dual layer: the base is HDR10
                }
                hdr = f.joined(separator: " · ")
            case .hdr10Plus: hdr = "HDR10+ · HDR10"
            case .hdr10:     hdr = "HDR10"
            case .hlg:       hdr = "HLG"
            default:         hdr = "None (SDR)"
            }
            if hdrPath != nil && hdrLabel == "SDR" { hdr += " · this screen shows SDR" }
            v.append(("HDR", hdr))
            if dv {
                var d = [dvProfileName]
                if engine.sourceDVProfile == 5 { d.append("no base layer") }
                else if engine.sourceDVProfile == 7 { d.append("dual layer") }
                else if let c = engine.sourceDVBLCompatID, c > 0 {
                    d.append([1: "HDR10-compatible base", 2: "SDR-compatible base", 4: "HLG-compatible base", 6: "Blu-ray HDR10 base"][c] ?? "base \(c)")
                }
                if engine.dolbyVisionConversion == .profile7ToProfile81 { d.append("served as Profile 8.1") }
                v.append(("Dolby Vision", d.filter { !$0.isEmpty }.joined(separator: " · ")))
            }
            var codec = [(engine.sourceVideoCodecName ?? "unknown").uppercased()]
            if let p = fmt?.profile { codec[0] += " " + p }
            if let bd = fmt?.bitDepth { codec.append("\(bd)-bit") }
            if let px = fmt?.pixelFormat, let c = ["444": "4:4:4", "422": "4:2:2", "420": "4:2:0"].first(where: { px.contains($0.key) }) { codec.append(c.value) }
            v.append(("Codec", codec.joined(separator: " · ")))
            if let f = engine.sourceVideoFrameRate { v.append(("Frame rate", String(format: "%.3f fps", f))) }
            if nerds {
                // What actually plays: Dolby Vision off (or Specular's path) shows the base layer.
                let base = engine.videoFormat == .hlg ? "HLG" : engine.videoFormat == .hdr10Plus ? "HDR10+" : "HDR10"
                switch engine.sourceVideoFormat {
                case .dolbyVision:
                    let on = Settings.dolbyVisionNow || engine.sourceDVProfile == 5          // Profile 5 has no base layer
                    v.append(("Playing as", !on ? "\(base) base layer (Dolby Vision off)"
                              : hdrPath == .specular ? "\(base) base layer (Dolby Vision layer skipped)" : "Dolby Vision"))
                case .hdr10Plus: v.append(("Playing as", "HDR10+"))
                case .hdr10:     v.append(("Playing as", "HDR10"))
                case .hlg:       v.append(("Playing as", "HLG"))
                default:         break
                }
                let scr = NSApp.keyWindow?.screen ?? NSScreen.main
                if let scr { v.append(("Screen", String(format: "headroom %.2f× now · up to %.1f×",
                                                          scr.maximumExtendedDynamicRangeColorComponentValue, screenHeadroom))) }
                if let d = engine.activeVideoDecoder { v.append(("Decoder", d)) }
                let route: String
                switch engine.videoRoute {
                case .loopback:     route = "AVPlayer, fed by Aether's local HLS server"
                case .remoteBypass: route = "AVPlayer, reading the HLS stream directly"
                case .software:     route = "Aether software decode to a display layer"
                default:            route = "None"
                }
                v.append(("Pipeline", route))
                var fr: [String] = []
                if let f = t?.observedFps { fr.append(String(format: "%.3f fps shown", f)) }
                if let d = t?.droppedFrameCount { fr.append("\(d) dropped") }
                if !fr.isEmpty { v.append(("Frames", fr.joined(separator: " · "))) }
            }
            sections.append(("Video", v))
        }

        var a: [InfoRow] = [("Track", currentTrack >= 0 && currentTrack < audioTracks.count ? audioTracks[currentTrack] : "None")]
        if audioDelay != 0 { a.append(("Delay", String(format: "%+.0f ms", audioDelay*1000))) }
        if engine.audioShapingState != .off {
            a.append(("Shaping", engine.audioShaping.summary
                + (engine.audioShapingState == .applied ? " (on)" : " (not possible on this pipeline)")))
        }
        if nerds {
            if let tr = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) {
                var p = [tr.codec.uppercased()]
                if tr.channels > 0 { p.append("\(tr.channels) ch") }
                if tr.sampleRate > 0 { p.append(String(format: "%g kHz", Double(tr.sampleRate) / 1000)) }
                p.append(tr.bitrate > 0 ? String(format: "%.0f kb/s", Double(tr.bitrate) / 1000) : "variable bitrate")
                a.append(("Codec", p.joined(separator: " · ")))
            }
            let delivery: String
            switch engine.audioDelivery {
            case .streamCopy:        delivery = "Passed through unchanged"
            case .bridged:           delivery = "Decoded and re-encoded (not playable as is)"
            case .decoded:           delivery = "Decoded by FFmpeg, played by Aether"
            case .playerManaged:     delivery = "Handled by AVPlayer"
            case .droppedNoPipeline: delivery = "Not playing: no decoder could open it"
            default:                 delivery = "None"
            }
            a.append(("Path", [engine.activeAudioDecoder, delivery].compactMap { $0 }.joined(separator: " · ")))
            if let b = t?.audioBridgeBitrateMbps { a.append(("Sent", Self.mbps(b) + " after conversion")) }
            if let o = t?.objectAudio {
                a.append(("Objects", "\(o.layout.rawValue) speakers · \(o.activeObjects) of \(o.objects) objects active · "
                    + "\(o.elevatedObjects) overhead" + (o.heightChannels > 0 ? " · \(o.heightChannels) height channels" : "")))
            }
        }
        sections.append(("Audio", a))

        var sub: [InfoRow] = [("Track", currentSubtitle >= 0 && currentSubtitle < subtitleTracks.count ? subtitleTracks[currentSubtitle] : "Off")]
        if subtitleDelay != 0 { sub.append(("Delay", String(format: "%+.0f ms", subtitleDelay*1000))) }
        sections.append(("Subtitles", sub))

        var f: [InfoRow] = []
        if nerds {          // the File section is Stats for Nerds only
            let stream = path.contains("://")
            if !stream { f.append(("Name", (path as NSString).lastPathComponent)) }     // never a URL: it may carry a key
            var size: [String] = []
            if let b = fileBytes { size.append(ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)) }
            if duration > 0 { size.append(formatTime(duration)) }
            if !size.isEmpty { f.append(("Size", size.joined(separator: " · "))) }
            let ext = stream ? "" : (path as NSString).pathExtension.lowercased()
            let containers = ["mkv": "Matroska (MKV)", "mp4": "MPEG-4 (MP4)", "m4v": "MPEG-4 (M4V)", "mov": "QuickTime (MOV)",
                              "m2ts": "Blu-ray (M2TS)", "ts": "MPEG-TS", "webm": "WebM", "avi": "AVI", "iso": "Disc image (ISO)"]
            if !ext.isEmpty { f.append(("Container", containers[ext] ?? ext.uppercased())) }
            var br: [String] = []
            if let x = fileAverageMbps { br.append(Self.mbps(x) + " overall") }
            if let x = t?.instantBitrateMbps { br.append(Self.mbps(x) + " now") }
            if !br.isEmpty { f.append(("Bitrate", br.joined(separator: " · "))) }
            let ahead = engine.bufferedPosition - position
            if stream, ahead > 0 { f.append(("Buffered", String(format: "%.0f s ahead", ahead))) }
            if stream, let n = t?.networkThroughputMbps { f.append(("Network", Self.mbps(n) + " read rate")) }
        }
        if rate != 1 { f.append(("Speed", String(format: "%g×", rate))) }
        if !f.isEmpty { sections.append(("File", f)) }
        return sections
    }

    /// Stop polling; the app stops the engine.
    func shutdown() { if Self.sleepMode == .endOfFile { Self.sleepMode = .off }   // "this episode" only
        saveResume(); timer?.invalidate(); timer = nil; hideWork?.cancel(); allowSleep(); ass.deactivate(); closeFrames(); pip?.stop()
        if let o = resetObserver { NotificationCenter.default.removeObserver(o) } }

    // MARK: resume playback (resumes automatically by default)
    private var lastResumeSave: Double = 0
    private static let resumeKey = "resumePositions"
    /// Key for a path: a URL's query is dropped, so a Jellyfin api_key never lands in UserDefaults.
    private static func resumeID(_ path: String) -> String {
        path.contains("://") ? String(path.prefix { $0 != "?" }) : path
    }
    /// Where to start this file: the saved mid-film position, or nil.
    static func resumePosition(_ path: String) -> Double? {
        guard Settings.resumeEnabled,
              let t = UserDefaults.standard.dictionary(forKey: resumeKey)?[resumeID(path)] as? Double, t > 1 else { return nil }
        return t
    }
    private func saveResume() {
        guard !isLive else { return }
        var d = UserDefaults.standard.dictionary(forKey: PlayerModel.resumeKey) as? [String: Double] ?? [:]
        // Remember only a genuine mid-film position; forget it once watched to the end.
        let key = PlayerModel.resumeID(path)
        if Settings.resumeEnabled, duration > 30, position > 15, position < duration - 15 { d[key] = position }
        else { d.removeValue(forKey: key) }
        if d.count > 400 { for k in d.keys.filter({ $0 != key }).prefix(d.count - 400) { d.removeValue(forKey: k) } }
        UserDefaults.standard.set(d, forKey: PlayerModel.resumeKey)
        Library.shared.setProgress(path, position: ended ? duration : position, duration: duration)   // watched state
    }

    private func tick() {
        let previous = position
        if !isScrubbing { position = engine.clock.currentTime }
        duration = engine.duration
        isPaused = engine.state == .paused
        isLive = engine.isLive
        if isLive { behindLive = engine.behindLiveSeconds; liveRange = engine.seekableLiveRange }
        let nowEnded = engine.state == .ended
        if nowEnded && !ended {
            controlsVisible = true
            if sleepTimer == .endOfFile { fireSleepTimer() } else { onEnded() }   // sleep: no next episode
        }
        if let d = Self.sleepDeadline, Date.now >= d { fireSleepTimer() }
        ended = nowEnded
        syncTracks()
        if position - lastResumeSave > 5 || position < lastResumeSave { lastResumeSave = position; saveResume() }
        updateSleep(playing: !isPaused && !nowEnded)
        updateUpNext()
        NowPlaying.shared.update(title: displayTitle, duration: duration, position: position, rate: rate, paused: isPaused || nowEnded)
        updateHDRBadge()
        updateSpinner(moved: position > previous, ended: nowEnded)
        if showInfo { objectWillChange.send() }   // refresh live info lines
    }

    // MARK: spinner while playback is rebuilt or switched (the picture stutters then)
    private var rebuildDone: (() -> Bool)?      // set while the app rebuilds playback; true once the engine is done
    private var rebuildStart = Date()
    private var waitingForMotion = false        // rebuild done: hide once the clock moves again
    private var busySince: Date?

    /// Audio switch, settings reload, Dolby Vision toggle: the engine rebuilds the pipeline at the playhead.
    func beginRebuild(until done: @escaping () -> Bool = { false }) { rebuildDone = done; rebuildStart = .now }
    func endRebuild() { if rebuildDone != nil { rebuildDone = { true } } }

    private func updateSpinner(moved: Bool, ended: Bool) {
        // 10 s cap: a switch the engine ignores (e.g. a stream that cannot change audio) must not spin forever.
        if let done = rebuildDone, done() || Date.now.timeIntervalSince(rebuildStart) > 10 { rebuildDone = nil; waitingForMotion = true }
        let engineBusy: Bool
        switch engine.playbackPhase {
        case .loading, .seeking, .rebuffering, .stalled: engineBusy = true     // long seeks, network buffering
        default: engineBusy = false
        }
        if waitingForMotion, !engineBusy, moved || isPaused || ended { waitingForMotion = false }
        let busy = rebuildDone != nil || waitingForMotion || engineBusy
        if !busy { busySince = nil } else if busySince == nil { busySince = .now }
        // A short delay so instant switches and quick seeks never flash it.
        let show = busySince.map { Date.now.timeIntervalSince($0) >= 0.15 } ?? false
        if show != showSpinner { showSpinner = show }
    }

    /// Track lists and chapters arrive after load and can be republished (Atmos confirmation).
    private func syncTracks() {
        let a = engine.audioTracks, s = engine.subtitleTracks
        let an = a.map(audioName), sn = s.map(subtitleName)        // readable names (Library.swift)
        if a.map(\.id) != audioIDs || an != audioTracks { audioIDs = a.map(\.id); audioTracks = an }
        if s.map(\.id) != subtitleIDs || sn != subtitleTracks { subtitleIDs = s.map(\.id); subtitleTracks = sn }
        currentTrack = audioIDs.firstIndex(of: engine.activeAudioTrackIndex ?? -1) ?? -1
        currentSubtitle = engine.isSubtitleActive ? (subtitleIDs.firstIndex(of: engine.activeSubtitleTrackIndex ?? -1) ?? -1) : -1
        // Styled ASS / SSA: libass draws it; other kinds go through the text / bitmap overlay.
        let activeID = engine.isSubtitleActive ? (engine.activeSubtitleTrackIndex ?? -1) : -1
        if activeID != assTrackID {
            let track = s.first { $0.id == activeID }
            let codec = track?.codec.lowercased() ?? ""
            if codec == "ass" || codec == "ssa" {
                // An added .ass file publishes its header after decoding: retry next tick until it is there.
                if let h = track?.assHeader ?? engine.sidecarASSHeader {
                    assTrackID = activeID
                    ass.activate(header: h) { [weak self] in self?.subtitleDelay ?? 0 }
                }
            } else { assTrackID = activeID; ass.deactivate() }
        }
        let c = engine.discChapters.isEmpty ? engine.mediaChapters : engine.discChapters   // discs publish their own
        if c.count != chapters.count || c.first?.startSeconds != chapters.first?.time {
            chapters = c.map { (time: $0.startSeconds, title: $0.name) }
        }
    }

    // MARK: keep the display awake while playing (IOKit assertion, like every media app)
    private var sleepAssertion: IOPMAssertionID = 0
    private var resetObserver: NSObjectProtocol?
    private func updateSleep(playing: Bool) {
        if playing && sleepAssertion == 0 {
            // Video keeps the display on; music only keeps the Mac awake.
            let kind = audioOnly ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
            IOPMAssertionCreateWithName(kind as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Playing video" as CFString, &sleepAssertion)
        } else if !playing {
            allowSleep()
        }
    }
    private func allowSleep() {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
    }

    // MARK: transport
    func togglePlay() {
        if ended { seek(to: 0); engine.play() }
        else if isPaused { engine.play() } else { engine.pause() }
        isPaused = engine.state == .paused
        poke()
    }
    func seek(to t: Double) {
        let c = isLive ? (liveRange.map { min(max(t, $0.lowerBound), $0.upperBound) } ?? t)
                       : max(0, min(duration > 0 ? duration : t, t))
        position = c; ended = false; poke()
        Task { await engine.seek(to: c) }
    }
    func goLive() { Task { await engine.seekToLiveEdge() }; poke() }
    func skip(_ delta: Double) { seek(to: position + delta) }
    /// Arrow keys, media keys, skip buttons: by chapter when Skip mode is Chapters and the file has them, else by the set interval.
    func skip(forward: Bool) {
        if Settings.skipMode == "chapters", !chapters.isEmpty { forward ? nextChapter() : prevChapter() }
        else { skip(forward ? Settings.skipForward : -Settings.skipBackward) }
    }
    func nextChapter() { if let c = chapters.first(where: { $0.time > position + 0.5 }) { seek(to: c.time) } }
    func prevChapter() {
        let here = position - 2                                   // 2 s grace: jump to the start of this one first
        if let c = chapters.last(where: { $0.time <= here }) { seek(to: c.time) } else { seek(to: 0) }
    }
    func setRate(_ r: Double) { engine.setRate(Float(r)); rate = r; poke() }
    func selectTrack(_ i: Int) {
        guard i >= 0, i < audioIDs.count else { return }
        let id = audioIDs[i]
        if engine.activeAudioTrackIndex != id { beginRebuild { [weak self] in self?.engine.activeAudioTrackIndex == id } }   // the engine rebuilds for a new track
        engine.selectAudioTrack(index: id); currentTrack = i; poke()
    }
    func selectSubtitle(_ i: Int) {
        if i >= 0, i < subtitleIDs.count { engine.selectSubtitleTrack(index: subtitleIDs[i]); currentSubtitle = i }
        else { engine.clearSubtitle(); currentSubtitle = -1 }
        poke()
    }
    static let subtitleExts: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "idx", "sup", "smi", "ttml"]
    /// Subtitles > Add Subtitle File… or a subtitle file dropped on the window: listed and selected.
    func addSubtitleFile(_ url: URL) {
        let t = engine.addExternalSubtitleTrack(ExternalSubtitleTrack(url: url, name: url.deletingPathExtension().lastPathComponent))
        engine.selectSubtitleTrack(index: t.id)
        poke()
    }
    func cycleSubtitle() { guard !subtitleTracks.isEmpty else { return }
        selectSubtitle(currentSubtitle + 1 >= subtitleTracks.count ? -1 : currentSubtitle + 1) }
    func cycleAudio() { guard audioTracks.count > 1 else { return }; selectTrack((currentTrack + 1) % audioTracks.count) }

    // MARK: sleep timer (shared across files, so a 60 min timer survives the next episode)
    enum SleepTimer: Equatable, Hashable {
        case off, endOfFile, minutes(Int)
        var title: String {
            switch self {
            case .off: "Off"
            case .endOfFile: "End of Episode"
            case .minutes(let m): "\(m) Minutes"
            }
        }
        static let choices: [SleepTimer] = [.off, .endOfFile, .minutes(30), .minutes(60), .minutes(90)]
    }
    private static var sleepMode: SleepTimer = .off
    private static var sleepDeadline: Date?
    @Published private(set) var sleepTimer: SleepTimer = PlayerModel.sleepMode
    func setSleepTimer(_ t: SleepTimer) {
        Self.sleepMode = t; sleepTimer = t
        if case .minutes(let m) = t { Self.sleepDeadline = .now + Double(m) * 60 } else { Self.sleepDeadline = nil }
        flash(t == .off ? "Sleep Timer Off" : "Sleep Timer: \(t.title)")
    }
    private func fireSleepTimer() {
        Self.sleepMode = .off; Self.sleepDeadline = nil; sleepTimer = .off
        if !isPaused && !ended { engine.pause(); isPaused = true }
        controlsVisible = true
        flash("Sleep Timer: Paused")
    }

    // MARK: Skip Intro / Skip Credits / Up Next (from chapter names)
    enum ChapterKind { case intro, recap, credits }
    /// "Intro", "Opening", "OP", "Recap", "Previously…" / "Credits", "End Credits", "ED", "Ending".
    static func chapterKind(_ title: String) -> ChapterKind? {
        let t = title.lowercased().trimmingCharacters(in: .whitespaces)
        if t.contains("recap") || t.hasPrefix("previously") { return .recap }
        if t.contains("intro") || t.hasPrefix("opening") || t.range(of: #"^op\s*\d*$"#, options: .regularExpression) != nil { return .intro }
        if t.contains("credits") || t.hasPrefix("ending") || t.range(of: #"^ed\s*\d*$"#, options: .regularExpression) != nil { return .credits }
        return nil
    }
    /// Self-check for selftest: chapter names map to the right button.
    static func chapterKindSelfTest() -> [String] {
        let cases: [(String, ChapterKind?)] = [("Intro", .intro), ("Opening", .intro), ("OP", .intro), ("Opening Credits", .intro),
            ("Recap", .recap), ("Previously on", .recap), ("Credits", .credits), ("End Credits", .credits), ("ED", .credits),
            ("Ending", .credits), ("Chapter 3", nil), ("Ed's Story", nil), ("Operation", nil)]
        return cases.filter { chapterKind($0.0) != $0.1 }.map { "chapterKind \($0.0)" }
    }
    private var chapterIndex: Int? { chapters.lastIndex { $0.time <= position + 0.25 } }
    /// The Skip button for the chapter playing now: its label and where it jumps (the chapter's end).
    var skipButton: (label: String, to: Double)? {
        guard !placeholder, !ended, !isLive, let i = chapterIndex, let kind = Self.chapterKind(chapters[i].title) else { return nil }
        let end = i + 1 < chapters.count ? chapters[i + 1].time : duration
        guard end - position > 1 else { return nil }
        switch kind {
        case .intro:   return ("Skip Intro", end)
        case .recap:   return ("Skip Recap", end)
        case .credits: return upNext == nil ? ("Skip Credits", end) : nil     // the Up Next card replaces it
        }
    }

    struct UpNext: Equatable { let label: String; let countdown: Int? }
    @Published var upNext: UpNext?
    private var upNextSince: Double?            // position when the card appeared (the countdown runs on playback time)
    private var upNextDismissed = false
    private lazy var nextEpisode: (path: String, label: String)? = {
        guard !placeholder, let it = Library.shared.items.first(where: { $0.path == path }), it.isEpisode else { return nil }
        let eps = Library.shared.episodes(of: it)          // same order as the app's continuous playback
        guard let i = eps.firstIndex(where: { $0.path == path }), i + 1 < eps.count else { return nil }
        let n = eps[i + 1]
        return (n.path, Library.shared.playerTitle(n.path)?.0 ?? n.episodeLabel)
    }()
    /// Shown in the last credits chapter, or the last 30 s; with continuous playback on it counts down 10 s.
    private func updateUpNext() {
        let lastCredits = chapterIndex == chapters.count - 1 && chapters.last.map { Self.chapterKind($0.title) == .credits } == true
        guard !isLive, !ended, !upNextDismissed, duration > 60, lastCredits || duration - position <= 30,
              let next = nextEpisode else {
            upNextSince = nil
            if upNext != nil { upNext = nil }
            return
        }
        let since = upNextSince ?? position
        upNextSince = since
        var count: Int?
        if Settings.continuousPlayback && sleepTimer != .endOfFile {
            let left = 10 - (position - since)
            if left <= 0 { playNextNow(); return }
            count = Int(left.rounded(.up))
        }
        let u = UpNext(label: next.label, countdown: count)
        if u != upNext { upNext = u }
    }
    func playNextNow() {
        guard let n = nextEpisode else { return }
        upNextDismissed = true; upNext = nil
        onPlayNext(n.path)
    }
    func dismissUpNext() { upNextDismissed = true; upNext = nil }

    // MARK: metadata badges (Apple TV style)
    var badges: [String] {
        var b: [String] = []
        if !audioOnly { b.append(resolutionLabel(width: videoWidth, height: videoHeight)) }
        if hdrIsDolby { b.append("Dolby Vision") }
        else if let l = hdrLabel { b.append(l.hasPrefix("SDR") ? "SDR" : String(l.prefix { $0 != " " })) }
        if currentTrack >= 0 && currentTrack < engine.audioTracks.count {
            let t = engine.audioTracks[currentTrack]
            if t.isAtmos { b.append("Dolby Atmos") }
            else if t.name.contains("DTS:X") { b.append("DTS:X") }
            else if t.name.contains("DTS-HD") { b.append("DTS-HD") }
            if t.channels >= 8 { b.append("7.1") } else if t.channels >= 6 { b.append("5.1") }
        }
        if !subtitleTracks.isEmpty { b.append("CC") }
        return b
    }

    func nudgeVolume(_ d: Double) { muted = false; volume = max(0, min(1, volume + d)); poke() }

    // MARK: scrubbing
    func beginScrub() { isScrubbing = true; scrubValue = position; poke() }
    func endScrub()   { isScrubbing = false; seek(to: scrubValue) }

    // MARK: auto-hide controls
    // The controls fade after `autoHideInterval` of a still pointer, even
    // when it rests on them — only active scrubbing or an open panel keeps them up.
    func poke() {
        guard !placeholder else { return }      // the loading screen keeps its controls up
        controlsVisible = true
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.isPaused, !self.ended, !self.isScrubbing,
                  !self.showTrackPanel, !self.showInfo, !self.showKeyHelp, !self.audioOnly else { return }
            self.controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideInterval, execute: w)
    }

    /// A click on the picture shows or hides the controls — it never pauses
    /// (play/pause stays on Space and the button).
    func toggleControls() {
        guard !placeholder else { return }
        if controlsVisible {
            guard !ended else { return }          // keep the replay button up at the end
            controlsVisible = false
            hideWork?.cancel()
            NSCursor.setHiddenUntilMouseMoves(true)
        } else {
            poke()
        }
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// "Spider-Man.Brand.New.Day.2026.2160p.MA.WEB-DL.mkv" -> ("Spider-Man Brand New Day", "2026")
/// "(2017) Blade Runner 2049 [1080p] [Open Matte].mkv" -> ("Blade Runner 2049", "2017")
func cleanTitle(_ path: String) -> (String, String?) {
    var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    if path.contains("://") { name = name.removingPercentEncoding ?? name }     // network stream
    var year: String?
    if let r = name.range(of: #"^\s*[\(\[]((19|20)\d{2})[\)\]]\s*"#, options: .regularExpression) {   // year first
        year = String(name[r].filter(\.isNumber)); name = String(name[r.upperBound...])
    }
    name = name.replacingOccurrences(of: #"[\[{][^\]}]*[\]}]"#, with: " ", options: .regularExpression)   // [1080p] [Blu-Ray] {…]
    if !name.contains(" ") { name = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }
    if year == nil, let r = name.range(of: #"[\(\[ ]((19|20)\d{2})[\)\] ]?(?=\s|$)"#, options: .regularExpression),
       r.lowerBound > name.startIndex {
        year = String(name[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ()[]"))
        name = String(name[..<r.lowerBound])
    } else if let r = name.range(of: #"\s(2160p|1080p|720p|480p|4K|UHD|BluRay|WEB-DL|WEBRip|HDR|DV)\b"#, options: [.regularExpression, .caseInsensitive]) {
        name = String(name[..<r.lowerBound])
    }
    let t = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
    return (t.isEmpty ? (path as NSString).lastPathComponent : t, year)
}

extension Double { func rounded(toPlaces p: Int) -> Double { let m = pow(10.0, Double(p)); return (self*m).rounded()/m } }
