import AppKit
import Foundation
import AetherEngine

// The library: folders the user adds are scanned for video files, grouped into films and
// shows, enriched with metadata (local files first, then TMDB — see TMDB.swift) and a
// watched / progress state. Everything is stored in one JSON file; images in a cache folder.

let libraryVideoExts: Set<String> = ["mkv","mp4","m4v","mov","avi","webm","ts","m2ts","mts",
    "mpg","mpeg","wmv","flv","vob","ogm","ogv","3gp","rmvb","m2v","divx","mxf","iso"]

struct LibraryItem: Identifiable, Hashable {
    let path: String
    let title: String           // film title, or the show's name for an episode
    let year: String?
    let season: Int?            // nil = film
    let episode: Int?
    var added = Date.distantPast    // file creation date ("Recently Added")
    var id: String { path }
    var isEpisode: Bool { season != nil }
    /// One metadata record per film (title + year) or per show (name).
    var metaKey: String { isEpisode ? "tv|\(title.lowercased())" : "movie|\(title.lowercased())|\(year ?? "")" }
    var episodeLabel: String { "S\(season ?? 0) · E\(episode ?? 0)" }
}

/// New fields are optional so a library.json written by an older build still loads.
struct LibraryMeta: Codable {
    var tmdbID: Int             // id in `source`'s database; 0 = nothing found (retried on Refresh); -1 = local files only
    var title: String
    var overview: String
    var poster: String?         // file name in the image cache, or an absolute path (local artwork)
    var year: String?
    var backdrop: String?       // same convention as poster
    var tagline: String?
    var genres: [String]?
    var runtime: Int?           // minutes
    var rating: Double?         // 0...10
    var cast: [CastMember]?
    var seasons: [Int: SeasonMeta]?
    var detailed: Bool?         // full details fetched (older records are upgraded on the next scan)
    var source: String?         // "tmdb", "tvmaze", "wiki"; nil = TMDB (older records)
    var collection: String?     // film series this belongs to (TMDB)
    var imdbID: String?         // "tt1375666", from TMDB; key for OMDb
    var imdbRating: Double?     // 0...10, OMDb
    var rottenTomatoes: Int?    // critics' score in percent, OMDb
    var ratingsChecked: Date?   // last OMDb lookup; a missing Rotten Tomatoes score is asked again after a week
}

/// What a file holds (resolution, HDR, codecs, audio), read once with AetherEngine's probe (no playback).
struct MediaInfo: Codable, Hashable {
    var width = 0, height = 0           // 0 = no video
    var videoCodec: String?             // "HEVC 10-bit"
    var hdr: String?                    // "Dolby Vision P8", "HDR10+", "HDR10", "HLG"; nil = SDR
    var audio: [String] = []            // "English · Dolby TrueHD Atmos 7.1" (audioName)
    var audioIDs: [Int]?                // engine track ids behind `audio`; nil = probed by an older build
    var subtitles: [String]?            // "English · PGS · Forced" (subtitleName)
    var subtitleIDs: [Int]?
    var atmos = false, dtsx = false
    var readable = true                 // false: the probe failed (not retried until the app restarts)
    var version: Int?                   // naming rules used; older records are probed again (see `current`)
    static let current = 4              // 2: release-group titles dropped; 3: commentary flag on the default track ignored; 4: that rule reverted (bad tags get fixed in the file)

    /// Short tags for cards: "4K", "Dolby Vision", "Atmos".
    var tags: [String] {
        var t: [String] = []
        if width > 0 { t.append(resolutionLabel(width: width, height: height)) }
        if let h = hdr { t.append(h.hasPrefix("Dolby Vision") ? "Dolby Vision" : h) }
        if atmos { t.append("Atmos") } else if dtsx { t.append("DTS:X") }
        return t
    }

    /// Narrow cards: "DV" for Dolby Vision.
    var cardTags: [String] { tags.map { $0 == "Dolby Vision" ? "DV" : $0 } }

