import AppKit
import SwiftUI

// The library detail page: backdrop header, badges, track pickers, episodes, cast.

/// A film, or a show with its seasons and episodes.
struct DetailView: View {
    @ObservedObject private var lib = Library.shared
    let item: LibraryItem
    let onPlay: (String) -> Void
    let onPlayTracks: (String, TrackChoice) -> Void
    @State private var season: Int?
    @State private var tracks = TrackChoice()          // nil = automatic (the user's languages)
    @State private var fixing = false
    @State private var showOverview = false     // the MORE popover: full summary
    @State private var showInfo = false         // the "i" popover: video, audio and subtitle tracks
    @AppStorage("showFilenames") private var showFilenames = false     // re-render when the Library setting flips

    var body: some View {
        let m = lib.meta[item.metaKey]
        let eps = item.isEpisode ? lib.episodes(of: item) : []
        let seasons = Array(Set(eps.compactMap(\.season))).sorted()
        let current = season ?? seasons.first
        // What Play starts: the film, or the show's next episode (in progress, else first unwatched).
        let target = item.isEpisode
            ? (eps.first { (lib.play[$0.path]?.position ?? 0) > 0 && lib.play[$0.path]?.watched != true }
               ?? eps.first { lib.play[$0.path]?.watched != true } ?? eps.first ?? item)
            : item
        let st = lib.play[target.path]
        let resuming = (st?.position ?? 0) > 0 && st?.watched != true
        let paths = item.isEpisode ? eps.map(\.path) : [item.path]
        let allWatched = paths.allSatisfy { lib.play[$0]?.watched == true }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        if let img = lib.backdrop(for: item) { Color.clear.overlay(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)).clipped() }
                        else { Color(white: 0.15) }
                        heroScrim
                    }
                    .frame(minHeight: 480)
                    .backgroundExtensionEffect()        // only the picture runs under the sidebar and toolbar
                    HStack(alignment: .bottom, spacing: 40) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(lib.displayTitle(for: item)).font(.system(size: 40, weight: .heavy)).lineLimit(2).shadow(color: .black.opacity(0.5), radius: 12)
                            if let t = m?.tagline, !t.isEmpty { Text(t).font(.title3).italic().foregroundStyle(.secondary) }
                            Text(item.isEpisode ? "TV Show" : "Film")      // genres sit bottom right
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            if let o = m?.overview, !o.isEmpty {
                                HStack(alignment: .lastTextBaseline, spacing: 8) {
                                    Text(o).font(.system(size: 14)).lineLimit(2)
                                    // shortcut: length guess for "is it cut off", upgrade to a measured truncation check if it misfires
                                    if o.count > 160 { Button("MORE") { showOverview = true }
                                        .font(.system(size: 10, weight: .bold)).buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.mini)
                                        .popover(isPresented: $showOverview) {
                                            Text(o).font(.system(size: 14)).lineSpacing(3).frame(width: 420, alignment: .leading).padding(18)
                                                .fixedSize(horizontal: false, vertical: true)
                                        } }
                                }
                                .frame(maxWidth: 620, alignment: .leading)
                            }
                            FactsLine(item: item, badges: true).padding(.top, 2)
                            HStack(spacing: 10) {
                                Button { item.isEpisode ? onPlay(target.path) : onPlayTracks(target.path, tracks) } label: {
                                    Label(playLabel(target, resuming: resuming, st: st), systemImage: "play.fill")
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.black)
                                        .padding(.horizontal, 22).padding(.vertical, 9).background(Capsule().fill(.white)).contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                Button { lib.setWatched(paths, !allWatched) } label: { Image(systemName: allWatched ? "checkmark.circle.fill" : "checkmark.circle") }
                                    .buttonStyle(.bordered).buttonBorderShape(.circle).help(allWatched ? "Mark as Unwatched" : "Mark as Watched")
                                Menu {
                                    Button("Fix Match…") { fixing = true }
                                    if !item.isEpisode { Button("Show in Finder") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") } }
                                } label: { Image(systemName: "ellipsis") }
                                    .menuIndicator(.hidden).buttonStyle(.bordered).buttonBorderShape(.circle).fixedSize().help("More")
                                if !item.isEpisode, let info = lib.mediaInfo[item.path], info.readable {
                                    Button { showInfo = true } label: { Image(systemName: "info") }
                                        .buttonStyle(.bordered).buttonBorderShape(.circle).help("Video & Audio")
                                        .popover(isPresented: $showInfo) { TechInfo(info: info) }
                                }
                            }
                            .controlSize(.large).padding(.top, 6)
                            if !item.isEpisode, let info = lib.mediaInfo[item.path], let ids = info.audioIDs { trackPickers(info, ids) }
                        }
                        .layoutPriority(1)      // the facts row keeps its width; the cast column gives way
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 18) {
                            Ratings(meta: m).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            if let g = m?.genres, !g.isEmpty {
                                Text(g.prefix(3).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .frame(maxWidth: 320, alignment: .trailing)
                    }
                    .padding(.horizontal, sidePadding).padding(.bottom, 24)
                    .environment(\.colorScheme, .dark)      // the backdrop is a dark picture in light mode too
                }
                VStack(alignment: .leading, spacing: 26) {
                    if item.isEpisode {
                        if seasons.count > 1 {
                            Picker("Season", selection: Binding(get: { current }, set: { season = $0 })) {
                                ForEach(seasons, id: \.self) { Text("Season \($0)").tag(Int?.some($0)) }
                            }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                        } else if let s = seasons.first {
                            Text("Season \(s)").font(.title2.bold())
                        }
                        VStack(spacing: 6) {
                            ForEach(eps.filter { $0.season == current }) { ep in EpisodeRow(item: ep) { onPlay(ep.path) } }
                        }
                        .padding(.horizontal, -10)      // the row's hover inset; stills line up with the page edge
                    }
                    if let cast = m?.cast, !cast.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Cast").font(.title2.bold())
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(alignment: .top, spacing: 18) { ForEach(cast, id: \.self) { CastBubble(member: $0) } }
                            }
                        }
                    }
                }
                .padding(.horizontal, sidePadding).padding(.top, 24).padding(.bottom, 50)
            }
        }
        .onAppear { if lib.needsThumb(item) { lib.requestThumb(item.path) }; if !item.isEpisode { lib.requestInfo(item.path) } }
        .sheet(isPresented: $fixing) { FixMatchSheet(item: item, query: lib.title(for: item)) }
    }

    /// Audio and subtitle menus next to Play (films). Automatic = the engine picks by the user's languages.
    @ViewBuilder private func trackPickers(_ info: MediaInfo, _ audioIDs: [Int]) -> some View {
        let subs = info.subtitles ?? [], subIDs = info.subtitleIDs ?? []
        HStack(spacing: 10) {
            if audioIDs.count > 1 {
                Picker(selection: $tracks.audio) {
                    Text("Automatic").tag(Int?.none)
                    ForEach(Array(zip(audioIDs, info.audio)), id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
                } label: { Label("Audio", systemImage: "speaker.wave.2") }
                .fixedSize()
            }
            if !subIDs.isEmpty {
                Picker(selection: $tracks.subtitle) {
                    Text("Automatic").tag(Int?.none)
                    Text("Off").tag(Int?.some(-1))
                    ForEach(Array(zip(subIDs, subs)), id: \.0) { Text($0.1).tag(Int?.some($0.0)) }
                } label: { Label("Subtitles", systemImage: "captions.bubble") }
                .fixedSize()
            }
        }
        .pickerStyle(.menu).controlSize(.regular)
    }

    private func playLabel(_ target: LibraryItem, resuming: Bool, st: PlayState?) -> String {
        let ep = target.isEpisode ? " \(target.episodeLabel)" : ""
        return resuming ? "Resume\(ep) · \(formatTime(st?.position ?? 0))" : "Play\(ep)"
    }
}

