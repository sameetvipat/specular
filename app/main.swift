import AppKit
import SwiftUI
import AetherEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var libraryWindow: NSWindow?        // LibraryView.swift
    var model: PlayerModel?
    /// One playback engine for the app's lifetime; each file is a `load` on it.
    private lazy var engine: AetherEngine? = {
        do { return try AetherEngine() } catch { fputs("AetherEngine init failed: \(error)\n", stderr); return nil }
    }()
    var surface: AetherPlayerView?
    var bright: BrightVideo?            // HDR Colors = Specular (BrightVideo.swift)
    private var openedViaEvent = false
    private var openSerial = 0          // newest play() request; older opens are discarded
    private var opening = false         // a file is being opened in the background
    private var loadingView: NSView?    // loading screen laid over a playing film
    private var loadingWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var blackoutWindows: [NSWindow] = []    // Settings > Black out other displays
    private var jellyfinTimer: Timer?                // progress reports to a Jellyfin server, every 10 s
    // menu state (used by Menu.swift)
    var currentPath: String?
    var floatOnTop = false
    var floatItem: NSMenuItem?
    var dvItem: NSMenuItem?
    var dialogueItem: NSMenuItem?, nightItem: NSMenuItem?, loudnessItem: NSMenuItem?
    var lastSub = -1

    // Finder double-click / drag onto the Dock icon / `open file.mkv`
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedViaEvent = true
        play(url.path)
    }

    let selfTest = ProcessInfo.processInfo.environment["PLAYER_SELFTEST"] != nil

    func applicationDidFinishLaunching(_ note: Notification) {
        if !selfTest {                       // self-test: don't steal focus or take input
            NSApp.activate(ignoringOtherApps: true)
            buildMainMenu()
            installKeyboardShortcuts()
            setupNowPlaying()
        }
        UserDefaults.standard.removeObject(forKey: "hdrOutput")   // legacy key, no longer used
        UserDefaults.standard.removeObject(forKey: "tmdbKey")     // legacy: the key is built in now (TMDBKey.swift)
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
        // Command-line path (swift run player <file>) — ignore Finder's -psn_ args.
        let env = ProcessInfo.processInfo.environment
        if let dir = env["PLAYER_LIBTEST"] { libraryTest(dir); return }
        if let f = env["PLAYER_METATEST"] { metadataTest(f); return }
        if let f = env["PLAYER_INFOTEST"] { infoTest(f); return }
        if env["PLAYER_UNITTEST"] != nil { unitTest(); return }
        let args = CommandLine.arguments.dropFirst().filter { $0.contains("://") || FileManager.default.fileExists(atPath: $0) }
        if let p = args.first {
            if env["PLAYER_PANELTEST"] != nil { panelTest(p); return }
            let audioID = env["PLAYER_AUDIOID"].flatMap { Int($0) }       // test: a track chosen before Play
            play(p, tracks: audioID.map { TrackChoice(audio: $0) }); return
        }
        DispatchQueue.main.async { [weak self] in       // nothing to play yet: the library is home
            guard let self, !self.openedViaEvent, self.model == nil else { return }
            self.showLibrary()
        }
    }

    /// File > Open URL…: play a network stream (http, https, ftp, rtmp…; whatever FFmpeg reads).
    func showOpenURL() {
        let a = NSAlert()
        a.messageText = "Open URL"
        a.informativeText = "Address of a video or audio stream."
        let field = NSTextField(frame: NSRect(x: 0, y: 30, width: 420, height: 24))
        field.placeholderString = "https://example.com/film.mkv"
        field.stringValue = UserDefaults.standard.string(forKey: "lastURL") ?? ""
        let live = NSButton(checkboxWithTitle: "Live stream (TV / IPTV, 30-minute rewind)", target: nil, action: nil)
        live.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
        box.addSubview(field); box.addSubview(live)
        a.accessoryView = box
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let s = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains("://"), URL(string: s) != nil else { return }
        UserDefaults.standard.set(s, forKey: "lastURL")
        play(s, live: live.state == .on)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true                  // a BDMV / VIDEO_TS disc folder
        panel.allowsMultipleSelection = false
        panel.message = "Choose a file to play"
        if panel.runModal() == .OK, let p = panel.url?.path { play(p) }
        else if model == nil && libraryWindow?.isVisible != true { NSApp.terminate(nil) }
    }

    /// Opening reads the file (stream info, tracks), which can take seconds on a slow share;
    /// it is an async `load` on the engine. A newer open supersedes an older one.
    /// `tracks`: audio / subtitle chosen on the library's detail page (engine track ids; subtitle -1 = off).
    func play(_ path: String, live: Bool = false, start: Double? = nil, tracks: TrackChoice? = nil) {
        guard let engine else { return }
        if path != currentPath { leaveCurrentFilm() }     // before the D override below is replaced
        let saved = FilmChoices.load(path)
        if path != currentPath { Settings.dolbyVisionOverride = saved?.dolbyVision; dvItem?.state = Settings.dolbyVisionNow ? .on : .off }   // the D override is per film (and remembered)
        let tracks = tracks ?? saved.map { TrackChoice(audio: $0.audio, subtitle: $0.subtitle) }     // last choice for this film
        openSerial += 1
        opening = true
        let serial = openSerial
        showLoading(path)
        let slow = Double(ProcessInfo.processInfo.environment["PLAYER_SLOWOPEN"] ?? "") ?? 0   // test: fake a slow disk
        let url = path.contains("://") ? URL(string: path) : URL(fileURLWithPath: path)
        Task {
            if slow > 0 { try? await Task.sleep(for: .seconds(slow)) }
            var options = LoadOptions(audioOnly: Self.isAudioFile(path))
            Self.applySettings(&options, path: path)
            if live { options.isLive = true; options.dvrWindowSeconds = 1800 }
            options.confirmAtmos = true                      // honest Atmos label on audio tracks
            options.preserveASSMarkup = true                 // ASS / SSA raw events for libass
            // Audio (and, when on by default, subtitles) in the user's languages, not whatever track
            // the file flags "default" (e.g. a Russian dub ahead of the English original).
            let langs = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
            // A language chosen in Settings > Language goes first; the system languages stay as the fallback.
            func first(_ l: String) -> [String] { l == "auto" ? langs : [l] + langs.filter { $0 != l } }
            options.preferredAudioLanguages = first(Settings.audioLanguage)
            if Settings.subtitlesDefaultOn { options.preferredSubtitleLanguages = first(Settings.subtitleLanguage) }
            if let s = tracks?.subtitle, s >= 0 { options.initialSubtitleTrackID = s }     // wins over the languages
            var probe: SourceProbe?
            var failed = url == nil
            if let url, serial == openSerial {
                self.model?.shutdown()                      // the old model stops polling; load replaces the session
                self.model = nil
                let start = start ?? Double(ProcessInfo.processInfo.environment["PLAYER_START"] ?? "") ?? PlayerModel.resumePosition(path) ?? Jellyfin.shared.resumePosition(forStream: path)
                do {
                    if let disc = DiscFolder.root(of: path) {       // BDMV / VIDEO_TS folder
                        probe = try await engine.load(source: .custom(DiscFolder(disc)), startPosition: start, options: options)
                    } else { probe = try await engine.load(url: url, startPosition: start, options: options) }
                }
                catch { failed = true; fputs("load failed: \(error)\n", stderr) }
            }
            guard serial == self.openSerial else { return }    // superseded by a newer open
            self.opening = false
            if failed { self.hideLoading() }                    // before the error alert
            self.finishOpen(path, failed ? nil : probe, tracks: tracks)
            self.hideLoading()                                  // after the player window is up
        }
    }

    /// The LoadOptions that come from Settings. Used at load and for a live change (`settingsChanged`).
    static func applySettings(_ o: inout LoadOptions, path: String) {
        o.forceDolbyVisionOnNonDVDisplay = Settings.dolbyVisionNow      // Apple composes DV on every Mac
        o.dolbyVisionHandling = Settings.dolbyVisionNow ? .automatic : .baseLayerOnly
        o.preferDualLayerDolbyVision = Settings.dolbyVisionNow && Settings.dualLayerDV
        o.dualLayerRoute = .avPlayerOutput                          // AVPlayer keeps the audio (Atmos survives)
        o.audioShaping = Settings.shaping
        o.audioBridgeMode = Settings.losslessBridge ? .lossless : .surroundCompat
        o.objectAudioRendering = Settings.objectAudio               // TrueHD Atmos / DTS:X heights (traits on)
        o.forwardBufferSegments = path.contains("://") && Settings.readAhead > 0 ? Settings.readAhead : nil
    }

    /// A Settings change applies to the playing film at once: the engine rebuilds at the playhead
    /// (about 0.3 s). If it cannot rebuild in place, the file reopens at the same position.
    private var lastSettings = Settings.playbackSignature
    func settingsChanged() {
        NowPlaying.shared.setSkipIntervals()
        dialogueItem?.state = Settings.dialogueLift ? .on : .off     // the Settings window can flip these too
        nightItem?.state = Settings.nightMode ? .on : .off
        loudnessItem?.state = Settings.levelLoudness ? .on : .off
        updateBlackout()
        let sig = Settings.playbackSignature
        guard sig != lastSettings else { return }      // resume saves etc. also post didChange
        lastSettings = sig
        dvItem?.state = Settings.dolbyVisionNow ? .on : .off
        reloadPlaying()
    }

    /// D key / Video menu: Dolby Vision on or off for this film only; the saved setting stays.
    func toggleDolbyVision() {
        Settings.dolbyVisionOverride = !Settings.dolbyVisionNow
        dvItem?.state = Settings.dolbyVisionNow ? .on : .off
        model?.flash(Settings.dolbyVisionNow ? "Dolby Vision" : "HDR10")
        reloadPlaying()
    }

    private func reloadPlaying() {
        guard let engine, let m = model, let path = currentPath else { return }
        m.beginRebuild()                                // spinner over the dimmed picture while it rebuilds
        Task {
            defer { m.endRebuild() }
            do { try await engine.reloadAtCurrentPosition { Self.applySettings(&$0, path: path) } }
            catch {
                fputs("settings: in-place reload refused (\(type(of: error))), reopening\n", stderr)
                self.play(path, start: m.position)
            }
        }
    }

    private static func isAudioFile(_ path: String) -> Bool {
        ["mp3", "flac", "m4a", "aac", "wav", "aiff", "aif", "ogg", "opus", "alac", "wma", "ac3", "eac3", "dts", "thd", "mka"]
            .contains((path as NSString).pathExtension.lowercased())
    }

    /// Loading screen inside the player window: the player screen itself (title, controls shown but
    /// inert) with a spinner on black, shown only when the open takes longer than a moment so local
    /// files never flash it. With a film already playing it is laid over the picture; otherwise the
    /// player window appears with it.
    private func showLoading(_ path: String) {
        hideLoading()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.opening, let engine = self.engine else { return }
            let stub = PlayerModel(engine: engine, path: path, probe: nil, placeholder: true)
            let view = NSHostingView(rootView: PlayerView(model: stub, surface: NSView()))
            if self.model != nil, let content = self.window?.contentView {       // over the current film
                view.frame = content.bounds
                view.autoresizingMask = [.width, .height]
                content.addSubview(view)
                self.loadingView = view
            } else {                                                             // no player yet: open one
                let win = self.window ?? self.makeWindow()
                win.contentView = view
                if !win.isVisible { win.setContentSize(NSSize(width: 960, height: 540)); win.center() }
                if self.selfTest { win.orderFrontRegardless() } else { win.makeKeyAndOrderFront(nil) }
                self.window = win
                self.libraryWindow?.orderOut(nil)
            }
            if self.selfTest { print("LOADING shown") }
        }
        loadingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    /// The overlay goes away here; a loading-only window is taken over by `finishOpen`, or
    /// put away if the open failed.
    private func hideLoading() {
        loadingWork?.cancel(); loadingWork = nil
        loadingView?.removeFromSuperview(); loadingView = nil
        if model == nil, !opening { window?.orderOut(nil) }
    }

    /// `probe` nil = the load failed.
    private func finishOpen(_ path: String, _ probe: SourceProbe?, tracks: TrackChoice? = nil) {
        guard let engine, let probe else {
            let a = NSAlert()
            a.messageText = "Can't open this file"
            a.informativeText = (path as NSString).lastPathComponent
            a.runModal()
            if model == nil { if libraryWindow != nil { showLibrary() } else { showOpenPanel() } }
            return
        }
        currentPath = path
        if !selfTest && !path.contains("://") { NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path)) }

        let view = surface ?? AetherPlayerView()
        if surface == nil {
            engine.bind(view: view); surface = view
            bright = BrightVideo(engine: engine, surface: view)
            bright?.onChange = { [weak self] on in if self?.selfTest == true { print("BRIGHT \(on ? "on" : "off")") } }
        }
        let vh = Double(probe.videoHeight)                                // 0 = audio-only file
        let h = vh > 0 ? vh : 540, w = vh > 0 ? Double(probe.videoWidth) : 960

        let m = PlayerModel(engine: engine, path: path, probe: probe)
        m.onOpen = { [weak self] in self?.showOpenPanel() }
        m.onDropFile = { [weak self, weak m] p in
            if PlayerModel.subtitleExts.contains((p as NSString).pathExtension.lowercased()) { m?.addSubtitleFile(URL(fileURLWithPath: p)) }
            else { self?.play(p) }
        }
        m.onToggleFullScreen = { [weak self] in self?.window?.toggleFullScreen(nil) }
        m.onPlayNext = { [weak self] p in self?.play(p) }      // Up Next card: Play Now / countdown
        m.onEnded = { [weak self, weak m] in
            Jellyfin.shared.reportStopped(url: path, position: m?.duration ?? 0, finished: true)      // marks it watched there
            self?.playNextEpisode(after: path)
        }
        m.onControlsVisible = { [weak self] shown in
            // Window buttons fade with the controls, as in the TV app.
            guard let win = self?.window else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    win.standardWindowButton(b)?.animator().alphaValue = shown ? 1 : 0
                }
            }
        }
        model = m
        Jellyfin.shared.reportStart(url: path, position: m.position)       // no-op for local files
        jellyfinTimer?.invalidate()
        jellyfinTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let m = self?.model, self?.currentPath == path else { return }
                Jellyfin.shared.reportProgress(url: path, position: m.position, paused: m.isPaused)
            }
        }

        let win = window ?? makeWindow()
        let scale = min(1.0, min(1280.0 / w, 720.0 / h))
        let size = NSSize(width: w * scale, height: h * scale)
        win.title = m.displayTitle
        win.contentView = NSHostingView(rootView: PlayerView(model: m, surface: view))
        if !win.styleMask.contains(.fullScreen) { win.setContentSize(size); win.center() }
        if selfTest { win.ignoresMouseEvents = true; win.orderFrontRegardless() }
        else { win.makeKeyAndOrderFront(nil) }
        win.level = floatOnTop ? .floating : .normal
        window = win
        libraryWindow?.orderOut(nil)                     // back when the player window closes

        let subtitlesOff = tracks?.subtitle == -1 || (tracks?.subtitle == nil && !Settings.subtitlesDefaultOn)
        if !selfTest, subtitlesOff { m.selectSubtitle(-1) }
        if let a = tracks?.audio, engine.activeAudioTrackIndex != a {       // no load option for audio: switch at once
            m.beginRebuild { engine.activeAudioTrackIndex == a }
            engine.selectAudioTrack(index: a)
        }
        print("playing \(Int(w))x\(Int(h)), duration \(probe.durationSeconds)s, route \(engine.videoRoute), " +
              "source \(engine.sourceVideoFormat)")
        if selfTest, let f = ProcessInfo.processInfo.environment["PLAYER_SUBFILE"] { m.addSubtitleFile(URL(fileURLWithPath: f)) }
        if selfTest, ProcessInfo.processInfo.environment["PLAYER_SETTINGTEST"] != nil {   // live settings: on, then back off
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Settings.nightMode.toggle(); print("SETTINGTEST night \(Settings.nightMode)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                print("SETTINGTEST engine shaping \(engine.audioShaping.summary), \(engine.audioShapingState)")
                Settings.nightMode.toggle(); print("SETTINGTEST night \(Settings.nightMode)") }
        }
        if selfTest, let t = ProcessInfo.processInfo.environment["PLAYER_PAUSEAT"].flatMap(Double.init) {   // test: hold one frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { m.seek(to: t) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if !m.isPaused { m.togglePlay() } }
        }
        if selfTest, let s = ProcessInfo.processInfo.environment["PLAYER_PLAYFOR"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                let audio = m.currentTrack >= 0 && m.currentTrack < m.audioTracks.count ? m.audioTracks[m.currentTrack] : "none"
                print("PLAYFOR done at \(m.position)s, audio \"\(audio)\" of \(m.audioTracks.count), subtitles \(m.currentSubtitle) of \(m.subtitleTracks.count)")
                let cues = engine.subtitleCues
                print("PLAYFOR subtitle active \(engine.isSubtitleActive), loading \(engine.isLoadingSubtitles), track \(engine.activeSubtitleTrackIndex ?? -1)")
                print("PLAYFOR cues \(cues.count), sample: \(cues.first.map { "\($0.startTime)-\($0.endTime) \($0.text ?? "image")" } ?? "none")")
                NSApp.terminate(nil)
            }
        } else if selfTest, ProcessInfo.processInfo.environment["PLAYER_PANELTEST"] == nil { transportTest(m) }
    }

    func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.collectionBehavior.insert(.fullScreenPrimary)
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.delegate = self
        return win
    }

    /// Continuous playback: a library episode that ends is followed by the next one of its show.
    private func playNextEpisode(after path: String) {
        guard Settings.continuousPlayback, !selfTest, path == currentPath,
              let it = Library.shared.items.first(where: { $0.path == path }), it.isEpisode else { return }
        let eps = Library.shared.episodes(of: it)
        if let i = eps.firstIndex(where: { $0.path == path }), i + 1 < eps.count { play(eps[i + 1].path) }
    }

    /// Black windows over every screen but the full-screen player's, while it is full screen and the setting is on.
    func updateBlackout() {
        let on = Settings.blackoutOtherScreens && model != nil && window?.styleMask.contains(.fullScreen) == true
        blackoutWindows.forEach { $0.orderOut(nil) }; blackoutWindows = []
        guard on, let playerScreen = window?.screen else { return }
        for screen in NSScreen.screens where screen != playerScreen {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.backgroundColor = .black
            w.level = .statusBar                                      // above that screen's menu bar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.isReleasedWhenClosed = false
            w.orderFrontRegardless()
            blackoutWindows.append(w)
        }
    }

    /// The film being left (closed, quit, or replaced by another): tell Jellyfin, remember the track choices.
    private func leaveCurrentFilm() {
        jellyfinTimer?.invalidate(); jellyfinTimer = nil
        guard let m = model, !m.placeholder, let path = currentPath else { return }
        Jellyfin.shared.reportStopped(url: path, position: m.position, finished: false)
        if !selfTest, let e = engine {
            FilmChoices.save(path, FilmChoices(audio: e.activeAudioTrackIndex,
                                               subtitle: e.isSubtitleActive ? e.activeSubtitleTrackIndex : -1,
                                               dolbyVision: Settings.dolbyVisionOverride))
        }
    }

    func teardownCurrent() {
        if !selfTest { NowPlaying.shared.clear() }
        leaveCurrentFilm()
        model?.shutdown()
        model = nil
        engine?.stop()
    }

    private func installKeyboardShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, let m = self.model, ev.window === self.window else { return ev }
            // Bare keys come from the editable list (HotKeys.swift); menu shortcuts are handled by the menu itself.
            guard let action = HotKeys.action(for: ev) else { return ev }
            switch action {
            case .playPause:          m.togglePlay()
            case .skipBackKey:        m.skip(forward: false)
            case .skipForwardKey:     m.skip(forward: true)
            case .volumeUp:           m.nudgeVolume(0.1)
            case .volumeDown:         m.nudgeVolume(-0.1)
            case .fullScreenKey:      self.window?.toggleFullScreen(nil)
            case .muteKey:            m.muted.toggle()
            case .cycleSubtitlesKey:  m.cycleSubtitle()
            case .cycleAudioKey:      m.cycleAudio()
            case .infoKey:            m.showInfo.toggle(); m.poke()
            case .dolbyVisionKey:     self.toggleDolbyVision()
            case .audioDelayMinusKey: m.nudgeAudioDelay(-0.05)       // lip sync
            case .audioDelayPlusKey:  m.nudgeAudioDelay(0.05)
            case .keyHelp:            m.showKeyHelp.toggle()
            case .closePanels where m.showTrackPanel || m.showInfo || m.showKeyHelp:  // Esc closes panels first
                m.showTrackPanel = false; m.showInfo = false; m.showKeyHelp = false
            case .closePanels:
                if self.window?.styleMask.contains(.fullScreen) == true { self.window?.toggleFullScreen(nil) } else { return ev }
            default:                  return ev               // menu actions: the menu handles them
            }
            return nil
        }
    }

    private func setupNowPlaying() {
        let np = NowPlaying.shared
        np.setupCommands()
        np.onToggle = { [weak self] in self?.model?.togglePlay() }
        np.onPlay   = { [weak self] in if self?.model?.isPaused == true { self?.model?.togglePlay() } }
        np.onPause  = { [weak self] in if self?.model?.isPaused == false { self?.model?.togglePlay() } }
        np.onSkip   = { [weak self] fwd in self?.model?.skip(forward: fwd) }
        np.onSeek   = { [weak self] t in self?.model?.seek(to: t) }
        np.onNext   = { [weak self] in self?.mNext() }
        np.onPrev   = { [weak self] in self?.mPrev() }
    }

    // While a file is still opening there is no player window yet: closing the Open panel
    // (the only window) must not quit the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !opening }
    func applicationWillTerminate(_ note: Notification) { teardownCurrent() }
}