    /// Demux plus a bounded decode for Atmos / HDR10+ (a few MB at most); runs off the main thread.
    nonisolated static func probe(_ path: String) -> MediaInfo {
        guard let p = try? AetherEngine.probe(url: URL(fileURLWithPath: path), detecting: [.atmos, .hdr10Plus]) else {
            return MediaInfo(readable: false)
        }
        let names = ["hevc": "HEVC", "h264": "H.264", "av1": "AV1", "vp9": "VP9", "vp8": "VP8", "mpeg2video": "MPEG-2",
                     "mpeg4": "MPEG-4", "vc1": "VC-1", "prores": "ProRes", "mpeg1video": "MPEG-1"]
        var info = MediaInfo(width: Int(p.videoWidth), height: Int(p.videoHeight))
        if let c = p.videoCodecName, p.videoWidth > 0 {
            info.videoCodec = (names[c] ?? c.uppercased()) + ((p.videoStreamFormat?.bitDepth ?? 8) > 8 ? " \(p.videoStreamFormat!.bitDepth!)-bit" : "")
        }
        switch p.videoFormat {
        case .dolbyVision: info.hdr = "Dolby Vision" + (p.dvProfile.map { " P\($0)" } ?? "")
        case .hdr10Plus:   info.hdr = "HDR10+"
        case .hdr10:       info.hdr = p.carriesHDR10PlusMetadata ? "HDR10+" : "HDR10"
        case .hlg:         info.hdr = "HLG"
        default:           break
        }
        info.version = MediaInfo.current
        info.audio = p.audioTracks.map(audioName); info.audioIDs = p.audioTracks.map(\.id)
        info.subtitles = p.subtitleTracks.map(subtitleName); info.subtitleIDs = p.subtitleTracks.map(\.id)
        info.atmos = p.audioTracks.contains { $0.isAtmos }
        info.dtsx = p.audioTracks.contains { $0.isDTSX }
        return info
    }
}

/// The track's language in the user's language ("Russian"); nil when unknown.
func trackLanguage(_ t: TrackInfo) -> String? {
    t.language.flatMap { $0 == "und" ? nil : Locale.current.localizedString(forLanguageCode: $0) }
}

/// The container's track title only when it names a kind of track the codec fields can't ("Director's
/// Commentary", "Audio Description", "Signs & Songs"). Release-group labels ("DUB (Продубляж)", "MVO (HDrezka
/// Studio)") and titles that repeat language / codec ("English", "DTS-HD MA 5.1") are dropped (user, 2026-11-15).
private func trackTitle(_ t: TrackInfo) -> String? {
    let n = t.name.trimmingCharacters(in: .whitespaces), l = n.lowercased()
    let meaningful = ["commentary", "description", "descriptive", "narrat", "director", "isolated", "score", "original",
                      "theatrical", "extended", "signs", "songs", "lyrics", "karaoke", "kids", "children", "dialogue", "music"]
    return meaningful.contains(where: l.contains) ? n : nil
}

/// "English · Dolby TrueHD Atmos 7.1", "Russian · DTS-HD MA 5.1 · Director's Commentary".
func audioName(_ t: TrackInfo) -> String {
    let codecs = ["truehd": "Dolby TrueHD", "eac3": "Dolby Digital Plus", "ac3": "Dolby Digital", "dts": "DTS", "dca": "DTS", "aac": "AAC",
                  "flac": "FLAC", "alac": "ALAC", "opus": "Opus", "mp3": "MP3", "vorbis": "Vorbis", "mp2": "MP2"]
    let l = t.name.lowercased()
    var codec = t.isDTSX ? "DTS:X" : codecs[t.codec] ?? (t.codec.hasPrefix("pcm") ? "PCM" : t.codec.uppercased())
    if t.codec == "dts" || t.codec == "dca", !t.isDTSX {                                  // the profile is not exposed: the title says it
        if l.contains("master") || l.contains("dts-hd ma") { codec = "DTS-HD MA" }
        else if l.contains("hi res") || l.contains("hra") { codec = "DTS-HD HRA" }
    }
    if t.isAtmos || (t.codec == "truehd" && l.contains("atmos")) { codec += " Atmos" }
    let ch = [1: "Mono", 2: "Stereo", 6: "5.1", 8: "7.1"][t.channels] ?? (t.channels > 0 ? "\(t.channels) ch" : "")
    let title = trackTitle(t)
    return [trackLanguage(t), [codec, ch].filter { !$0.isEmpty }.joined(separator: " "), title,
            t.isCommentary && title == nil ? "Commentary" : nil, t.isVisualImpaired ? "Audio Description" : nil]
        .compactMap { $0 }.joined(separator: " · ")
}

/// "English · PGS · Forced", "English · SRT · SDH". An added file keeps its file name.
func subtitleName(_ t: TrackInfo) -> String {
    let codecs = ["subrip": "SRT", "ass": "ASS", "ssa": "SSA", "hdmv_pgs_subtitle": "PGS", "pgssub": "PGS", "dvd_subtitle": "VobSub", "dvdsub": "VobSub", "dvbsub": "DVB",
                  "dvb_subtitle": "DVB", "mov_text": "Text", "webvtt": "WebVTT", "eia_608": "Closed Captions", "dvb_teletext": "Teletext"]
    let codec = codecs[t.codec] ?? t.codec.uppercased()
    if t.isExternal { return "\(t.name) · \(codec)" }
    return [trackLanguage(t) ?? (t.codec == "eia_608" ? t.name : nil), codec, trackTitle(t), t.isForced ? "Forced" : nil,
            t.isHearingImpaired ? "SDH" : nil, t.isCommentary ? "Commentary" : nil]
        .compactMap { $0 }.joined(separator: " · ")
}