/// Episode: still, number and title, runtime, summary, progress, watched mark.
private struct EpisodeRow: View {
    @ObservedObject private var lib = Library.shared
    let item: LibraryItem
    let action: () -> Void
    @State private var hover = false
    @AppStorage("showWatchedIndicators") private var showWatched = true
    @AppStorage("hideSpoilers") private var hideSpoilers = false

    var body: some View {
        let st = lib.play[item.path]
        let em = lib.episodeMeta(item)
        let spoil = hideSpoilers && st?.watched != true     // unwatched: blur the still, hide the summary
        let name = (em?.title).flatMap { $0.isEmpty ? nil : $0 } ?? ((item.path as NSString).lastPathComponent as NSString).deletingPathExtension
        Button(action: action) {
            HStack(alignment: .top, spacing: 16) {
                ZStack(alignment: .bottom) {
                    if let s = em?.still, let url = TMDB.imageURL(s, width: 300) {
                        AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill).blur(radius: spoil ? 14 : 0) } placeholder: { placeholder }
                    } else {
                        placeholder.overlay(Image(systemName: "play.fill").foregroundStyle(.secondary))
                    }
                    if showWatched, let st, !st.watched, st.duration > 0, st.position > 0 { ProgressStrip(fraction: st.position / st.duration) }
                }
                .frame(width: 176, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("\(item.episode ?? 0). \(name)").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        if showWatched, st?.watched == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 6) {
                        if let r = runtimeText(em?.runtime) { Text(r).font(.system(size: 12)).foregroundStyle(.secondary) }
                        TagRow(tags: lib.mediaInfo[item.path]?.tags ?? [])
                    }
                    if let o = em?.overview, !o.isEmpty {
                        Text(spoil ? "Summary hidden until watched" : o).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear { lib.requestInfo(item.path) }
        .contextMenu {
            Button(st?.watched == true ? "Mark as Unwatched" : "Mark as Watched") { lib.setWatched([item.path], !(st?.watched == true)) }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") }
        }
    }
}

/// Outlined tags ("4K", "Dolby Vision", "Atmos"), in the page's own colours (light and dark).
struct TagRow: View {
    let tags: [String]
    var size: CGFloat = 9.5
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(.system(size: size, weight: .bold)).foregroundStyle(.secondary).fixedSize()
                    .padding(.horizontal, size * 0.45).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(.secondary.opacity(0.6), lineWidth: 1))
            }
        }
    }
}

