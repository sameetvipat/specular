import AppKit

// Scripted checks, driven by environment variables (PLAYER_SELFTEST=1 plus one of
// PLAYER_MODETEST / PLAYER_SHOT / PLAYER_INFOTEST / PLAYER_FSTEST / PLAYER_PLAYFOR /
// PLAYER_SEEKTEST; none = transport self-test). Never runs for a normal launch.
extension AppDelegate {
    /// PLAYER_METATEST=<video file>: makes a frame-grab cover from the file, then asks the two
    /// keyless services about one well-known film and show. Needs the network; run by hand.
    func metadataTest(_ file: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("specular-metatest")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task.detached {
            let name = await Library.makeThumb(file, in: dir)
            let size = name.flatMap { try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.size] as? Int } ?? 0
            let img = name.flatMap { NSImage(contentsOf: dir.appendingPathComponent($0)) }
            print("METATEST thumb \(size > 2000 && img != nil ? "PASS" : "FAIL") \(name ?? "none") \(size) bytes \(img.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "")")
            Task {
                func show(_ label: String, _ r: TMDB.Result) {
                    switch r {
                    case .found(let m):
                        let eps = m.seasons?.values.reduce(0) { $0 + $1.episodes.count } ?? 0
                        print("METATEST \(label) PASS \(m.title) (\(m.year ?? "-")) | poster \(m.poster != nil) | genres \(m.genres ?? []) | runtime \(m.runtime ?? 0) | cast \(m.cast?.count ?? 0) | episodes \(eps) | \(m.overview.prefix(60))…")
                    case .notFound: print("METATEST \(label) FAIL not found")
                    case .failed(let why): print("METATEST \(label) FAIL \(why)")
                    }
                }
                show("film (Wikipedia)", await Wiki.lookup(title: "Inception", year: "2010", knownID: nil, imageDir: dir))
                show("show (TVmaze)", await TVmaze.lookup(title: "Breaking Bad", knownID: nil, imageDir: dir))
                let c = await Wiki.candidates(query: "Inception")
                print("METATEST candidates \(c.isEmpty ? "FAIL" : "PASS") \(c.count) for a film search")
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    /// PLAYER_UNITTEST=1: pure checks, no window: the HDR routing table (one line per row) and the hot keys.
    func unitTest() {
        func check(_ name: String, _ got: HDRRoute, _ want: HDRRoute) { print("UNITTEST \(got == want ? "PASS" : "FAIL") route \(name) -> \(got)") }
        let d = HDRRoute.decide
        check("hdrColors apple, DV 8.1", d("apple", .dolbyVision, 8, true, false), .apple)
        check("HDR10", d("specular", .hdr10, nil, true, false), .specular)
        check("HDR10+", d("specular", .hdr10Plus, nil, true, false), .specular)
        check("DV 8.1 on the Air", d("specular", .dolbyVision, 8, true, false), .specular)
        check("DV 8.1 on XDR", d("specular", .dolbyVision, 8, true, true), .apple)
        check("DV 8.1 on XDR, DV off", d("specular", .dolbyVision, 8, false, true), .specular)
        check("DV 5", d("specular", .dolbyVision, 5, true, false), .apple)
        check("DV 7 (MEL / FEL decided by the engine route)", d("specular", .dolbyVision, 7, true, false), .specular)
        check("HLG", d("specular", .hlg, nil, true, false), .apple)
        check("SDR", d("specular", .sdr, nil, true, false), .apple)
        let ck = PlayerModel.chapterKindSelfTest()
        print("UNITTEST \(ck.isEmpty ? "PASS" : "FAIL") chapter kinds\(ck.isEmpty ? "" : ": " + ck.joined(separator: "; "))")
        let hk = HotKeys.selfTest()
        print("UNITTEST \(hk.isEmpty ? "PASS" : "FAIL") hot keys\(hk.isEmpty ? "" : ": " + hk.joined(separator: "; "))")
        NSApp.terminate(nil)
    }

    /// PLAYER_INFOTEST=<video file>: the library's MediaInfo for one file (tags, codec, audio tracks).
    func infoTest(_ file: String) {
        Task.detached {
            let i = MediaInfo.probe(file)
            print("INFOTEST \(i.readable && i.width > 0 ? "PASS" : "FAIL") \(i.tags.joined(separator: ", ")) | \(i.videoCodec ?? "-") | \(i.hdr ?? "SDR") | \(i.audio.joined(separator: " / ")) | subs \((i.subtitles ?? []).joined(separator: " / "))")
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    /// PLAYER_LIBTEST=<dir>: checks the file-name parser, then scans <dir> and prints what the
    /// library would show. No window, no network.
    func libraryTest(_ dir: String) {
        func check(_ name: String, _ title: String, _ year: String?, _ s: Int?, _ e: Int?) {
            let it = parseMediaName("/x/Season 1/" + name)
            let ok = it.title == title && it.year == year && it.season == s && it.episode == e
            print("LIBTEST parse \(ok ? "PASS" : "FAIL") \(name) -> \(it.title) | \(it.year ?? "-") | \(it.season.map(String.init) ?? "-") | \(it.episode.map(String.init) ?? "-")")
        }
        check("Spider-Man.Brand.New.Day.2026.2160p.WEB-DL.mkv", "Spider-Man Brand New Day", "2026", nil, nil)
        check("The.Show.S02E05.1080p.WEB.h264.mkv", "The Show", nil, 2, 5)
        check("The Show (2019) - s01e10 - Pilot.mkv", "The Show", "2019", 1, 10)
        check("Other Show 3x07.mp4", "Other Show", nil, 3, 7)
        check("Plain Film.mp4", "Plain Film", nil, nil, nil)
        check("(2004) Before Sunset [1080p] [Blu-Ray] [DTS HD Master Audio 5.1].mkv", "Before Sunset", "2004", nil, nil)
        check("(2017) Blade Runner 2049 [1080p] [Open Matte] [Dolby TrueHD 7.1].mkv", "Blade Runner 2049", "2017", nil, nil)
        check("(2013) Kotonoha no Niwa - The Garden of Words [1080p] [Blu-Ray].mkv", "Kotonoha no Niwa - The Garden of Words", "2013", nil, nil)
        check("Heart.Of.The.Beast.2026.x265.WEB-DL.2160p.HDR-DV.mkv", "Heart Of The Beast", "2026", nil, nil)
        let bare = parseMediaName("/x/My Show/Season 1/S01E02.mkv")
        print("LIBTEST parse \(bare.title == "My Show" && bare.episode == 2 ? "PASS" : "FAIL") S01E02.mkv in folder -> \(bare.title)")
        // Local metadata, the Jellyfin way: id tag in the folder name, .nfo, artwork next to the file.
        let fm = FileManager.default, own = dir + "/Local Film (2001) [tmdbid-603]"
        try? fm.createDirectory(atPath: own, withIntermediateDirectories: true)
        fm.createFile(atPath: own + "/Local Film (2001).mkv", contents: nil)
        fm.createFile(atPath: own + "/poster.jpg", contents: Data([0xFF, 0xD8]))
        fm.createFile(atPath: own + "/fanart.jpg", contents: Data([0xFF, 0xD8]))
        try? "<movie><title>Nfo Title</title><plot>Nfo plot.</plot><year>2001</year><uniqueid type=\"tmdb\">604</uniqueid></movie>"
            .write(toFile: own + "/movie.nfo", atomically: true, encoding: .utf8)
        let li = Library.localInfo(for: parseMediaName(own + "/Local Film (2001).mkv"), alone: true)
        let lok = li.tmdbID == 603 && li.title == "Nfo Title" && li.plot == "Nfo plot." && li.year == "2001"
            && li.poster == own + "/poster.jpg" && li.backdrop == own + "/fanart.jpg"
        print("LIBTEST local \(lok ? "PASS" : "FAIL") id \(li.tmdbID ?? -1) | \(li.title ?? "-") | \(li.plot ?? "-") | poster \(li.poster != nil) | backdrop \(li.backdrop != nil)")
        let junk = dir + "/(2017) Junk Nfo [1080p]"                    // an .nfo holding the folder name is ignored
        try? fm.createDirectory(atPath: junk, withIntermediateDirectories: true)
        fm.createFile(atPath: junk + "/(2017) Junk Nfo [1080p].mkv", contents: nil)
        try? "<movie><title>(2017) Junk Nfo [1080p]</title><year>2049</year></movie>".write(toFile: junk + "/movie.nfo", atomically: true, encoding: .utf8)
        let jl = Library.localInfo(for: parseMediaName(junk + "/(2017) Junk Nfo [1080p].mkv"), alone: true)
        print("LIBTEST local \(jl.title == nil && jl.year == nil ? "PASS" : "FAIL") folder-name .nfo ignored (title \(jl.title ?? "-"), year \(jl.year ?? "-"))")
        let shared = Library.localInfo(for: parseMediaName(own + "/Local Film (2001).mkv"), alone: false)
        print("LIBTEST local \(shared.poster == nil && shared.title == nil ? "PASS" : "FAIL") folder artwork ignored when the folder holds several films")
        let logos = [Logo.imdb, Logo.tmdb, Logo.fresh, Logo.rotten, Logo.dolbyVision, Logo.dolbyAtmos].allSatisfy { ($0?.size.width ?? 0) > 0 }
        print("LIBTEST logos \(logos ? "PASS" : "FAIL") rating logos load from the resource bundle")
        let items = Library.scan([dir])
        let films = items.filter { !$0.isEpisode }, eps = items.filter { $0.isEpisode }
        print("LIBTEST scan: \(films.count) films, \(Set(eps.map(\.metaKey)).count) shows, \(eps.count) episodes")
        NSApp.terminate(nil)
    }

    /// PLAYER_PANELTEST=1 (with PLAYER_SELFTEST=1): stands in for the Open panel. A window is
    /// shown, a file is opened, and the window closes while the file is still opening; the app
    /// must stay alive and play. Regression check for "app quits after choosing a file".
    func panelTest(_ path: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.play(path)
            w.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { print("PANELTEST alive: PASS"); NSApp.terminate(nil) }
        }
    }
    /// PLAYER_SNAPTEST=1 (with PLAYER_SELFTEST=1 and a file): saves the frame on screen after 2 s
    /// into a temp folder (not ~/Pictures), prints `SNAPTEST PASS <path> <bytes>` and quits.
    func snapTest(_ m: PlayerModel) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("specular-snaptest")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task { @MainActor in
                let url = await m.saveFrame(to: dir)
                let size = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
                let ok = size > 2000 && url.flatMap { NSImage(contentsOf: $0) } != nil
                print("SNAPTEST \(ok ? "PASS" : "FAIL") \(url?.path ?? "none") \(size)")
                NSApp.terminate(nil)
            }
        }
    }

    /// PLAYER_SELFTEST=1 with a file and no other hook: play, seek, audio track switch, HDR label.
    /// Prints one `TEST <name> PASS|FAIL` line per check, then quits.
    func transportTest(_ m: PlayerModel) {
        if ProcessInfo.processInfo.environment["PLAYER_SNAPTEST"] != nil { snapTest(m); return }
        func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated(f) }
        }
        let start = m.position
        after(2.5) {
            print("TEST play \(!m.isPaused && m.position > start + 0.5 ? "PASS" : "FAIL") at \(m.position)s")
            let target = min(10, max(0, m.duration - 4))
            m.seek(to: target)
            after(2.5) {
                print("TEST seek \(m.position >= target - 0.5 && m.position < target + 4 ? "PASS" : "FAIL") to \(target), at \(m.position)s")
                let before = m.currentTrack
                if m.audioTracks.count > 1 { m.cycleAudio() }
                after(2) {
                    if m.audioTracks.count > 1 {
                        print("TEST audio switch \(m.currentTrack != before && !m.isPaused ? "PASS" : "FAIL") \(before) -> \(m.currentTrack) of \(m.audioTracks.count)")
                    }
                    print("TEST label \(m.hdrLabel ?? "SDR") | badges \(m.badges.joined(separator: ", "))")
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
