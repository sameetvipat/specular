import AppKit
import SwiftUI
import AetherEngine

// App settings, stored in UserDefaults and read where used. Only options that are wired.
enum Settings {
    static var resumeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "resumeEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "resumeEnabled") }
    }
    // Separate forward / back skips; the old single "skipSeconds" value seeds both.
    private static var legacySkip: Double { let v = UserDefaults.standard.double(forKey: "skipSeconds"); return v > 0 ? v : 10 }
    static var skipForward: Double {
        get { let v = UserDefaults.standard.double(forKey: "skipForward"); return v > 0 ? v : legacySkip }
        set { UserDefaults.standard.set(newValue, forKey: "skipForward") }
    }
    static var skipBackward: Double {
        get { let v = UserDefaults.standard.double(forKey: "skipBackward"); return v > 0 ? v : legacySkip }
        set { UserDefaults.standard.set(newValue, forKey: "skipBackward") }
    }
    /// Kept for PlayerView's button symbols; the forward interval.
    static var skipSeconds: Double { skipForward }
    // "time" = skip by the intervals above, "chapters" = to the next / previous chapter when the file has them.
    static var skipMode: String { UserDefaults.standard.string(forKey: "skipMode") ?? "time" }
    // At the end of a library episode, play the next one of the same show.
    static var continuousPlayback: Bool { UserDefaults.standard.object(forKey: "continuousPlayback") as? Bool ?? true }
    // Full screen player: cover every other screen in black.
    static var blackoutOtherScreens: Bool { UserDefaults.standard.bool(forKey: "blackoutOtherScreens") }
    // Plain gain on top of the audio shaping, dB (0, 3, 6, 9, 12).
    static var volumeBoostDB: Int { UserDefaults.standard.integer(forKey: "volumeBoostDB") }
    // "auto" (system languages) or an ISO 639-1 code; put first in the engine's track choice.
    static var audioLanguage: String { UserDefaults.standard.string(forKey: "audioLanguage") ?? "auto" }
    static var subtitleLanguage: String { UserDefaults.standard.string(forKey: "subtitleLanguage") ?? "auto" }
    static var subtitlesDefaultOn: Bool {
        get { UserDefaults.standard.object(forKey: "subtitlesDefaultOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "subtitlesDefaultOn") }
    }
    // TrueHD / DTS-HD (no fMP4 stream copy) re-encode: true = FLAC (lossless, up to 7.1),
    // false = E-AC-3 (lossy, 5.1, for a legacy-ARC soundbar).
    static var losslessBridge: Bool {
        get { UserDefaults.standard.object(forKey: "losslessBridge") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "losslessBridge") }
    }
    // TrueHD Atmos / DTS:X objects rendered into this speaker bed ("off" = 7.1 channel decode).
    static var heightsLayout: String {
        get { UserDefaults.standard.string(forKey: "heightsLayout") ?? SpatialSpeakerLayout.l714.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "heightsLayout") }
    }
    // Dolby Vision on (composed by macOS on every display) or off (HDR10 / HLG base layer).
    static var dolbyVision: Bool {
        get { UserDefaults.standard.object(forKey: "dolbyVision") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dolbyVision") }
    }
    // D key / Video > Dolby Vision: this film only (user, 2026-11-15). In memory, cleared when a new file opens.
    static var dolbyVisionOverride: Bool?
    /// What playback uses: the per-film override, else the saved setting.
    static var dolbyVisionNow: Bool { dolbyVisionOverride ?? dolbyVision }
    // HDR Colors: "specular" = Specular draws HDR itself (BrightVideo.swift, IINA-style), "apple" = macOS maps it
    // (as QuickTime). Default Specular (user, 2026-11-15). Read live by BrightVideo every frame.
    static var hdrColors: String {
        get { UserDefaults.standard.string(forKey: "hdrColors") ?? "specular" }
        set { UserDefaults.standard.set(newValue, forKey: "hdrColors") }
    }
    // Profile 7 FEL: full dual-layer decode (AVPlayer plays the base layer, Aether adds the FEL).
    static var dualLayerDV: Bool {
        get { UserDefaults.standard.object(forKey: "dualLayerDV") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dualLayerDV") }
    }
    // Audio shaping: live, from the Audio menu. Any of them moves Atmos onto the PCM bridge.
    static var dialogueLift: Bool {
        get { UserDefaults.standard.bool(forKey: "dialogueLift") }
        set { UserDefaults.standard.set(newValue, forKey: "dialogueLift") }
    }
    static var nightMode: Bool {
        get { UserDefaults.standard.bool(forKey: "nightMode") }
        set { UserDefaults.standard.set(newValue, forKey: "nightMode") }
    }
    static var levelLoudness: Bool {
        get { UserDefaults.standard.bool(forKey: "levelLoudness") }
        set { UserDefaults.standard.set(newValue, forKey: "levelLoudness") }
    }
    static var shaping: AudioShaping {
        // Boost rides on the compressor's makeup gain: ratio 1 is a plain gain; with Night Mode it adds to
        // the night makeup (10 + 12 = 22 dB max, inside the engine's 24 dB clamp). The engine's -1 dBFS limiter stops clipping.
        let boost = Double(volumeBoostDB)
        var comp: AudioShaping.Compressor? = nightMode ? .night : (boost > 0 ? .init(thresholdDB: 0, ratio: 1) : nil)
        comp?.makeupGainDB += boost
        return AudioShaping(dialogueGainDB: dialogueLift ? 6 : 0, compressor: comp,
                            loudnessTargetLUFS: levelLoudness ? -24 : nil)
    }
    // Network streams: read-ahead in 4 s segments (0 = engine default, about 40 s).
    static var readAhead: Int {
        get { UserDefaults.standard.integer(forKey: "readAhead") }
        set { UserDefaults.standard.set(newValue, forKey: "readAhead") }
    }
    static var objectAudio: ObjectAudioRendering {
        SpatialSpeakerLayout(rawValue: heightsLayout).map { .render($0) } ?? .off
    }
    // Subtitle look (read live by the overlay). Style 0 = the system caption style, as the Apple TV
    // app draws it; 1 = the custom look from the keys below.
    static var subStyle: Int {
        get { UserDefaults.standard.integer(forKey: "subStyle") }
        set { UserDefaults.standard.set(newValue, forKey: "subStyle") }
    }
    static var subColor: Int {
        get { UserDefaults.standard.object(forKey: "subColor") as? Int ?? 0xFFFFFF }
        set { UserDefaults.standard.set(newValue, forKey: "subColor") }
    }
    static var subOutline: Int {
        get { UserDefaults.standard.object(forKey: "subOutline") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue, forKey: "subOutline") }
    }
    static var subBgPct: Int {
        get { UserDefaults.standard.object(forKey: "subBgPct") as? Int ?? 60 }
        set { UserDefaults.standard.set(newValue, forKey: "subBgPct") }
    }
    static var subPosition: Int {
        get { UserDefaults.standard.integer(forKey: "subPosition") }
        set { UserDefaults.standard.set(newValue, forKey: "subPosition") }
    }
    static let keys = ["hdrColors", "statsForNerds", "resumeEnabled","skipSeconds","subtitlesDefaultOn","losslessBridge","heightsLayout","dolbyVision","dualLayerDV",
                       "dialogueLift","nightMode","levelLoudness","readAhead",
                       "subStyle","subColor","subOutline","subBgPct","subPosition","subtitleScale",
                       "skipForward","skipBackward","skipMode","continuousPlayback","blackoutOtherScreens","volumeBoostDB",
                       "audioLanguage","subtitleLanguage","metadataLanguage",
                       "showFilenames","showPosterTitles","showWatchedIndicators","showUpNext","hideSpoilers","tmdbCollections",
                       "customCollections","preferEmbeddedArtwork","preferLocalArtwork","preferLocalMetadata","ratingIMDb","ratingRT","ratingTMDB"]
    /// Every setting that becomes a LoadOptions field; a change here reloads the playing film.
    static var playbackSignature: String {
        "\(dolbyVision) \(dualLayerDV) \(losslessBridge) \(heightsLayout) \(readAhead) \(dialogueLift) \(nightMode) \(levelLoudness) \(volumeBoostDB)"
    }
    static func resetAll() { for k in keys { UserDefaults.standard.removeObject(forKey: k) }; HotKeys.reset() }
}

