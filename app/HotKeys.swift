import AppKit
import SwiftUI

// Editable keyboard shortcuts (settings-v2 step 5). One registry for the menu key equivalents
// and the player's bare-key monitor. Stored in UserDefaults "hotKeys" as
// [action rawValue: "cmd+shift+a"]; a missing entry means the default, "" means no key.
enum HotKeys {
    enum Group: String, CaseIterable { case file = "File", playback = "Playback", video = "Video",
                                            audio = "Audio", subtitles = "Subtitles", window = "Window" }

    // "(player)" actions are the bare keys of the player window's key monitor; the others are menu items.
    enum Action: String, CaseIterable {
        case open, openURL, close, settings, hide, quit
        case playPause, skipBack, skipForward, skipBackKey, skipForwardKey, prevChapter, nextChapter,
             prevVideo, nextVideo, speedUp, slowDown, normalSpeed, resetAdjustments
        case info, infoKey, discTitle, saveFrame, dolbyVision, dolbyVisionKey
        case cycleAudio, cycleAudioKey, mute, muteKey, volumeUp, volumeDown,
             audioDelayPlus, audioDelayMinus, audioDelayPlusKey, audioDelayMinusKey
        case toggleSubtitles, cycleSubtitles, cycleSubtitlesKey, addSubtitleFile, subDelayPlus, subDelayMinus
        case fullScreen, fullScreenKey, closePanels, library, minimize, keyHelp

        var title: String { info.title }
        var group: Group { info.group }
        var defaultSpec: String { info.spec }

        private var info: (title: String, group: Group, spec: String) {
            switch self {
            case .open:               ("Open…", .file, "cmd+o")
            case .openURL:            ("Open URL…", .file, "cmd+u")
            case .close:              ("Close", .file, "cmd+w")
            case .settings:           ("Settings…", .file, "cmd+,")
            case .hide:               ("Hide Specular", .file, "cmd+h")
            case .quit:               ("Quit Specular", .file, "cmd+q")
            case .playPause:          ("Play / Pause", .playback, "space")
            case .skipBack:           ("Skip Back", .playback, "cmd+[")
            case .skipForward:        ("Skip Forward", .playback, "cmd+]")
            case .skipBackKey:        ("Skip Back (player)", .playback, "left")
            case .skipForwardKey:     ("Skip Forward (player)", .playback, "right")
            case .prevChapter:        ("Previous Chapter", .playback, "cmd+left")
            case .nextChapter:        ("Next Chapter", .playback, "cmd+right")
            case .prevVideo:          ("Previous Video", .playback, "cmd+up")
            case .nextVideo:          ("Next Video", .playback, "cmd+down")
            case .speedUp:            ("Speed Up", .playback, "cmd+>")
            case .slowDown:           ("Slow Down", .playback, "cmd+<")
            case .normalSpeed:        ("Normal Speed", .playback, "cmd+0")
            case .resetAdjustments:   ("Reset Speed & Delays", .playback, "cmd+shift+0")
            case .info:               ("Playback Info", .video, "cmd+i")
            case .infoKey:            ("Playback Info (player)", .video, "i")
            case .discTitle:          ("Disc Title…", .video, "cmd+opt+t")
            case .saveFrame:          ("Save Frame", .video, "cmd+shift+s")
            case .dolbyVision:        ("Dolby Vision", .video, "cmd+shift+d")
            case .dolbyVisionKey:     ("Dolby Vision, this film (player)", .video, "d")
            case .cycleAudio:         ("Cycle Audio Track", .audio, "cmd+shift+a")
            case .cycleAudioKey:      ("Cycle Audio Track (player)", .audio, "a")
            case .mute:               ("Mute", .audio, "cmd+m")
            case .muteKey:            ("Mute (player)", .audio, "m")
            case .volumeUp:           ("Increase Volume", .audio, "up")
            case .volumeDown:         ("Decrease Volume", .audio, "down")
            case .audioDelayPlus:     ("Audio Delay +50 ms", .audio, "cmd+shift+=")
            case .audioDelayMinus:    ("Audio Delay −50 ms", .audio, "cmd+shift+-")
            case .audioDelayPlusKey:  ("Audio Delay +50 ms (player)", .audio, "k")
            case .audioDelayMinusKey: ("Audio Delay −50 ms (player)", .audio, "j")
            case .toggleSubtitles:    ("Toggle Subtitles", .subtitles, "cmd+shift+c")
            case .cycleSubtitles:     ("Cycle Subtitles Track", .subtitles, "cmd+opt+s")
            case .cycleSubtitlesKey:  ("Cycle Subtitles Track (player)", .subtitles, "s")
            case .addSubtitleFile:    ("Add Subtitle File…", .subtitles, "cmd+opt+o")
            case .subDelayPlus:       ("Subtitle Delay +50 ms", .subtitles, "cmd+opt+=")
            case .subDelayMinus:      ("Subtitle Delay −50 ms", .subtitles, "cmd+opt+-")
            case .fullScreen:         ("Enter Full Screen", .window, "cmd+ctrl+f")
            case .fullScreenKey:      ("Full Screen (player)", .window, "f")
            case .closePanels:        ("Close Panels / Exit Full Screen (player)", .window, "esc")
            case .library:            ("Library", .window, "cmd+l")
            case .minimize:           ("Minimize", .window, "cmd+m")   // same as Mute today: Mute wins
            case .keyHelp:            ("Keyboard Shortcuts (player)", .window, "?")   // typed as ⇧/
            }
        }
    }