/// Tracks picked on the detail page before Play: engine track ids, nil = automatic, subtitle -1 = off.
struct TrackChoice { var audio: Int?; var subtitle: Int? }

/// "4K" / "HD" / "SD": the rule the player badge and the library tags share.
func resolutionLabel(width: Int, height: Int) -> String {
    width >= 3200 || height >= 2000 ? "4K" : height >= 700 ? "HD" : "SD"
}

struct PlayState: Codable {
    var position: Double
    var duration: Double
    var watched: Bool
    var updated: Date
}

/// "Show.Name.S02E05.1080p.WEB.mkv" -> show "Show Name", season 2, episode 5.
/// "Show Name 2x05.mkv" works too. Anything else is a film, named by `cleanTitle`.
func parseMediaName(_ path: String) -> LibraryItem {
    if DiscFolder.root(of: path) != nil {       // disc folder: a fake extension keeps "Film.2010" from losing ".2010"
        let p = parseMediaName(path + ".disc")
        return LibraryItem(path: path, title: p.title, year: p.year, season: p.season, episode: p.episode)
    }
    let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let patterns = [#"(?i)^(.*?)[ ._\-\[]*\bs(\d{1,2})[ ._\-]?e(\d{1,3})"#, #"(?i)^(.*?)[ ._\-]+(\d{1,2})x(\d{2,3})(?!\d)"#]
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p),
              let m = re.firstMatch(in: file, range: NSRange(file.startIndex..., in: file)),
              let nameR = Range(m.range(at: 1), in: file), let sR = Range(m.range(at: 2), in: file),
              let eR = Range(m.range(at: 3), in: file), let s = Int(file[sR]), let e = Int(file[eR]) else { continue }
        var name = String(file[nameR])
        if !name.contains(" ") { name = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " -._[]()"))
        var year: String?
        if let r = name.range(of: #"[ (]((19|20)\d{2})\)?$"#, options: .regularExpression) {   // "Show (2019)"
            year = String(name[r]).trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            name = String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if name.isEmpty { name = (showFolder(path) as NSString).lastPathComponent }   // "S01E02.mkv"
        return LibraryItem(path: path, title: name, year: year, season: s, episode: e)
    }
    let (title, year) = cleanTitle(path)
    return LibraryItem(path: path, title: title, year: year, season: nil, episode: nil)
}