@MainActor
enum SettingsWindow {
    private static var win: NSWindow?
    static func show() {
        if let w = win { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        // Apple TV app look: icon + label tabs in the toolbar, one form per tab; the window fits each tab.
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        for t in SettingsTab.allCases {
            let host = NSHostingController(rootView: t.view)
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = t.rawValue
            item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.rawValue)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex { $0.rawValue == UserDefaults.standard.string(forKey: "settingsPane") } ?? 0
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        tabs.fit(animate: false)
        w.center()
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        win = w
    }
}

/// Toolbar tabs that resize the window (keeping its top edge) to the chosen tab's size.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        if let item { UserDefaults.standard.set(item.label, forKey: "settingsPane") }
        fit(animate: true)
    }
    // A tab whose rows change (Subtitles: custom style) grows or shrinks the window too.
    override func preferredContentSizeDidChange(for vc: NSViewController) {
        super.preferredContentSizeDidChange(for: vc)
        if vc === tabViewItems[selectedTabViewItemIndex].viewController { fit(animate: true) }
    }
    func fit(animate: Bool) {
        guard let w = view.window, let vc = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        let size = vc.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        var f = w.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        f.origin = NSPoint(x: w.frame.minX, y: w.frame.maxY - f.height)
        w.setFrame(f, display: true, animate: animate)
    }
}