/// Detail header badges, Apple TV style: resolution box, one HDR mark, one audio mark (best format of the user's-language tracks),
/// then CC / SDH / AD boxes. A mark without a logo file shows as an outlined text box.
/// Every mark and box is `height` tall so the row (and the 16 pt IMDb / RT plates after it in FactsLine) reads as one line.
struct DetailTags: View {
    let info: MediaInfo
    private let height: CGFloat = 16
    var body: some View {
        // The best format among the user's-language tracks (else all tracks): a Russian dub listed first must not hide
        // the English Atmos track.
        let own = Locale.current.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? ""
        let mine = info.audio.filter { !own.isEmpty && $0.hasPrefix(own + " ·") }
        let pool = mine.isEmpty ? info.audio : mine
        let hdr = info.hdr.map { $0.hasPrefix("Dolby Vision") ? "Dolby Vision" : $0 }
        let audio = pool.contains { $0.contains("Atmos") } ? "Dolby Atmos" : pool.contains { $0.contains("DTS:X") } ? "DTS:X"
                  : pool.contains { $0.contains("DTS-HD MA") } ? "DTS-HD Master Audio" : pool.contains { $0.contains("DTS") } ? "DTS"
                  : pool.contains { $0.contains("TrueHD") } ? "Dolby TrueHD" : pool.contains { $0.contains("Dolby Digital Plus") } ? "Dolby Digital Plus"
                  : pool.contains { $0.contains("Dolby Digital") } ? "Dolby Digital" : nil
        let audioLogos = ["Dolby Atmos": Logo.dolbyAtmos, "DTS:X": Logo.dtsX, "DTS-HD Master Audio": Logo.dtsHDMA, "DTS": Logo.dts,
                          "Dolby TrueHD": Logo.dolbyTrueHD, "Dolby Digital Plus": Logo.dolbyDigitalPlus, "Dolby Digital": Logo.dolbyDigital]
        let hdrLogos = ["Dolby Vision": Logo.dolbyVision, "HDR10+": Logo.hdr10Plus, "HDR10": Logo.hdr10]      // HLG: no clean mark, stays text
        let subs = info.subtitles ?? []
        HStack(spacing: 8) {
            if info.width > 0 { box(resolutionLabel(width: info.width, height: info.height)) }
            if let hdr { mark(hdr, hdrLogos[hdr] ?? nil) }
            if let audio { mark(audio, audioLogos[audio] ?? nil) }
            if !subs.isEmpty { box("CC").help("Subtitles") }
            if subs.contains(where: { $0.contains("SDH") }) { box("SDH").help("Subtitles for the deaf and hard of hearing") }
            // shortcut: AD spotted from the track title only ("Audio Description"), upgrade if the probe exposes the disposition
            if info.audio.contains(where: { $0.lowercased().contains("descri") }) { box("AD").help("Audio description") }
        }
    }
    @ViewBuilder private func mark(_ name: String, _ logo: NSImage?) -> some View {
        if let logo {
            Image(nsImage: logo).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                .frame(height: height).foregroundStyle(.primary.opacity(0.85))
                .accessibilityLabel(name).help(name)
        } else {
            box(name)
        }
    }
    /// An outlined text box (TagRow's look) at the row's full height.
    private func box(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).fixedSize()
            .padding(.horizontal, 4.5).frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(.secondary.opacity(0.6), lineWidth: 1))
    }
}

/// Detail page "i" popover: the file's video, audio and subtitle tracks, from MediaInfo.
private struct TechInfo: View {
    let info: MediaInfo
    /// The user's own language first, then the rest in file order (names start "English · …").
    private var ordered: [String] {
        let own = Locale.current.language.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? ""
        let mine = info.audio.filter { !own.isEmpty && $0.hasPrefix(own + " ·") }
        return mine + info.audio.filter { !mine.contains($0) }
    }
    var body: some View {
        let subs = info.subtitles ?? []
        VStack(alignment: .leading, spacing: 14) {
            if info.width > 0 {
                section("Video", [["\(resolutionLabel(width: info.width, height: info.height)) (\(info.width)×\(info.height))",
                                   info.hdr ?? "SDR", info.videoCodec].compactMap { $0 }.joined(separator: " · ")])
            }
            section("Audio", ordered.isEmpty ? ["None"] : ordered)
            section("Subtitles", subs.isEmpty ? ["None"] : subs)
        }
        .font(.system(size: 13)).textSelection(.enabled)
        .frame(minWidth: 280, alignment: .leading).padding(18).fixedSize()
    }
    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element) }
        }
    }
}

private struct CastBubble: View {
    let member: CastMember
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let p = member.photo, let url = TMDB.imageURL(p, width: 185) {
                    AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) } placeholder: { placeholder }
                } else {
                    placeholder.overlay(Image(systemName: "person.fill").font(.title).foregroundStyle(.secondary))
                }
            }
            .frame(width: 84, height: 84).clipShape(Circle())
            Text(member.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(member.role).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 104)
    }
}