/// The show's folder for an episode file: its folder, or the one above a "Season N" folder.
func showFolder(_ path: String) -> String {
    let dir = (path as NSString).deletingLastPathComponent
    if (dir as NSString).lastPathComponent.range(of: #"(?i)^(season\s*\d+|s\d+|specials)$"#, options: .regularExpression) != nil {
        return (dir as NSString).deletingLastPathComponent
    }
    return dir
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var folders: [String] = []
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var meta: [String: LibraryMeta] = [:]
    @Published private(set) var play: [String: PlayState] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var status = ""

    /// Covers made from a frame of the video itself, for titles no database knows: path -> file
    /// name in the image cache ("" = could not make one).
    @Published private(set) var thumbs: [String: String] = [:]
    /// Matches chosen by hand ("Fix Match"), by metaKey.
    @Published private(set) var overrides: [String: MatchOverride] = [:]
    /// Collections made by hand: name -> metaKeys.
    @Published private(set) var userCollections: [String: [String]] = [:]
    /// Technical facts per file path (MediaInfo), probed on demand.
    @Published private(set) var mediaInfo: [String: MediaInfo] = [:]
    /// Removed from Continue Watching: path -> when. It comes back once it is played after that.
    @Published private(set) var hiddenContinue: [String: Date] = [:]
    /// TMDB series collections the user deleted (by name).
    @Published private(set) var hiddenCollections: Set<String> = []

    private struct Saved: Codable {
        var folders: [String]; var meta: [String: LibraryMeta]; var play: [String: PlayState]
        var thumbs: [String: String]?; var overrides: [String: MatchOverride]?; var userCollections: [String: [String]]?
        var mediaInfo: [String: MediaInfo]?
        var hiddenContinue: [String: Date]?; var hiddenCollections: Set<String>?
    }
    private var infoPending = Set<String>()
    private var infoQueue: [String] = []        // probes run one at a time
    private var infoRunning = false
    private var thumbPending = Set<String>()
    private var thumbQueue: [String] = []       // frame grabs run one at a time
    private var thumbRunning = false
    private var watcher: FSEventStreamRef?
    private var watchWork: DispatchWorkItem?
    private let file: URL
    let imageDir: URL
    private let images = NSCache<NSString, NSImage>()
    private var scanSerial = 0

    private init() {
        let fm = FileManager.default
        // SPECULAR_LIBRARY_DIR: keep the library somewhere else (tests use a scratch folder).
        let custom = ProcessInfo.processInfo.environment["SPECULAR_LIBRARY_DIR"].map { URL(fileURLWithPath: $0) }
        let support = custom ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Specular")
        imageDir = custom?.appendingPathComponent("posters")
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Specular/posters")
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
        file = support.appendingPathComponent("library.json")
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d) {
            folders = s.folders; meta = s.meta; play = s.play
            thumbs = s.thumbs ?? [:]; overrides = s.overrides ?? [:]; userCollections = s.userCollections ?? [:]
            mediaInfo = s.mediaInfo ?? [:]
            hiddenContinue = s.hiddenContinue ?? [:]; hiddenCollections = s.hiddenCollections ?? []
        }
        watchFolders()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(Saved(folders: folders, meta: meta, play: play, thumbs: thumbs,
                                                      overrides: overrides, userCollections: userCollections, mediaInfo: mediaInfo,
                                                      hiddenContinue: hiddenContinue, hiddenCollections: hiddenCollections)) else { return }
        try? d.write(to: file, options: .atomic)     // atomic: a crash mid-write keeps the old file
    }

    // MARK: folders and scanning
    func addFolder(_ path: String) {
        guard !folders.contains(path) else { return }
        folders.append(path); save(); watchFolders(); rescan()
    }
    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }; save(); watchFolders(); rescan()
    }

    /// Rescan by itself when files are added, removed or renamed inside a library folder
    /// (FSEvents, recursive). Changes are gathered for 3 s so a large copy triggers one scan.
    private func watchFolders() {
        if let w = watcher { FSEventStreamStop(w); FSEventStreamInvalidate(w); FSEventStreamRelease(w); watcher = nil }
        guard !folders.isEmpty, ProcessInfo.processInfo.environment["PLAYER_SELFTEST"] == nil else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let lib = Unmanaged<Library>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { lib.foldersChanged() }       // delivered on the main queue (set below)
        }
        guard let w = FSEventStreamCreate(nil, cb, &ctx, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(w, .main)
        FSEventStreamStart(w)
        watcher = w
    }
    private func foldersChanged() {
        watchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rescan() }
        watchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    /// Every video file under the folders (hidden files and package contents skipped), sorted.
    /// A disc folder (holding BDMV / VIDEO_TS) is one film, named from the folder; its clips are not listed.
    nonisolated static func scan(_ folders: [String]) -> [LibraryItem] {
        var out: [LibraryItem] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard seen.insert(url.path).inserted else { return }
            var it = parseMediaName(url.path)
            it.added = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            out.append(it)
        }
        for folder in folders {
            let top = URL(fileURLWithPath: folder)
            if let disc = DiscFolder.root(of: folder) { add(disc); continue }
            guard let en = FileManager.default.enumerator(at: top, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in en {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if let disc = DiscFolder.root(of: url.path) { en.skipDescendants(); add(disc) }
                } else if libraryVideoExts.contains(url.pathExtension.lowercased()) {
                    add(url)
                }
            }
        }
        return out.sorted {
            ($0.title.lowercased(), $0.season ?? 0, $0.episode ?? 0, $0.path) < ($1.title.lowercased(), $1.season ?? 0, $1.episode ?? 0, $1.path)
        }
    }

    /// What sits next to the files of one film or show: id tag, .nfo, local artwork.
    nonisolated static func localInfo(for it: LibraryItem, alone: Bool) -> LocalInfo {
        if it.isEpisode { return LocalInfo.read(path: it.path, folder: showFolder(it.path), base: nil, ownFolder: true, tv: true) }
        // A disc folder is the film's own folder: its poster.jpg / movie.nfo sit inside it.
        if DiscFolder.root(of: it.path) != nil { return LocalInfo.read(path: it.path, folder: it.path, base: nil, ownFolder: true, tv: false) }
        let dir = (it.path as NSString).deletingLastPathComponent
        let base = ((it.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return LocalInfo.read(path: it.path, folder: dir, base: base, ownFolder: alone, tv: false)
    }

    /// Scan the folders off the main thread, then gather metadata. `refresh` also retries
    /// titles that found nothing last time.
    func rescan(refresh: Bool = false) {
        scanSerial += 1
        let serial = scanSerial, folders = self.folders
        scanning = true; status = "Scanning…"
        if refresh { meta = meta.filter { $0.value.tmdbID != 0 } }
        Task.detached(priority: .userInitiated) {
            let found = Library.scan(folders)
            // A film's folder-wide artwork (poster.jpg) counts only if it is alone in its folder.
            var perDir: [String: Int] = [:]
            for it in found where !it.isEpisode { perDir[(it.path as NSString).deletingLastPathComponent, default: 0] += 1 }
            var local: [String: LocalInfo] = [:]
            for it in found where local[it.metaKey] == nil {
                local[it.metaKey] = Library.localInfo(for: it, alone: perDir[(it.path as NSString).deletingLastPathComponent] == 1)
            }
            await MainActor.run {
                guard serial == self.scanSerial else { return }
                self.items = found
                let paths = Set(found.map(\.path))
                if folders.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {    // not while a drive is unplugged
                    self.mediaInfo = self.mediaInfo.filter { paths.contains($0.key) }        // files that are gone
                }
                self.status = ""
            }
            await self.fetchMetadata(serial, local, refreshing: refresh)
        }
    }

    private func fetchMetadata(_ serial: Int, _ local: [String: LocalInfo], refreshing: Bool) async {
        defer { if serial == scanSerial { scanning = false } }
        var first: [String: LibraryItem] = [:]
        for it in items where first[it.metaKey] == nil { first[it.metaKey] = it }

        // 1. Local files: title, plot and artwork next to the media win over anything online.
        for (key, it) in first {
            guard let l = local[key], l.title != nil || l.plot != nil || l.poster != nil || l.backdrop != nil else { continue }
            var m = meta[key] ?? LibraryMeta(tmdbID: -1, title: it.title, overview: "", poster: nil, year: it.year)   // -1 = local only so far
            Library.applyLocal(l, to: &m)
            meta[key] = m
        }
        save()

        // 2. Online: anything never looked up, or looked up before full details existed. After
        //    a TMDB key is built in, a Refresh also upgrades records from the keyless sources.
        let upgrade = refreshing && !TMDB.key.isEmpty
        let wanted = first.filter { key, _ in
            guard let m = meta[key] else { return true }
            // A title that is still a raw folder name ("(2017) Blade Runner 2049 [1080p]") came from a junk .nfo:
            // fetch it again, even if it was "not found" or already detailed.
            if m.title.range(of: #"[\[\]{}]|^\s*\((19|20)\d{2}\)"#, options: .regularExpression) != nil { return true }
            if m.tmdbID == 0 { return false }
            // TMDB records made before ratings existed have no IMDb id: Refresh fetches them again.
            return m.detailed != true || (upgrade && (m.source != "tmdb" || m.imdbID == nil))
        }.sorted { $0.key < $1.key }
        var done = 0
        for (key, it) in wanted {                       // one at a time: well inside every service's limits
            guard serial == scanSerial else { return }
            status = "Fetching details \(done + 1) of \(wanted.count)…"
            switch await fetchOne(key, it, local[key]) {
            case .failed(let why): status = why; save(); return      // bad key / offline: stop, keep what we have
            default: break
            }
            done += 1
            if done % 5 == 0 { save() }
        }
        save()
        await refreshMissingRatings(serial)
        if serial == scanSerial { status = "" }
    }

    /// OMDb often has no Rotten Tomatoes score for a new film yet: ask again, at most once a week per film.
    private func refreshMissingRatings(_ serial: Int) async {
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let due = meta.filter { $0.value.imdbID != nil && $0.value.rottenTomatoes == nil && ($0.value.ratingsChecked ?? .distantPast) < weekAgo }
        for (key, m) in due {
            guard serial == scanSerial, let id = m.imdbID else { return }
            let (imdb, rt) = await OMDb.ratings(imdbID: id)
            guard var cur = meta[key] else { continue }
            if let imdb { cur.imdbRating = imdb }
            cur.rottenTomatoes = rt
            cur.ratingsChecked = Date()
            meta[key] = cur
        }
        if !due.isEmpty { save() }
    }

    /// Look one film or show up online and store the result; local values still win.
    @discardableResult
    private func fetchOne(_ key: String, _ it: LibraryItem, _ l: LocalInfo?) async -> TMDB.Result {
        let old = meta[key]
        var known = overrides[key]
        if known == nil, let id = l?.tmdbID { known = MatchOverride(source: "tmdb", id: id) }
        if known == nil, let o = old, o.tmdbID > 0 { known = MatchOverride(source: o.source ?? "tmdb", id: o.tmdbID) }
        let seasons = Array(Set(items.filter { $0.metaKey == key }.compactMap(\.season))).sorted()
        let r = await Metadata.lookup(title: l?.title ?? it.title, year: l?.year ?? it.year, tv: it.isEpisode,
                                      known: known, seasons: seasons, imageDir: imageDir)
        switch r {
        case .found(var m):
            if let l { Library.applyLocal(l, to: &m) }
            meta[key] = m
        case .notFound:
            if old == nil { meta[key] = LibraryMeta(tmdbID: 0, title: it.title, overview: "", poster: nil, year: it.year) }
            else if old?.detailed != true { meta[key]?.tmdbID = 0 }
        case .failed: break
        }
        return r
    }

    /// Local values (.nfo, poster.jpg) win by default; with the "prefer local" settings off they only
    /// fill what the online record lacks (or everything while nothing was found online).
    private static func applyLocal(_ l: LocalInfo, to m: inout LibraryMeta) {
        let d = UserDefaults.standard, offline = m.tmdbID <= 0
        let text = offline || (d.object(forKey: "preferLocalMetadata") as? Bool ?? true)
        let art = offline || (d.object(forKey: "preferLocalArtwork") as? Bool ?? true)
        if let t = l.title, text { m.title = t }
        if let p = l.plot, text || m.overview.isEmpty { m.overview = p }
        if let y = l.year, text || m.year == nil { m.year = y }
        if let p = l.poster, art || m.poster == nil { m.poster = p }
        if let b = l.backdrop, art || m.backdrop == nil { m.backdrop = b }
    }

    /// Look everything up online again (stored ids kept): after the image cache is cleared, or when
    /// a "prefer local" setting is turned off so online values can replace the local ones.
    func refetchOnline() {
        for (k, m) in meta where m.tmdbID > 0 { meta[k]?.detailed = nil }
        save(); rescan()
    }

    /// Empty the image cache (posters, backdrops, frame grabs, embedded covers), then fetch them again.
    func clearImageCache() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
        thumbs = [:]; images.removeAllObjects()     // frame grabs and covers are made again as cards appear
        refetchOnline()
    }

    /// "Fix Match": use this database entry for the film or show from now on.
    func fixMatch(_ it: LibraryItem, to c: MatchCandidate) {
        let key = it.metaKey
        overrides[key] = MatchOverride(source: c.source, id: c.id)
        meta[key] = nil
        status = "Fetching details…"
        Task {
            let alone = movies.filter { ($0.path as NSString).deletingLastPathComponent == (it.path as NSString).deletingLastPathComponent }.count == 1
            let l = Library.localInfo(for: it, alone: alone)
            if case .failed(let why) = await fetchOne(key, it, l) { status = why } else { status = "" }
            save()
        }
    }

    // MARK: media info
    /// Ask for a file's MediaInfo. Probed once, in the background; saved when the queue runs dry.
    func requestInfo(_ path: String) {
        if let i = mediaInfo[path], !i.readable || i.version == MediaInfo.current { return }   // known and current
        guard infoPending.insert(path).inserted else { return }
        infoQueue.append(path)
        pumpInfo()
    }
    private func pumpInfo() {
        guard !infoRunning, !infoQueue.isEmpty else { return }
        infoRunning = true
        let path = infoQueue.removeFirst()
        Task {
            mediaInfo[path] = await Task.detached(priority: .utility) { MediaInfo.probe(path) }.value
            infoPending.remove(path)
            infoRunning = false
            if infoQueue.isEmpty { save() }         // one write per batch, not per file
            pumpInfo()
        }
    }

    // MARK: covers from the video itself
    /// Ask for a frame-grab cover for a file that has no artwork. Made once, in the background.
    func requestThumb(_ path: String) {
        guard thumbs[path] == nil, thumbPending.insert(path).inserted else { return }
        thumbQueue.append(path)
        pumpThumbs()
    }
    private func pumpThumbs() {
        guard !thumbRunning, !thumbQueue.isEmpty else { return }
        thumbRunning = true
        let path = thumbQueue.removeFirst(), dir = imageDir
        let m = meta[parseMediaName(path).metaKey]
        let grab = m?.poster == nil || m?.backdrop == nil       // only asked for its embedded cover: no frame grab needed
        Task {
            let name = await Task.detached(priority: .utility) { await Library.makeThumb(path, in: dir, grab: grab) }.value ?? ""
            thumbs[path] = name; save()
            thumbRunning = false
            pumpThumbs()
        }
    }
    func thumbnail(_ path: String) -> NSImage? { image(thumbs[path]) }

    /// The cover embedded in the file (MKV attachment / MP4 cover) when there is one, saved as is.
    /// Otherwise (and only when `grab`) take the frame about 12% in (AetherEngine's FrameExtractor: no playback, HDR tone-mapped
    /// to SDR) and save it as a JPEG. Returns the file name, or nil for audio-only and
    /// unreadable files. Dolby Vision profile 5 gives no still without Aether's
    /// DolbyVisionStillReshaping trait (off), so those keep the gradient placeholder.
    nonisolated static func makeThumb(_ path: String, in dir: URL, grab: Bool = true) async -> String? {
        let url = URL(fileURLWithPath: path)
        guard let probe = try? AetherEngine.probe(url: url) else { return nil }
        var hash: UInt64 = 0xcbf29ce484222325                         // FNV-1a of the path: stable file name
        for b in path.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        if let art = probe.metadata.artworkData, NSImage(data: art) != nil {
            let name = String(format: "cover-%016llx", hash)          // no extension: JPEG or PNG, read by content
            if (try? art.write(to: dir.appendingPathComponent(name))) != nil { return name }
        }
        guard grab, probe.videoWidth > 0 else { return nil }
        let frames = FrameExtractor(url: url)
        let dur = probe.durationSeconds
        let cg = await frames.snapshot(at: dur > 0 ? min(dur * 0.12, 600) : 5, maxSize: CGSize(width: 1280, height: 720))
        await frames.shutdown()
        guard let cg else { return nil }
        let name = String(format: "thumb-%016llx.jpg", hash)
        guard let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? name : nil
    }

    // MARK: collections
    /// Film series from TMDB with at least two films here (`auto`, unless deleted), then collections made
    /// by hand (empty ones too).
    var collections: [(name: String, items: [LibraryItem], auto: Bool)] {
        var auto: [String: [LibraryItem]] = [:]
        let d = UserDefaults.standard       // Library settings can leave either kind out
        let tmdb = d.object(forKey: "tmdbCollections") as? Bool ?? true, custom = d.object(forKey: "customCollections") as? Bool ?? true
        for it in movies where tmdb { if let c = meta[it.metaKey]?.collection, !hiddenCollections.contains(c) { auto[c, default: []].append(it) } }
        let byKey = Dictionary((movies + shows).map { ($0.metaKey, $0) }, uniquingKeysWith: { a, _ in a })
        let manual = (custom ? userCollections : [:]).map { (name: $0.key, items: $0.value.compactMap { byKey[$0] }, auto: false) }
        return (auto.filter { $0.value.count >= 2 }.map { (name: $0.key, items: $0.value, auto: true) } + manual).sorted { $0.name < $1.name }
    }
    func createCollection(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, userCollections[n] == nil else { return }
        userCollections[n] = []; save()
    }
    /// A hand-made collection is removed; a TMDB series is hidden for good. The films stay in the library.
    func deleteCollection(_ name: String, auto: Bool) {
        if auto { hiddenCollections.insert(name) } else { userCollections[name] = nil }
        save()
    }
    func addToCollection(_ it: LibraryItem, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, userCollections[n]?.contains(it.metaKey) != true else { return }
        userCollections[n, default: []].append(it.metaKey); save()
    }
    func removeFromCollection(_ it: LibraryItem, _ name: String) {
        userCollections[name]?.removeAll { $0 == it.metaKey }      // an emptied collection stays until deleted
        save()
    }
    /// Genres present among these items, most common first.
    func genres(in list: [LibraryItem]) -> [String] {
        var n: [String: Int] = [:]
        for it in list { for g in meta[it.metaKey]?.genres ?? [] { n[g, default: 0] += 1 } }
        return n.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    // MARK: lookups for the views
    func title(for it: LibraryItem) -> String { let t = meta[it.metaKey]?.title ?? ""; return t.isEmpty ? it.title : t }
    /// Card and detail title: the metadata title, or the file name with "Show filenames" on
    /// (a show: its folder's name).
    func displayTitle(for it: LibraryItem) -> String {
        guard UserDefaults.standard.bool(forKey: "showFilenames") else { return title(for: it) }
        let name = it.isEpisode ? (showFolder(it.path) as NSString).lastPathComponent : (it.path as NSString).lastPathComponent
        return it.isEpisode ? name : (name as NSString).deletingPathExtension
    }
    func year(for it: LibraryItem) -> String? { meta[it.metaKey]?.year ?? it.year }
    private func image(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let img = images.object(forKey: name as NSString) { return img }
        let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : imageDir.appendingPathComponent(name)
        guard let img = NSImage(contentsOf: url) else { return nil }
        images.setObject(img, forKey: name as NSString)
        return img
    }
    /// Poster / backdrop from the database or local artwork, else the frame-grab cover.
    /// With "Prefer embedded artwork" the file's own cover wins over both.
    func poster(for it: LibraryItem) -> NSImage? {
        if preferEmbedded, let t = thumbs[it.path], t.hasPrefix("cover-") { return image(t) }
        return image(meta[it.metaKey]?.poster) ?? thumbnail(it.path)
    }
    private var preferEmbedded: Bool { UserDefaults.standard.bool(forKey: "preferEmbeddedArtwork") }
    func backdrop(for it: LibraryItem) -> NSImage? { image(meta[it.metaKey]?.backdrop) ?? thumbnail(it.path) }
    /// True when neither exists yet, so the view should ask for a frame-grab cover.
    func needsThumb(_ it: LibraryItem) -> Bool {
        thumbs[it.path] == nil && (preferEmbedded || meta[it.metaKey]?.poster == nil || meta[it.metaKey]?.backdrop == nil)
    }
    /// The player's title for a file: "The Batman" + year, or "Show · S1 · E2 · Episode". From the file name
    /// and the stored metadata, so it works even before a scan (Finder open). nil = nothing known: use cleanTitle.
    func playerTitle(_ path: String) -> (String, String?)? {
        guard !path.contains("://") else { return nil }             // streams: Jellyfin names them itself
        let it = parseMediaName(path)
        guard meta[it.metaKey] != nil else { return nil }
        guard it.isEpisode else { return (title(for: it), year(for: it)) }
        let name = episodeMeta(it)?.title ?? ""
        return (([title(for: it), it.episodeLabel] + (name.isEmpty ? [] : [name])).joined(separator: " · "), nil)
    }
    func episodeMeta(_ it: LibraryItem) -> EpisodeMeta? {
        guard let s = it.season, let e = it.episode else { return nil }
        return meta[it.metaKey]?.seasons?[s]?.episodes[e]
    }

    var movies: [LibraryItem] { items.filter { !$0.isEpisode } }
    /// One entry per show (its first episode), in title order.
    var shows: [LibraryItem] {
        var seen = Set<String>()
        return items.filter { $0.isEpisode && seen.insert($0.metaKey).inserted }
    }
    func episodes(of show: LibraryItem) -> [LibraryItem] { items.filter { $0.isEpisode && $0.metaKey == show.metaKey } }

    /// Started but not finished, plus the next episode of a show in progress; most recent first.
    var continueWatching: [LibraryItem] {
        var out = items.filter { if let p = play[$0.path] { return !p.watched && p.position > 60 } else { return false } }
        for show in shows {
            let eps = episodes(of: show)
            guard !eps.contains(where: { e in out.contains(e) }),                       // already resuming one
                  let last = eps.lastIndex(where: { play[$0.path]?.watched == true }), last + 1 < eps.count else { continue }
            out.append(eps[last + 1])
        }
        func when(_ it: LibraryItem) -> Date {
            if let p = play[it.path] { return p.updated }
            return episodes(of: it).compactMap { play[$0.path]?.updated }.max() ?? .distantPast    // next up: when its show was last watched
        }
        return out.filter { it in hiddenContinue[it.path].map { when(it) > $0 } ?? true }.sorted { when($0) > when($1) }
    }
    /// Remove from Continue Watching = forget it was started (user, 2026-11-15): its progress and the player's
    /// resume position are cleared, so it plays from the start. A "next up" episode that was never started only
    /// needs hiding until its show is watched again.
    func removeFromContinue(_ it: LibraryItem) {
        if play[it.path] != nil, play[it.path]?.watched != true {
            play[it.path] = nil
            var d = UserDefaults.standard.dictionary(forKey: "resumePositions") ?? [:]   // PlayerModel's resume store
            d.removeValue(forKey: it.path); UserDefaults.standard.set(d, forKey: "resumePositions")
        } else {
            hiddenContinue[it.path] = Date()
        }
        save()
    }
    /// Newest films and shows (a show counts by its newest episode).
    var recentlyAdded: [LibraryItem] {
        let showDates = shows.map { s in (s, episodes(of: s).map(\.added).max() ?? .distantPast) }
        return (movies.map { ($0, $0.added) } + showDates).sorted { $0.1 > $1.1 }.prefix(20).map(\.0)
    }

    // MARK: watched state
    /// Called by the player every few seconds. Only files inside a library folder are tracked.
    func setProgress(_ path: String, position: Double, duration: Double) {
        guard duration > 0, folders.contains(where: { path.hasPrefix($0 + "/") }) else { return }
        let was = play[path]?.watched ?? false
        // Watched once the credits are reached: the last 8% or the last 3 minutes, whichever is shorter.
        let watched = was || position >= duration - min(duration * 0.08, 180)
        play[path] = PlayState(position: watched ? 0 : position, duration: duration, watched: watched, updated: Date())
        save()
    }
    func setWatched(_ paths: [String], _ watched: Bool) {
        for p in paths {
            play[p] = PlayState(position: 0, duration: play[p]?.duration ?? 0, watched: watched, updated: Date())
        }
        save()
    }
}