/// The tabs. @AppStorage in each tab uses the keys and defaults of `Settings` above.
enum SettingsTab: String, CaseIterable {
    case general = "General", playback = "Playback", video = "Video", audio = "Audio",
         subtitles = "Subtitles & Language", library = "Library", metadata = "Metadata", hotKeys = "Hot Keys"
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.rectangle"
        case .video: "tv"
        case .audio: "speaker.wave.2"
        case .subtitles: "captions.bubble"
        case .library: "books.vertical"
        case .metadata: "photo.on.rectangle"
        case .hotKeys: "keyboard"
        }
    }
    @MainActor var view: AnyView {
        switch self {
        case .general: AnyView(SettingsForm { GeneralSettings() })
        case .playback: AnyView(SettingsForm { PlaybackSettings() })
        case .video: AnyView(SettingsForm { VideoSettings() })
        case .audio: AnyView(SettingsForm { AudioSettings() })
        case .subtitles: AnyView(SettingsForm { SubtitleSettings() })
        case .library: AnyView(SettingsForm { LibrarySettingsSection() })
        case .metadata: AnyView(SettingsForm { MetadataSettingsSection() })
        // Too many rows for one screen: a scrolling grouped list at a fixed height.
        case .hotKeys: AnyView(Form { HotKeysSettingsSection() }.formStyle(.grouped).frame(width: 620, height: 520))
        }
    }
}

// Form pieces shared by the tabs: a two-column grid with right-aligned "Label:" captions.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) { content }
            .padding(.vertical, 24).padding(.horizontal, 30)
            .frame(width: 620)
    }
}

/// One row: the caption on the left (right-aligned, with a colon), controls stacked on the right.
func settingsRow<C: View>(_ label: String, @ViewBuilder _ controls: () -> C) -> some View {
    GridRow {
        Text(label.isEmpty ? "" : label + ":").gridColumnAlignment(.trailing)
        VStack(alignment: .leading, spacing: 6) { controls() }
    }
}

/// Grey help text under a group, in the controls column.
func settingsNote(_ text: String) -> some View {
    GridRow {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: 380, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }
}

/// A line between groups, across both columns.
func settingsDivider() -> some View { Divider().padding(.vertical, 4).gridCellUnsizedAxes(.horizontal) }

private struct GeneralSettings: View {
    var body: some View {
        settingsRow("Settings") {
            Button("Reset All Settings to Defaults") {
                Settings.resetAll()     // @AppStorage follows the removed keys
                NotificationCenter.default.post(name: .init("ResetAdjustments"), object: nil)
            }
        }
    }
}

