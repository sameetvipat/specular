import AppKit
import UniformTypeIdentifiers

// macOS menu bar, standard video-player commands. Items forward
// to the current PlayerModel / window via the AppDelegate; key equivalents come from HotKeys
// (bare-key "(player)" actions stay on the key monitor in main.swift).
extension AppDelegate {
    static let mediaExts: Set<String> = libraryVideoExts.union(
        ["m4a","mp3","flac","wav","aiff","aac","ogg","opus","mka","ac3","ec3","eac3","thd","dts"])

    func buildMainMenu() {
        // Key equivalents come from HotKeys; rebuild the whole bar when the user edits one.
        if Self.hotKeysObserver == nil {
            Self.hotKeysObserver = NotificationCenter.default.addObserver(forName: HotKeys.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.buildMainMenu() }
            }
        }
        let main = NSMenu()
        let appName = ProcessInfo.processInfo.processName

        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        add(appMenu, "Settings…", #selector(openSettings), .settings)
        appMenu.addItem(.separator())
        add(appMenu, "Hide \(appName)", #selector(NSApplication.hide(_:)), .hide, targeted: false)
        add(appMenu, "Quit \(appName)", #selector(NSApplication.terminate(_:)), .quit, targeted: false)
        appItem.submenu = appMenu; main.addItem(appItem)

        let fileItem = NSMenuItem(); let fileMenu = NSMenu(title: "File")
        add(fileMenu, "Open…", #selector(menuOpen), .open)
        add(fileMenu, "Open URL…", #selector(menuOpenURL), .openURL)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = recentMenu; fileMenu.addItem(recent)
        fileMenu.addItem(.separator())
        add(fileMenu, "Close", #selector(NSWindow.performClose(_:)), .close, targeted: false)
        fileItem.submenu = fileMenu; main.addItem(fileItem)

        // Standard text editing (search fields, Settings) plus Find for the library search.
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        for (title, sel, key) in [("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("", nil, ""),
                                  ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
                                  ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] as [(String, Selector?, String)] {
            if let sel { editMenu.addItem(withTitle: title, action: sel, keyEquivalent: key) } else { editMenu.addItem(.separator()) }
        }
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "Find in Library", action: #selector(mFind), keyEquivalent: "f")
        find.target = self; editMenu.addItem(find)
        editItem.submenu = editMenu; main.addItem(editItem)

        let playItem = NSMenuItem(); let playMenu = NSMenu(title: "Playback")
        add(playMenu, "Play / Pause", #selector(mPlay), .playPause)
        add(playMenu, "Skip Back", #selector(mBack), .skipBack)
        add(playMenu, "Skip Forward", #selector(mFwd), .skipForward)
        playMenu.addItem(.separator())
        add(playMenu, "Previous Chapter", #selector(mPrevChapter), .prevChapter)
        add(playMenu, "Next Chapter", #selector(mNextChapter), .nextChapter)
        playMenu.addItem(.separator())
        add(playMenu, "Previous Video", #selector(mPrev), .prevVideo)
        add(playMenu, "Next Video", #selector(mNext), .nextVideo)
        playMenu.addItem(.separator())
        add(playMenu, "Speed Up", #selector(mSpeedUp), .speedUp)
        add(playMenu, "Slow Down", #selector(mSpeedDown), .slowDown)
        add(playMenu, "Normal Speed", #selector(mSpeedNormal), .normalSpeed)
        playMenu.addItem(.separator())
        add(playMenu, "Reset Speed & Delays", #selector(mResetAdjust), .resetAdjustments)
        playMenu.addItem(.separator())
        let sleep = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: ""); let sleepMenu = NSMenu(title: "Sleep Timer")
        for (i, t) in PlayerModel.SleepTimer.choices.enumerated() {
            let it = add(sleepMenu, t.title, #selector(mSleep(_:)), nil); it.tag = i
        }
        sleep.submenu = sleepMenu; playMenu.addItem(sleep)
        playItem.submenu = playMenu; main.addItem(playItem)

        let audioItem = NSMenuItem(); let audioMenu = NSMenu(title: "Audio")
        add(audioMenu, "Cycle Audio Track", #selector(mCycleAudio), .cycleAudio)
        add(audioMenu, "Mute", #selector(mMute), .mute)
        add(audioMenu, "Increase Volume", #selector(mVolUp), .volumeUp)
        add(audioMenu, "Decrease Volume", #selector(mVolDown), .volumeDown)
        audioMenu.addItem(.separator())
        add(audioMenu, "Audio Delay +50 ms", #selector(mAudioDelayPlus), .audioDelayPlus)
        add(audioMenu, "Audio Delay −50 ms", #selector(mAudioDelayMinus), .audioDelayMinus)
        add(audioMenu, "Reset Audio Delay", #selector(mAudioDelayReset), nil)
        audioMenu.addItem(.separator())
        dialogueItem = add(audioMenu, "Dialogue Lift", #selector(mDialogue), nil)
        nightItem = add(audioMenu, "Night Mode", #selector(mNight), nil)
        loudnessItem = add(audioMenu, "Level Loudness", #selector(mLoudness), nil)
        dialogueItem?.state = Settings.dialogueLift ? .on : .off
        nightItem?.state = Settings.nightMode ? .on : .off
        loudnessItem?.state = Settings.levelLoudness ? .on : .off
        audioItem.submenu = audioMenu; main.addItem(audioItem)

        let subItem = NSMenuItem(); let subMenu = NSMenu(title: "Subtitles")
        add(subMenu, "Toggle Subtitles", #selector(mToggleSubs), .toggleSubtitles)
        add(subMenu, "Cycle Subtitles Track", #selector(mCycleSubs), .cycleSubtitles)
        add(subMenu, "Add Subtitle File…", #selector(mAddSubFile), .addSubtitleFile)
        add(subMenu, "Teletext Page…", #selector(mTeletext), nil)
        subMenu.addItem(.separator())
        add(subMenu, "Subtitle Delay +50 ms", #selector(mSubDelayPlus), .subDelayPlus)
        add(subMenu, "Subtitle Delay −50 ms", #selector(mSubDelayMinus), .subDelayMinus)
        add(subMenu, "Reset Subtitle Delay", #selector(mSubDelayReset), nil)
        subItem.submenu = subMenu; main.addItem(subItem)

        let videoItem = NSMenuItem(); let videoMenu = NSMenu(title: "Video")
        add(videoMenu, "Playback Info", #selector(mInfo), .info)
        add(videoMenu, "Keyboard Shortcuts", #selector(mKeyHelp), nil)
        add(videoMenu, "Disc Title…", #selector(mDiscTitle), .discTitle)
        add(videoMenu, "Save Frame", #selector(mSaveFrame), .saveFrame)
        let dvItem = add(videoMenu, "Dolby Vision", #selector(mDolbyVision), .dolbyVision)
        dvItem.state = Settings.dolbyVisionNow ? .on : .off
        self.dvItem = dvItem
        videoItem.submenu = videoMenu; main.addItem(videoItem)

        let winItem = NSMenuItem(); let winMenu = NSMenu(title: "Window")
        add(winMenu, "Enter Full Screen", #selector(mFullScreen), .fullScreen)
        floatItem = add(winMenu, "Float On Top", #selector(mFloat), nil)
        floatItem?.state = floatOnTop ? .on : .off          // survives a rebuild
        add(winMenu, "Picture in Picture", #selector(mPiP), nil)
        add(winMenu, "Library", #selector(mLibrary), .library)
        winMenu.addItem(.separator())
        add(winMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), .minimize, targeted: false)
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu; main.addItem(winItem)

        NSApp.mainMenu = main
    }

    private static var hotKeysObserver: (any NSObjectProtocol)?

    /// Player-only items are greyed out while no film is open; App, File and Window > Library stay enabled.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let playerOnly: Set<Selector> = [#selector(mFullScreen), #selector(mFloat), #selector(mPiP)]
        if item.action == #selector(mSleep(_:)) {           // check mark on the current sleep timer
            item.state = model?.sleepTimer == PlayerModel.SleepTimer.choices[item.tag] ? .on : .off
        }
        if ["Playback", "Audio", "Subtitles", "Video", "Sleep Timer"].contains(item.menu?.title ?? "") || item.action.map(playerOnly.contains) == true {
            return model != nil
        }
        return true
    }

    /// `targeted: false` leaves the target nil so standard actions go down the responder chain.
    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ hotKey: HotKeys.Action?, targeted: Bool = true) -> NSMenuItem {
        let b: HotKeys.Binding = hotKey.map(HotKeys.binding(for:)) ?? ("", [])
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: b.key)
        it.keyEquivalentModifierMask = b.modifiers
        if targeted { it.target = self }
        m.addItem(it); return it
    }

    // MARK: actions (no-ops when nothing is playing)
    @objc func menuOpen() { showOpenPanel() }
    @objc func menuOpenURL() { showOpenURL() }
    @objc func openSettings() { SettingsWindow.show() }
    @objc func mFind() { showLibrary(); NotificationCenter.default.post(name: .librarySearch, object: nil) }
    @objc func mPlay() { model?.togglePlay() }
    @objc func mBack() { model?.skip(forward: false) }
    @objc func mFwd() { model?.skip(forward: true) }
    @objc func mPrev() { playRelative(-1) }
    @objc func mNextChapter() { model?.nextChapter() }
    @objc func mPrevChapter() { model?.prevChapter() }
    @objc func mNext() { playRelative(1) }
    @objc func mSpeedUp() { if let m = model { m.setRate(min(2, m.rate + 0.25)) } }
    @objc func mSpeedDown() { if let m = model { m.setRate(max(0.5, m.rate - 0.25)) } }
    @objc func mSpeedNormal() { model?.setRate(1) }
    @objc func mCycleAudio() { model?.cycleAudio() }
    @objc func mMute() { model?.muted.toggle() }
    @objc func mVolUp() { model?.nudgeVolume(0.1) }
    @objc func mVolDown() { model?.nudgeVolume(-0.1) }
    @objc func mToggleSubs() { guard let m = model else { return }
        if m.currentSubtitle >= 0 { lastSub = m.currentSubtitle; m.selectSubtitle(-1) }
        else { m.selectSubtitle(lastSub >= 0 && lastSub < m.subtitleTracks.count ? lastSub : 0) } }
    @objc func mCycleSubs() { model?.cycleSubtitle() }
    @objc func mAddSubFile() {
        guard let m = model else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = PlayerModel.subtitleExts.compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a subtitle file"
        if let cur = currentPath, !cur.contains("://") { p.directoryURL = URL(fileURLWithPath: (cur as NSString).deletingLastPathComponent) }
        if p.runModal() == .OK, let u = p.url { m.addSubtitleFile(u) }
    }
    /// Teletext captions: the page number (UK 888, DE 150 / 777); empty = auto-detect.
    @objc func mTeletext() {
        guard let m = model else { return }
        let a = NSAlert()
        a.messageText = "Teletext Page"
        a.informativeText = "Caption page, for example 888 or 777. Leave empty to detect it."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        f.stringValue = m.engine.teletextPage.map(String.init) ?? ""
        a.accessoryView = f
        a.addButton(withTitle: "Set"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let v = Int(f.stringValue.trimmingCharacters(in: .whitespaces))
        m.engine.setTeletextPage(v.flatMap { (100...899).contains($0) ? $0 : nil })
    }
    @objc func mAudioDelayPlus() { model?.nudgeAudioDelay(0.05) }
    @objc func mAudioDelayMinus() { model?.nudgeAudioDelay(-0.05) }
    @objc func mSubDelayPlus() { model?.nudgeSubtitleDelay(0.05) }
    @objc func mSubDelayMinus() { model?.nudgeSubtitleDelay(-0.05) }
    @objc func mAudioDelayReset() { model?.resetAudioDelay() }
    @objc func mSubDelayReset() { model?.resetSubtitleDelay() }
    @objc func mResetAdjust() { model?.resetAdjustments() }
    @objc func mDialogue() { Settings.dialogueLift.toggle(); dialogueItem?.state = Settings.dialogueLift ? .on : .off }
    @objc func mNight() { Settings.nightMode.toggle(); nightItem?.state = Settings.nightMode ? .on : .off }
    @objc func mLoudness() { Settings.levelLoudness.toggle(); loudnessItem?.state = Settings.levelLoudness ? .on : .off }
    @objc func mDolbyVision() { toggleDolbyVision() }
    @objc func mSleep(_ sender: NSMenuItem) { model?.setSleepTimer(PlayerModel.SleepTimer.choices[sender.tag]) }
    @objc func mKeyHelp() { model?.showKeyHelp.toggle() }
    @objc func mInfo() { model?.showInfo.toggle(); model?.poke() }
    /// DVD / Blu-ray: pick a title (longest first; the engine rebuilds from its start).
    @objc func mDiscTitle() {
        guard let e = model?.engine, !e.discTitles.isEmpty else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = "Disc Title"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for t in e.discTitles {
            pop.addItem(withTitle: "\(t.name) · \(formatTime(t.durationSeconds)) · \(t.chapterCount) chapters")
        }
        if let cur = e.selectedDiscTitle, let i = e.discTitles.firstIndex(where: { $0.id == cur.id }) { pop.selectItem(at: i) }
        a.accessoryView = pop
        a.addButton(withTitle: "Play"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        e.selectTitle(id: e.discTitles[pop.indexOfSelectedItem].id)
    }
    @objc func mSaveFrame() { if let m = model { m.poke(); Task { await m.saveFrame() } } }
    @objc func mPiP() { model?.togglePiP() }
    @objc func mFullScreen() { window?.toggleFullScreen(nil) }
    @objc func mFloat() {
        floatOnTop.toggle()
        window?.level = floatOnTop ? .floating : .normal
        floatItem?.state = floatOnTop ? .on : .off
    }

    // Play the next/previous video file in the same folder (sorted).
    private func playRelative(_ delta: Int) {
        guard let cur = currentPath else { return }
        let dir = (cur as NSString).deletingLastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let vids = names.filter { AppDelegate.mediaExts.contains(($0 as NSString).pathExtension.lowercased()) }
                        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let curName = (cur as NSString).lastPathComponent
        guard let i = vids.firstIndex(of: curName) else { return }
        let j = i + delta
        if j >= 0 && j < vids.count { play(dir + "/" + vids[j]) }
    }
}