    typealias Binding = (key: String, modifiers: NSEvent.ModifierFlags)

    static let changed = Notification.Name("HotKeysChanged")
    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
    private static let storeKey = "hotKeys"
    private static let names: [String: String] = ["space": " ", "esc": "\u{1b}", "left": "\u{F702}",
        "right": "\u{F703}", "up": "\u{F700}", "down": "\u{F701}", "return": "\r", "tab": "\t"]
    private static let mods: [(String, NSEvent.ModifierFlags)] =
        [("cmd", .command), ("shift", .shift), ("opt", .option), ("ctrl", .control)]

    private static var stored: [String: String] {
        UserDefaults.standard.dictionary(forKey: storeKey) as? [String: String] ?? [:]
    }

    /// Key equivalent (menu form: a character, or "\u{F700}"… for arrows) and modifiers; key "" = none.
    static func binding(for a: Action) -> Binding { parse(stored[a.rawValue] ?? a.defaultSpec) }

    static func set(_ b: Binding, for a: Action) {
        var d = stored; d[a.rawValue] = encode(b)
        UserDefaults.standard.set(d, forKey: storeKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The action bound to this keyDown (bare or modified), first in Action order on a tie.
    static func action(for ev: NSEvent) -> Action? {
        let m = ev.modifierFlags.intersection(modifierMask)
        let base = ev.characters(byApplyingModifiers: [])?.lowercased() ?? ""
        let plain = ev.charactersIgnoringModifiers ?? ""
        let s = stored
        return Action.allCases.first { a in
            let b = parse(s[a.rawValue] ?? a.defaultSpec)
            guard !b.key.isEmpty else { return false }
            // Second form: shifted-character defaults like ⌘> (typed as ⌘⇧.).
            return (b.key == base && b.modifiers == m) || (b.key == plain && b.modifiers == m.subtracting(.shift))
        }
    }

    /// The action other than `a` that already uses `b`, if any.
    static func conflict(_ b: Binding, with a: Action) -> Action? {
        guard !b.key.isEmpty else { return nil }
        return Action.allCases.first { $0 != a && binding(for: $0) == b }
    }

    /// The binding as macOS menus show it: ⌃⌥⇧⌘ then the key.
    static func symbols(_ b: Binding) -> String {
        guard !b.key.isEmpty else { return "None" }
        var s = ""
        if b.modifiers.contains(.control) { s += "⌃" }
        if b.modifiers.contains(.option) { s += "⌥" }
        if b.modifiers.contains(.shift) { s += "⇧" }
        if b.modifiers.contains(.command) { s += "⌘" }
        switch b.key {
        case " ": return s + "Space"
        case "\u{1b}": return s + "Esc"
        case "\u{F702}": return s + "←"
        case "\u{F703}": return s + "→"
        case "\u{F700}": return s + "↑"
        case "\u{F701}": return s + "↓"
        case "\r": return s + "↩"
        case "\t": return s + "⇥"
        case "\u{7f}", "\u{8}": return s + "⌫"
        default:
            if let u = b.key.unicodeScalars.first?.value, (0xF704...0xF70F).contains(u) { return s + "F\(u - 0xF703)" }
            return s + b.key.uppercased()
        }
    }

    static func parse(_ spec: String) -> Binding {
        guard !spec.isEmpty else { return ("", []) }
        var parts = spec.hasSuffix("+") ? spec.dropLast().split(separator: "+") + ["+"] : spec.split(separator: "+")
        let key = String(parts.removeLast())
        var m: NSEvent.ModifierFlags = []
        for p in parts { if let f = mods.first(where: { $0.0 == p })?.1 { m.insert(f) } }
        return (names[key] ?? key, m)
    }

    static func encode(_ b: Binding) -> String {
        guard !b.key.isEmpty else { return "" }
        let key = names.first(where: { $0.value == b.key })?.key ?? b.key
        return (mods.filter { b.modifiers.contains($0.1) }.map(\.0) + [key]).joined(separator: "+")
    }

    /// Self-check for selftest: every default round-trips, and defaults collide only where they do today.
    static func selfTest() -> [String] {
        var fails: [String] = []
        for a in Action.allCases where encode(parse(a.defaultSpec)) != a.defaultSpec { fails.append("round-trip \(a)") }
        if encode(parse("cmd++")) != "cmd++" { fails.append("round-trip cmd++") }
        for a in Action.allCases {
            if let c = Action.allCases.first(where: { $0 != a && parse($0.defaultSpec) == parse(a.defaultSpec) }),
               Set([a, c]) != [.mute, .minimize] { fails.append("default clash \(a) / \(c)") }
        }
        return fails
    }
}

/// Settings > Hot Keys: one Section per group, double-click (or Record) to set a key, Esc cancels.
struct HotKeysSettingsSection: View {
    @State private var tick = 0                       // bumps on HotKeys.changed so rows re-read
    @State private var recording: HotKeys.Action?
    @State private var monitor: Any?
    @State private var clash: (action: HotKeys.Action, binding: HotKeys.Binding, other: HotKeys.Action)?

    var body: some View {
        let _ = tick
        ForEach(HotKeys.Group.allCases, id: \.self) { g in
            Section(g.rawValue) {
                ForEach(HotKeys.Action.allCases.filter { $0.group == g }, id: \.self) { a in row(a) }
            }
        }
        Section {
            Button("Reset All") { stopRecording(); HotKeys.reset() }
        } footer: {
            Text("Double-click a shortcut to record a new one; Esc cancels. Keys marked (player) work in the player window only.")
        }
        .onReceive(NotificationCenter.default.publisher(for: HotKeys.changed)) { _ in tick += 1 }
        .onDisappear { stopRecording() }
        .alert(clash.map { "\(HotKeys.symbols($0.binding)) is used by “\($0.other.title)”" } ?? "",
               isPresented: Binding(get: { clash != nil }, set: { if !$0 { clash = nil } })) {
            Button("Replace") {
                if let c = clash { HotKeys.set(("", []), for: c.other); HotKeys.set(c.binding, for: c.action) }
                clash = nil
            }
            Button("Cancel", role: .cancel) { clash = nil }
        } message: {
            Text("Replace gives it to “\(clash?.action.title ?? "")” and leaves the other action without a key.")
        }
    }

    private func row(_ a: HotKeys.Action) -> some View {
        HStack {
            Text(a.title)
            Spacer()
            Text(recording == a ? "Type a shortcut…" : HotKeys.symbols(HotKeys.binding(for: a)))
                .foregroundStyle(recording == a ? .secondary : .primary)
                .monospacedDigit()
            Button(recording == a ? "Cancel" : "Record") { recording == a ? stopRecording() : startRecording(a) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { startRecording(a) }
    }

    private func startRecording(_ a: HotKeys.Action) {
        stopRecording()
        recording = a
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let m = ev.modifierFlags.intersection(HotKeys.modifierMask)
            let key = ev.characters(byApplyingModifiers: [])?.lowercased() ?? ""
            stopRecording()
            if key == "\u{1b}" && m.isEmpty || key.isEmpty { return nil }   // bare Esc cancels
            let b: HotKeys.Binding = (key, m)
            if let other = HotKeys.conflict(b, with: a) { clash = (a, b, other) } else { HotKeys.set(b, for: a) }
            return nil                                // swallow it: no menu item or player action fires
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = nil
    }
}