private struct PlaybackSettings: View {
    @AppStorage("resumeEnabled") private var resume = true
    @AppStorage("skipForward") private var skipFwd = Settings.skipForward
    @AppStorage("skipBackward") private var skipBack = Settings.skipBackward
    @AppStorage("skipMode") private var skipMode = "time"
    @AppStorage("continuousPlayback") private var continuous = true
    @AppStorage("blackoutOtherScreens") private var blackout = false
    @AppStorage("readAhead") private var readAhead = 0
    private static let skipChoices: [Double] = [5, 10, 15, 30, 60]      // all have gobackward / goforward symbols

    var body: some View {
        settingsRow("Resume") { Toggle("Resume where you left off", isOn: $resume) }
        settingsRow("Skip mode") {
            Picker("", selection: $skipMode) { Text("Time").tag("time"); Text("Chapters").tag("chapters") }.labelsHidden().fixedSize()
        }
        settingsRow("Skip forward") {
            Picker("", selection: $skipFwd) { ForEach(Self.skipChoices, id: \.self) { Text("\(Int($0)) seconds").tag($0) } }.labelsHidden().fixedSize()
        }
        settingsRow("Skip back") {
            Picker("", selection: $skipBack) { ForEach(Self.skipChoices, id: \.self) { Text("\(Int($0)) seconds").tag($0) } }.labelsHidden().fixedSize()
        }
        settingsNote("Chapters skips to the next or previous chapter; files without chapters skip by time.")
        settingsDivider()
        settingsRow("Episodes") { Toggle("Play next episode automatically", isOn: $continuous) }
        settingsRow("Full screen") { Toggle("Black out other displays", isOn: $blackout) }
        settingsDivider()
        settingsRow("Read ahead") {
            Picker("", selection: $readAhead) {
                Text("40 seconds").tag(0); Text("5 minutes").tag(75); Text("Whole film").tag(2700)
            }.labelsHidden().fixedSize()
        }
        settingsNote("For streams opened by URL. More read-ahead rides out network drops but uses disk "
                     + "(4K is about 2.5 MB per second). SMB / NAS shares: mount them in Finder and add the folder to the library.")
    }
}

private struct VideoSettings: View {
    @AppStorage("dolbyVision") private var dv = true
    @AppStorage("hdrColors") private var hdrColors = "specular"

    var body: some View {
        settingsRow("HDR Colors") {
            Picker("", selection: $hdrColors) { Text("Specular").tag("specular"); Text("Apple").tag("apple") }.labelsHidden().fixedSize()
        }
        settingsRow("Dolby Vision") { Toggle("Use Dolby Vision", isOn: $dv) }
        settingsNote("Specular draws HDR itself and is brighter on most Macs. Apple matches QuickTime. Dolby Vision on XDR displays, and Profile 5 or Profile 7 FEL files, always use Apple's Dolby Vision. D in the player switches Dolby Vision for the current film only.")
    }
}

private struct AudioSettings: View {
    @AppStorage("losslessBridge") private var lossless = true
    @AppStorage("heightsLayout") private var heights = SpatialSpeakerLayout.l714.rawValue
    @AppStorage("dialogueLift") private var dialogue = false
    @AppStorage("nightMode") private var night = false
    @AppStorage("levelLoudness") private var loudness = false
    @AppStorage("volumeBoostDB") private var boost = 0