/// The audio track, subtitle track (-1 = off) and D-key Dolby Vision choice last used for a film,
/// restored the next time it opens. Keyed like resume positions: a stream URL without its query (no api_key).
struct FilmChoices: Codable {
    var audio: Int?
    var subtitle: Int?
    var dolbyVision: Bool?
    private static let key = "filmChoices"
    private static func id(_ path: String) -> String { path.contains("://") ? String(path.prefix { $0 != "?" }) : path }
    static func load(_ path: String) -> FilmChoices? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: FilmChoices].self, from: d) else { return nil }
        return all[id(path)]
    }
    static func save(_ path: String, _ c: FilmChoices) {
        var all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: FilmChoices].self, from: $0) } ?? [:]
        all[id(path)] = c
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }
}

setvbuf(stdout, nil, _IONBF, 0)   // unbuffered logs (visible even when piped)
// Full-screen blackout, like the Apple TV app: the picture goes black for the zoom
// animation, then snaps back once the window has settled. Controls are untouched.
extension AppDelegate: NSWindowDelegate {
    private static let fsDebug = ProcessInfo.processInfo.environment["PLAYER_DEBUG"] != nil

    private func blackout(_ why: String) {
        surface?.alphaValue = 0
        if Self.fsDebug { print("[fullscreen] \(why): video hidden") }
    }
    private func reveal(_ why: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in   // let the window settle
            self?.surface?.alphaValue = 1                                         // snap back, no fade
            if Self.fsDebug { print("[fullscreen] \(why): video shown") }
        }
    }
    /// Closing the player stops playback and goes back to the library (it used to quit the app).
    func windowWillClose(_ n: Notification) {
        guard (n.object as? NSWindow) === window, !selfTest else { return }
        if model == nil {                               // closed on the loading screen: drop that open
            guard opening else { return }
            openSerial += 1; opening = false
            hideLoading(); showLibrary()
            return
        }
        teardownCurrent()
        currentPath = nil
        updateBlackout()                                // model is gone: the black screens go too
        window?.contentView = NSView()                  // drop the views that point at the closed engine
        showLibrary()
    }
    func windowWillEnterFullScreen(_ n: Notification)      { blackout("will enter") }
    func windowWillExitFullScreen(_ n: Notification)       { blackout("will exit"); blackoutWindows.forEach { $0.orderOut(nil) }; blackoutWindows = [] }
    func windowDidEnterFullScreen(_ n: Notification)       { reveal("did enter"); updateBlackout() }
    func windowDidExitFullScreen(_ n: Notification)        { reveal("did exit") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { reveal("failed enter") }
    func windowDidFailToExitFullScreen(_ window: NSWindow)  { reveal("failed exit") }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