    var body: some View {
        settingsRow("Atmos / DTS:X heights") {
            Picker("", selection: $heights) {
                Text("Off (7.1)").tag("off")
                ForEach(SpatialSpeakerLayout.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }.labelsHidden().fixedSize()
        }
        settingsRow("Lossless") { Toggle("Lossless TrueHD / DTS-HD (FLAC)", isOn: $lossless) }
        settingsNote("Heights renders TrueHD Atmos and DTS:X objects into the chosen speaker layout; macOS mixes it "
                     + "down for headphones or built-in speakers. Turn lossless off only for a soundbar on legacy ARC. "
                     + "E-AC-3 Atmos always plays through Apple's decoder.")
        settingsDivider()
        settingsRow("Sound") {
            Toggle("Dialogue lift", isOn: $dialogue)
            Toggle("Night mode", isOn: $night)
            Toggle("Level loudness", isOn: $loudness)
        }
        settingsRow("Volume boost") {
            Picker("", selection: $boost) {
                Text("Off").tag(0)
                ForEach([3, 6, 9, 12], id: \.self) { Text("+\($0) dB").tag($0) }
            }.labelsHidden().fixedSize()
        }
        settingsNote("Any of these moves Atmos onto the PCM path. A limiter keeps boosted sound from clipping.")
    }
}

private struct SubtitleSettings: View {
    @AppStorage("subtitlesDefaultOn") private var subsOn = true
    @AppStorage("subStyle") private var subStyle = 0
    @AppStorage("subColor") private var subColor = 0xFFFFFF
    @AppStorage("subOutline") private var subOutline = 1
    @AppStorage("subBgPct") private var subBg = 60
    @AppStorage("subPosition") private var subPos = 0
    @AppStorage("audioLanguage") private var audioLang = "auto"
    @AppStorage("subtitleLanguage") private var subLang = "auto"
    @AppStorage("metadataLanguage") private var metaLang = "auto"

    private static let languages = ["en", "fr", "de", "es", "it", "pt", "nl", "sv", "da", "no", "fi", "pl", "cs", "hu", "el",
                                    "ru", "uk", "tr", "ar", "he", "hi", "th", "ja", "ko", "zh"]
    private static let regions = ["en-US", "en-GB", "fr-FR", "de-DE", "es-ES", "es-MX", "it-IT", "pt-BR", "pt-PT", "nl-NL",
                                  "sv-SE", "da-DK", "nb-NO", "fi-FI", "pl-PL", "ru-RU", "tr-TR", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "hi-IN"]
    private func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    var body: some View {
        settingsRow("Subtitles") { Toggle("Show subtitles automatically", isOn: $subsOn) }
        settingsRow("Style") {
            Picker("", selection: $subStyle) { Text("System (like Apple TV)").tag(0); Text("Custom").tag(1) }.labelsHidden().fixedSize()
            if subStyle == 0 {
                Button("Open Captions Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Captioning")!)
                }
            }
        }
        if subStyle == 1 {
            settingsRow("Text color") {
                Picker("", selection: $subColor) {
                    Text("White").tag(0xFFFFFF); Text("Yellow").tag(0xFFEB3B); Text("Soft Gray").tag(0xDDDDDD)
                }.labelsHidden().fixedSize()
            }
            settingsRow("Edge") {
                Picker("", selection: $subOutline) {
                    Text("None").tag(0); Text("Outline").tag(1); Text("Shadow").tag(2); Text("Box").tag(3)
                }.labelsHidden().fixedSize()
            }
            if subOutline == 3 {
                settingsRow("Box opacity") {
                    Picker("", selection: $subBg) { Text("25%").tag(25); Text("50%").tag(50); Text("75%").tag(75); Text("100%").tag(100) }
                        .labelsHidden().fixedSize()
                }
            }
            settingsRow("Position") {
                Picker("", selection: $subPos) { Text("Low").tag(0); Text("Higher").tag(30); Text("Highest").tag(80) }.labelsHidden().fixedSize()
            }
        }
        settingsNote((subStyle == 0 ? "Change the system style in System Settings > Accessibility > Captions. " : "")
                     + "Size is in the player's Subtitles panel.")
        settingsDivider()
        settingsRow("Audio language") { languagePicker($audioLang, Self.languages) }
        settingsRow("Subtitle language") { languagePicker($subLang, Self.languages) }
        settingsRow("Metadata language") { languagePicker($metaLang, Self.regions) }
        settingsNote("The chosen language comes first; your system languages follow when a file has no track in it. "
                     + "Metadata is the language of titles and descriptions in the library.")
    }

    private func languagePicker(_ sel: Binding<String>, _ ids: [String]) -> some View {
        Picker("", selection: sel) {
            Text("Automatic (System)").tag("auto")
            ForEach(ids, id: \.self) { Text(name($0)).tag($0) }
        }.labelsHidden().fixedSize()
    }
}
