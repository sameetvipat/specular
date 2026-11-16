import AppKit
import SwiftUI

// The library window, in the style of the Apple TV app: a full-bleed hero for what you were
// watching, horizontal shelves, poster grids, and a detail page with backdrop, cast and episodes.
// A standard window: system sidebar, unified toolbar (title, Back, Refresh, search), system appearance.

extension AppDelegate {
    func showLibrary() {
        Jellyfin.selfTestIfAsked()      // PLAYER_JELLYTEST=1: offline check, then quits
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: LibraryView(
                onPlay: { [weak self] p in self?.play(p) },
                onPlayTracks: { [weak self] p, t in self?.play(p, tracks: t) },
                onOpenFile: { [weak self] in self?.showOpenPanel() },
                onOpenURL: { [weak self] in self?.showOpenURL() }))
            host.sceneBridgingOptions = [.toolbars, .title]     // SwiftUI .toolbar / .navigationTitle / .searchable drive this window
            let size = w.frame.size
            w.contentViewController = host
            w.setContentSize(size)                              // the controller shrank the window to the view's minimum
            w.toolbarStyle = .unified
            w.center()
            w.setFrameAutosaveName("Library")
            libraryWindow = w
            Library.shared.rescan()
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func mLibrary() { showLibrary() }
}

private let pageBackground = Color(nsColor: .windowBackgroundColor)
let placeholder = Color(nsColor: .quaternarySystemFill)     // where artwork is missing or loading
let sidePadding: CGFloat = 40

/// Darkens the bottom and leading edge of a backdrop so white text reads over any picture.
var heroScrim: some View {
    ZStack {
        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .init(x: 0.5, y: 0.25), endPoint: .bottom)
        LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .leading, endPoint: .center)
    }
}

/// Rating logos shipped in the package's resource bundle (app/Logos, SVG). Looked up by hand, not via
/// Bundle.module, so a missing bundle shows text instead of crashing: next to the executable in a dev
/// build, in Contents/Resources in Specular.app.
enum Logo {
    private static let dir: URL? = {
        let main = Bundle.main
        return [main.resourceURL, main.bundleURL, main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
            .compactMap { Bundle(url: $0.appendingPathComponent("player_player.bundle"))?.resourceURL?.appendingPathComponent("Logos") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }()
    static let imdb = load("imdb"), tmdb = load("tmdb"), fresh = load("rt-fresh"), rotten = load("rt-rotten")
    /// One-colour marks: drawn as templates, in the text colour of the page. The DTS marks are colour, but their
    /// black parts vanish on the dark header, so they are tinted too.
    static let dolbyVision = load("dolby-vision-stacked", template: true), dolbyAtmos = load("dolby-atmos-stacked", template: true),
               dts = load("dts", template: true), dtsHDMA = load("dts-hd-ma", template: true), hdr10Plus = load("hdr10plus", template: true),
               hdr10 = load("hdr10", template: true), dtsX = load("dts-x", ext: "png", template: true),     // Commons has DTS:X as PNG only
               dolbyTrueHD = load("dolby-truehd", template: true), dolbyDigitalPlus = load("dolby-digital-plus", template: true),
               dolbyDigital = load("dolby-digital", template: true)
    private static func load(_ name: String, ext: String = "svg", template: Bool = false) -> NSImage? {
        let img = dir.flatMap { NSImage(contentsOf: $0.appendingPathComponent(name + "." + ext)) }
        img?.isTemplate = template
        return img
    }
}

func runtimeText(_ minutes: Int?) -> String? {
    guard let m = minutes, m > 0 else { return nil }
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

extension Notification.Name {
    /// Post (e.g. from an Edit > Find menu item) to focus the library's search field, like Cmd-F in the window.
    static let librarySearch = Notification.Name("LibrarySearch")
}

struct LibraryView: View {
    enum Tab: String, CaseIterable { case home = "Home", films = "Films", shows = "Shows", collections = "Collections", jellyFilms = "Jellyfin Films", jellyShows = "Jellyfin Shows" }
    enum Sort: String, CaseIterable { case title = "Title", year = "Year", added = "Recently Added" }

    @ObservedObject private var lib = Library.shared
    @ObservedObject private var jelly = Jellyfin.shared
    let onPlay: (String) -> Void
    let onPlayTracks: (String, TrackChoice) -> Void
    let onOpenFile: () -> Void
    let onOpenURL: () -> Void
    @AppStorage("libraryTab") private var tab = Tab.home
    @AppStorage("showFilenames") private var showFilenames = false     // re-render when the Library setting flips
    @AppStorage("showUpNext") private var showUpNext = true
    @AppStorage("tmdbCollections") private var tmdbCollections = true      // read by Library.collections
    @AppStorage("customCollections") private var customCollections = true
    @State private var sort = Sort.title
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var genre: String?               // nil = all genres
    @State private var detail: LibraryItem?         // film, or a show's first episode
    @State private var addingServer = false         // Jellyfin sign-in sheet
    @State private var jellySeries: JellyfinItem?   // Jellyfin show whose episodes are listed
    @State private var page: Page?                  // a full page opened from a shelf arrow or a collection tile
    enum Page: Hashable { case collection(String), recent }
    private var onJellyfin: Bool { tab == .jellyFilms || tab == .jellyShows }

    private func matches(_ it: LibraryItem) -> Bool {
        search.isEmpty || lib.title(for: it).localizedCaseInsensitiveContains(search) || it.title.localizedCaseInsensitiveContains(search)
    }
    private func sorted(_ list: [LibraryItem]) -> [LibraryItem] {
        switch sort {
        case .title: return list.sorted { lib.title(for: $0).localizedStandardCompare(lib.title(for: $1)) == .orderedAscending }
        case .year:  return list.sorted { (lib.year(for: $0) ?? "") > (lib.year(for: $1) ?? "") }
        case .added: return list.sorted { $0.added > $1.added }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                // Home has no search field; Films, Shows, Collections and the pages opened from them do.
                if onHome { detailPage } else { detailPage.searchable(text: $search, placement: .toolbar).searchFocused($searchFocused) }
            }
            .background(pageBackground)
            .toolbar { toolbar }
            .background { Button("Find", action: focusSearch).keyboardShortcut("f").opacity(0).allowsHitTesting(false) }   // Cmd-F
        }
        .onReceive(NotificationCenter.default.publisher(for: .librarySearch)) { _ in focusSearch() }
        .onChange(of: search) { if !$1.isEmpty { detail = nil; jellySeries = nil; page = nil } }    // typing on a detail page shows the results
        .frame(minWidth: 960, minHeight: 520)       // sidebar + content
        .animation(.smooth(duration: 0.3), value: detail)
        .animation(.smooth(duration: 0.3), value: page)
        .animation(.smooth(duration: 0.25), value: tab)
        .sheet(isPresented: $addingServer) { JellyfinSheet() }
    }

    /// Cmd-F: focus the search field. Home has none, so go to Films first and focus once the field is there.
    private func focusSearch() {
        if onHome { tab = .films }
        searchFocused = false
        Task { try? await Task.sleep(for: .milliseconds(100)); searchFocused = true }
    }

    private var onHome: Bool { tab == .home && detail == nil && page == nil && jellySeries == nil && search.isEmpty }

    @ViewBuilder private var detailPage: some View {
        if let s = jellySeries { JellyfinEpisodes(series: s, onPlay: onPlay).navigationTitle(s.Name) }
        else if onJellyfin {
            JellyfinGrid(films: tab == .jellyFilms, search: search) { it in
                if tab == .jellyShows { jellySeries = it }
                else if let u = jelly.streamURL(it.Id, title: it.Name + (it.ProductionYear.map { " (\($0))" } ?? "")) { onPlay(u) }
            }
        }
        else if lib.folders.isEmpty { empty.navigationTitle(tab.rawValue) }
        else if let d = detail { DetailView(item: d, onPlay: onPlay, onPlayTracks: onPlayTracks).navigationTitle(lib.displayTitle(for: d)) }
        else if !search.isEmpty { results }
        else if page == .recent { grid(lib.recentlyAdded, title: "Recently Added", showSort: false) }
        else if case .collection(let n)? = page, let c = lib.collections.first(where: { $0.name == n }) {
            grid(c.items, title: c.name, showSort: false, emptyText: "Empty. Right-click a poster and choose Add to Collection.")
        }
        else {
            switch tab {
            case .home:  home.navigationTitle(tab.rawValue)
            case .films: grid(sorted(lib.movies), title: "Films")
            case .shows: grid(sorted(lib.shows), title: "Shows")
            case .collections: collectionsPage
            case .jellyFilms, .jellyShows: EmptyView()      // handled above
            }
        }
    }

    // MARK: sidebar
    private var sidebar: some View {
        // No row is selected on a detail page or in search results, so a click on the current entry still leaves them.
        List(selection: Binding<Tab?>(get: { detail == nil && jellySeries == nil && page == nil && search.isEmpty ? tab : nil },
                                      set: { if let t = $0 { tab = t; detail = nil; jellySeries = nil; page = nil; search = "" } })) {
            Section("Library") {
                ForEach([Tab.home, .films, .shows, .collections], id: \.self) { t in
                    Label(t.rawValue, systemImage: t == .home ? "house" : t == .films ? "film" : t == .shows ? "tv" : "rectangle.stack").tag(t)
                }
            }
            Section("Jellyfin") {
                if jelly.server == nil {
                    Button { addingServer = true } label: { sidebarRow("Add Jellyfin Server…", "server.rack") }.buttonStyle(.plain)
                } else {
                    Group {
                        Label("Films", systemImage: "film").tag(Tab.jellyFilms)
                        Label("Shows", systemImage: "tv").tag(Tab.jellyShows)
                    }
                    .contextMenu {
                        Button("Sign Out") { jelly.signOut(); jellySeries = nil; if onJellyfin { tab = .home; page = nil } }
                    }
                }
            }
            Section("Open") {       // plain sidebar rows, like the ones above (a button never stays selected)
                Button(action: onOpenFile) { sidebarRow("Open File…", "doc") }
                Button(action: onOpenURL) { sidebarRow("Open URL…", "link") }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    /// A sidebar action drawn like a selectable row: accent-tinted icon, full-width hit area.
    private func sidebarRow(_ title: String, _ icon: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(.tint) }
            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if detail != nil || jellySeries != nil || page != nil {
            ToolbarItem(placement: .navigation) {
                // One level at a time: a film opened from a collection page goes back to that page.
                Button { if detail != nil || jellySeries != nil { detail = nil; jellySeries = nil } else { page = nil } } label: { Label("Back", systemImage: "chevron.left") }.help("Back")
            }
        }
        if lib.scanning || !lib.status.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Text(lib.status.isEmpty ? "Scanning…" : lib.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // Next to the search field: Refresh, swapped for a spinner while a scan runs. Folders are added in Settings > Library.
        ToolbarItem(placement: .primaryAction) {
            if lib.scanning {
                ProgressView().controlSize(.small)
            } else {
                Button { lib.rescan(refresh: true) } label: { Label("Refresh Library", systemImage: "arrow.clockwise") }
                    .help("Refresh Library").disabled(lib.folders.isEmpty)
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "film.stack")
        } description: {
            Text("Add a folder of films or shows. Posters, summaries, cast and episode details are fetched automatically.")
        } actions: {
            Button("Add Folder…") { addFolder() }.buttonStyle(.borderedProminent)
        }
    }

    // MARK: home: hero + shelves
    private var home: some View {
        let cont = showUpNext ? lib.continueWatching : []     // Up Next off: Recently Added leads the hero
        let recent = lib.recentlyAdded
        return ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                let feat = featured(cont: cont, recent: recent)
                if !feat.isEmpty {
                    HeroCarousel(items: feat, upNext: Set(cont.map(\.path)), onPlay: onPlay,
                                 onDetails: { it in detail = lib.shows.first { $0.metaKey == it.metaKey } ?? it })
                }
                if !cont.isEmpty {
                    Shelf(title: "Continue Watching", items: cont) { it in WideCard(item: it) { onPlay(it.path) } }
                }
                if !recent.isEmpty {
                    Shelf(title: "Recently Added", items: recent, onMore: { page = .recent }) { it in PosterCard(item: it, width: 150) { detail = it } }
                }
                ForEach(lib.collections.filter { !$0.items.isEmpty }, id: \.name) { c in
                    Shelf(title: c.name, items: c.items, onMore: { page = .collection(c.name) }) { it in PosterCard(item: it, width: 150) { detail = it } }
                }
                if !lib.movies.isEmpty {
                    Shelf(title: "Films", items: Array(lib.movies.prefix(30)), onMore: { tab = .films }) { it in PosterCard(item: it, width: 150) { detail = it } }
                }
                if !lib.shows.isEmpty {
                    Shelf(title: "Shows", items: Array(lib.shows.prefix(30)), onMore: { tab = .shows }) { it in PosterCard(item: it, width: 150) { detail = it } }
                }
                if lib.items.isEmpty && !lib.scanning {
                    Text("No video files found in the library folders.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 160)
                }
            }
            .padding(.bottom, 40)
        }
    }

    /// Hero picks, a show once each: up to 3 Continue Watching, 2 Recently Added, then well-rated titles to 6.
    private func featured(cont: [LibraryItem], recent: [LibraryItem]) -> [LibraryItem] {
        // hashValue is seeded per launch: a different random pick each run that stays put while the app is open
        let rated = (lib.movies + lib.shows).filter { (lib.meta[$0.metaKey]?.rating ?? 0) >= 7 }.sorted { $0.metaKey.hashValue < $1.metaKey.hashValue }
        var seen = Set<String>(), out: [LibraryItem] = []
        for (list, cap) in [(cont, 3), (recent, 2), (rated, 6)] {
            var n = 0
            for it in list where n < cap && out.count < 6 && seen.insert(it.metaKey).inserted { out.append(nextUp(it)); n += 1 }
        }
        return out
    }
    /// What Play starts for a show: the episode in progress, else the first unwatched (same rule as the detail page).
    private func nextUp(_ it: LibraryItem) -> LibraryItem {
        guard it.isEpisode, lib.play[it.path] == nil || lib.play[it.path]?.watched == true else { return it }
        let eps = lib.episodes(of: it)
        return eps.first { (lib.play[$0.path]?.position ?? 0) > 0 && lib.play[$0.path]?.watched != true }
            ?? eps.first { lib.play[$0.path]?.watched != true } ?? it
    }

    /// Every collection as a tile: film series from TMDB (2+ films here) and the ones made by hand.
    private var collectionsPage: some View {
        let all = lib.collections
        return Group {
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No Collections", systemImage: "rectangle.stack")
                } description: {
                    Text("Film series appear here once two of their films are in the library. Make your own, then add films with a poster's “Add to Collection”.")
                } actions: {
                    Button("New Collection…") { if let n = askCollectionName() { lib.createCollection(n) } }.buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                        ForEach(all, id: \.name) { c in
                            CollectionTile(name: c.name, items: c.items) { page = .collection(c.name) }
                                .contextMenu {
                                    Button("Delete Collection…") { if confirmDelete(c.name, auto: c.auto) { lib.deleteCollection(c.name, auto: c.auto) } }
                                }
                        }
                    }
                    .padding(.horizontal, sidePadding).padding(.top, 20).padding(.bottom, 40)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { if let n = askCollectionName() { lib.createCollection(n) } } label: { Label("New Collection", systemImage: "folder.badge.plus") }
                    .help("New Collection")
            }
        }
        .navigationTitle("Collections")
        .navigationSubtitle(all.isEmpty ? "" : all.count == 1 ? "1 collection" : "\(all.count) collections")
    }

    private var results: some View {
        grid((lib.movies + lib.shows).filter(matches), title: "Results for “\(search)”", showSort: false)
    }

    private func grid(_ all: [LibraryItem], title: String, showSort: Bool = true, emptyText: String = "Nothing here yet.") -> some View {
        let genres = showSort ? lib.genres(in: all) : []
        let pick = genres.contains(genre ?? "") ? genre : nil       // a genre picked on the other tab may not exist here
        let list = pick == nil ? all : all.filter { lib.meta[$0.metaKey]?.genres?.contains(pick!) == true }
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if showSort { HStack {
                    Spacer()
                    if !genres.isEmpty {
                        Picker("Genre", selection: $genre) {
                            Text("All Genres").tag(String?.none)
                            ForEach(genres, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    if showSort {
                        Picker("Sort", selection: $sort) { ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                } }
                if list.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                    ForEach(list) { it in PosterCard(item: it, width: nil) { detail = it } }
                }
            }
            .padding(.horizontal, sidePadding).padding(.top, 20).padding(.bottom, 40)
        }
        .navigationTitle(title)
        .navigationSubtitle(list.count == 1 ? "1 item" : "\(list.count) items")    // count lives in the toolbar, no big heading
    }

    private func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
        p.message = "Choose folders that hold your films and shows"
        if p.runModal() == .OK { for u in p.urls { lib.addFolder(u.path) } }
    }
}

// MARK: - home pieces

/// The featured items, crossfading every 8 s like the Apple TV app; paused under the pointer or in a background window.
private struct HeroCarousel: View {
    @ObservedObject private var lib = Library.shared
    let items: [LibraryItem]
    let upNext: Set<String>         // paths from Continue Watching: they get the "CONTINUE" kicker
    let onPlay: (String) -> Void
    let onDetails: (LibraryItem) -> Void
    @State private var index = 0
    @State private var hover = false
    @Environment(\.appearsActive) private var active      // false while the window is not key or is minimised

    private func go(_ i: Int) { withAnimation(.easeInOut(duration: 0.8)) { index = (i + items.count) % items.count } }

    var body: some View {
        let i = index % items.count         // the list can shrink under a stale index
        let it = items[i]
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Hero(item: it, kicker: upNext.contains(it.path), onPlay: { onPlay(it.path) }, onDetails: { onDetails(it) })
                    .id(it.path).transition(.opacity)
            }
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { d in
                        Button { go(d) } label: {
                            Capsule().fill(.white.opacity(d == i ? 0.95 : 0.4)).frame(width: d == i ? 22 : 8, height: 8)
                                .contentShape(Rectangle().inset(by: -4))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Item \(d + 1) of \(items.count)")
                    }
                }
                .padding(.trailing, sidePadding).padding(.bottom, 34)
                HStack {
                    chevron("chevron.left") { go(i - 1) }
                    Spacer()
                    chevron("chevron.right") { go(i + 1) }
                }
                .frame(maxHeight: .infinity).padding(.horizontal, 12)
                .opacity(hover ? 1 : 0).animation(.easeInOut(duration: 0.2), value: hover)
            }
        }
        .frame(height: 460)
        .onHover { hover = $0 }
        .onAppear { for f in items where lib.needsThumb(f) { lib.requestThumb(f.path) } }
        // id restarts the wait after every change, so a click on a dot or chevron gets a full 8 s too
        .task(id: [i, items.count, hover || !active ? 1 : 0]) {
            guard items.count > 1, !hover, active else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { go(i + 1) }
        }
    }

    private func chevron(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain).shadow(color: .black.opacity(0.6), radius: 8).disabled(!hover)
    }
}

/// Full-width backdrop fading into the page, with title, facts, summary and Play.
private struct Hero: View {
    @ObservedObject private var lib = Library.shared
    let item: LibraryItem
    let kicker: Bool            // from Continue Watching
    let onPlay: () -> Void
    let onDetails: () -> Void
    @AppStorage("showFilenames") private var showFilenames = false     // re-render when the Library setting flips

    var body: some View {
        let m = lib.meta[item.metaKey]
        ZStack(alignment: .bottomLeading) {
            ZStack {
                if let img = lib.backdrop(for: item) ?? lib.poster(for: item) {
                    Color.clear.overlay(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)).clipped()
                } else {
                    Color(white: 0.15)
                }
                heroScrim
            }
            .backgroundExtensionEffect()        // only the picture runs under the sidebar and toolbar
            VStack(alignment: .leading, spacing: 10) {
                if kicker { Text(item.isEpisode ? "CONTINUE · \(item.episodeLabel)" : "CONTINUE WATCHING").font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary) }
                Text(lib.displayTitle(for: item)).font(.system(size: 44, weight: .heavy)).lineLimit(2).shadow(color: .black.opacity(0.5), radius: 12)
                FactsLine(item: item)
                if let o = m?.overview, !o.isEmpty {
                    Text(o).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: 560, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button(action: onPlay) { Label(playLabel, systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                    Button(action: onDetails) { Label("Details", systemImage: "info.circle") }.buttonStyle(.bordered)
                }
                .controlSize(.large).padding(.top, 8)
            }
            .padding(.horizontal, sidePadding).padding(.bottom, 26)
            .environment(\.colorScheme, .dark)      // the hero is a dark picture in light mode too
        }
        .frame(height: 460)
    }

    private var playLabel: String {
        let p = lib.play[item.path]
        if (p?.position ?? 0) > 0 && p?.watched != true { return "Resume" }
        return item.isEpisode ? "Play \(item.episodeLabel)" : "Play"
    }
}

/// "2024 · 1h 52m  [IMDb] 8.8  [tomato] 87%  [TMDB] 8.4  Drama, Thriller" with the services' logos.
/// IMDb · Rotten Tomatoes · TMDB scores, the ones switched on in Metadata settings.
struct Ratings: View {
    @AppStorage("ratingIMDb") private var showIMDb = true       // Metadata settings: which scores to show
    @AppStorage("ratingRT") private var showRT = true
    @AppStorage("ratingTMDB") private var showTMDB = true
    let meta: LibraryMeta?
    var body: some View {
        let m = meta
        HStack(spacing: 14) {
            if showIMDb, let i = m?.imdbRating { Score(logo: Logo.imdb, name: "IMDb", value: String(format: "%.1f", i), height: 16) }
            if showRT, let rt = m?.rottenTomatoes {                 // Rotten Tomatoes: fresh at 60 % and up
                Score(logo: rt >= 60 ? Logo.fresh : Logo.rotten, name: "Rotten Tomatoes", value: "\(rt)%", height: 16)
            }
            if showTMDB, let v = m?.rating, v > 0 {
                let tvmaze = m?.source == "tvmaze"
                Score(logo: tvmaze ? nil : Logo.tmdb, name: tvmaze ? "TVmaze" : "TMDB", value: String(format: "%.1f", v), height: 9)
            }
        }
    }
}

struct FactsLine: View {
    @ObservedObject private var lib = Library.shared
    let item: LibraryItem
    var badges = false          // detail page: format badges after the year, genres sit on their own line there
    var body: some View {
        let m = lib.meta[item.metaKey]
        let lead = [lib.year(for: item), runtimeText(m?.runtime)].compactMap { $0 }
        HStack(spacing: 14) {
            if !lead.isEmpty { Text(lead.joined(separator: "  ·  ")) }
            if badges, let info = lib.mediaInfo[item.path], info.readable { DetailTags(info: info) }     // a show: its first episode
            if !badges { Ratings(meta: m) }          // the detail page shows them above its genres
            if !badges, let g = m?.genres, !g.isEmpty { Text(g.prefix(3).joined(separator: ", ")) }
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
    }
}

/// A service's logo (or its name when there is none) and its score.
private struct Score: View {
    let logo: NSImage?
    let name: String
    let value: String
    var height: CGFloat = 14     // per logo: the wide TMDB mark reads at a smaller height than the IMDb plate
    var body: some View {
        HStack(spacing: 6) {
            if let logo { Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(height: height).accessibilityLabel(name) }
            else { Text(name) }
            Text(value)
        }
        .help(name)
    }
}

/// A titled row that scrolls sideways. `onMore` turns the title into "Films ›", opening the full page (Apple TV app).
/// Swipes snap to whole tiles; on hover, chevrons at the edges page one screenful at a time (Netflix).
private struct Shelf<Card: View>: View {
    let title: String
    let items: [LibraryItem]
    var onMore: (() -> Void)? = nil
    @ViewBuilder let card: (LibraryItem) -> Card
    @State private var hover = false            // over the title
    @State private var rowHover = false         // over the row: shows the chevrons
    @State private var visible: [Int] = []      // indices of the tiles fully on screen, ascending
    @State private var position = ScrollPosition(idType: String.self)

    /// One page: the first tile past the visible ones (or as many back) lands at the leading edge.
    private func page(_ dir: Int) {
        guard let first = visible.first else { return }
        let target = min(max(0, first + dir * max(1, visible.count)), items.count - 1)
        withAnimation(.smooth(duration: 0.45)) { position.scrollTo(id: items[target].id, anchor: .leading) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let onMore {
                    Button(action: onMore) {
                        HStack(spacing: 6) {
                            Text(title)
                            Image(systemName: "chevron.right").font(.title3.bold()).foregroundStyle(hover ? .primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).onHover { hover = $0 }.help("Show All")
                } else {
                    Text(title)
                }
            }
            .font(.title2.bold())
            .padding(.horizontal, sidePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) { ForEach(items) { card($0) } }
                    .padding(.vertical, 8)      // room for the hover lift
                    .scrollTargetLayout()
            }
            .contentMargins(.horizontal, sidePadding, for: .scrollContent)     // tiles snap to the page margin, not the window edge
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition($position)
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.9) { ids in
                visible = ids.compactMap { id in items.firstIndex { $0.id == id } }.sorted()
            }
            .overlay {
                HStack {
                    chevron("chevron.left", show: (visible.first ?? 0) > 0) { page(-1) }
                    Spacer()
                    chevron("chevron.right", show: (visible.last ?? items.count - 1) < items.count - 1) { page(1) }
                }
                .padding(.horizontal, 4)
                .animation(.easeInOut(duration: 0.2), value: rowHover)
            }
            .onHover { rowHover = $0 }
        }
    }

    private func chevron(_ name: String, show: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 36).glassCircle()
        }
        .buttonStyle(.plain).help(name == "chevron.left" ? "Previous" : "Next")
        .opacity(rowHover && show ? 1 : 0).disabled(!(rowHover && show))
    }
}

/// Poster with a hover lift, progress bar and watched mark. `width` nil = fill the grid cell.
private struct PosterCard: View {
    @ObservedObject private var lib = Library.shared
    let item: LibraryItem
    let width: CGFloat?
    let action: () -> Void
    @State private var hover = false
    @AppStorage("showFilenames") private var showFilenames = false     // re-render when the Library setting flips
    @AppStorage("showWatchedIndicators") private var showWatched = true
    @AppStorage("showPosterTitles") private var showTitles = true

    private var paths: [String] { item.isEpisode ? lib.episodes(of: item).map(\.path) : [item.path] }
    private var watched: Bool { paths.allSatisfy { lib.play[$0]?.watched == true } }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    if let img = lib.poster(for: item) {
                        Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill))
                    } else {
                        placeholder
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay(Text(lib.displayTitle(for: item)).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center).padding(12))
                    }
                    if showWatched, !item.isEpisode, let p = lib.play[item.path], !p.watched, p.duration > 0, p.position > 0 {
                        ProgressStrip(fraction: p.position / p.duration)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if watched && showWatched {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                            .symbolRenderingMode(.palette).foregroundStyle(.black, .white).padding(8)
                    }
                }
                .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 18 : 8, y: hover ? 10 : 4)
                .scaleEffect(hover ? 1.04 : 1)
                if showTitles { VStack(alignment: .leading, spacing: 2) {
                    Text(lib.displayTitle(for: item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(item.isEpisode ? "\(lib.episodes(of: item).count) episodes" : (lib.year(for: item) ?? " "))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)        // tags sit at the poster's right edge
                        TagRow(tags: lib.mediaInfo[item.path]?.cardTags ?? [])      // a show: its first episode
                    }
                } }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
        .onAppear { if lib.needsThumb(item) { lib.requestThumb(item.path) }; lib.requestInfo(item.path) }
        .contextMenu {
            Button(watched ? "Mark as Unwatched" : "Mark as Watched") { lib.setWatched(paths, !watched) }
            if !item.isEpisode { Button("Show in Finder") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") } }
            Menu("Add to Collection") {
                ForEach(lib.userCollections.keys.sorted(), id: \.self) { n in Button(n) { lib.addToCollection(item, n) } }
                Button("New Collection…") { if let n = askCollectionName() { lib.addToCollection(item, n) } }
            }
            ForEach(lib.userCollections.filter { $0.value.contains(item.metaKey) }.keys.sorted(), id: \.self) { n in
                Button("Remove from “\(n)”") { lib.removeFromCollection(item, n) }
            }
        }
    }
}

/// Collections tab: the first item's poster (a placeholder while empty), name and item count.
private struct CollectionTile: View {
    @ObservedObject private var lib = Library.shared
    let name: String
    let items: [LibraryItem]
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let first = items.first, let img = lib.poster(for: first) {
                        Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill))
                    } else {
                        placeholder.aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay(Image(systemName: "rectangle.stack").font(.system(size: 34)).foregroundStyle(.tertiary))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 18 : 8, y: hover ? 10 : 4)
                .scaleEffect(hover ? 1.04 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(items.count == 1 ? "1 item" : "\(items.count) items").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
        .onAppear { if let f = items.first, lib.needsThumb(f) { lib.requestThumb(f.path) } }
    }
}

struct ProgressStrip: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white).frame(width: max(4, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4).padding(.horizontal, 10).padding(.bottom, 10).shadow(color: .black.opacity(0.4), radius: 1)
    }
}

/// Landscape card for Continue Watching: backdrop, title, where you are, progress.
private struct WideCard: View {
    @ObservedObject private var lib = Library.shared
    let item: LibraryItem
    let action: () -> Void
    @State private var hover = false
    @AppStorage("showFilenames") private var showFilenames = false     // re-render when the Library setting flips
    @AppStorage("showWatchedIndicators") private var showWatched = true

    var body: some View {
        let p = lib.play[item.path]
        let started = (p?.position ?? 0) > 0 && p?.watched != true
        let left = started ? Int(((p?.duration ?? 0) - (p?.position ?? 0)) / 60) : 0
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    Group {
                        if let img = lib.backdrop(for: item) ?? lib.poster(for: item) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholder
                        }
                    }
                    .frame(width: 300, height: 169).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    Image(systemName: "play.fill").font(.system(size: 26)).foregroundStyle(.white).padding(18).glassCircle()
                        .opacity(hover ? 1 : 0).frame(maxHeight: .infinity)
                    if started && showWatched { ProgressStrip(fraction: (p?.position ?? 0) / max(p?.duration ?? 1, 1)) }
                }
                .frame(width: 300, height: 169)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 18 : 8, y: hover ? 10 : 4)
                .scaleEffect(hover ? 1.03 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lib.displayTitle(for: item)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(item.isEpisode ? (started ? "\(item.episodeLabel) · \(left) min left" : "Next up · \(item.episodeLabel)")
                                        : (started ? "\(left) min left" : (lib.year(for: item) ?? " ")))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 300, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
        .onAppear { if lib.needsThumb(item) { lib.requestThumb(item.path) } }
        .contextMenu {
            Button("Remove from Continue Watching") { lib.removeFromContinue(item) }
            Button("Mark as Watched") { lib.setWatched([item.path], true) }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") }
        }
    }
}

// MARK: - fix match, collections

private func askCollectionName() -> String? {
    let a = NSAlert()
    a.messageText = "New Collection"
    a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    a.accessoryView = f; a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
}

/// Asks before deleting; a TMDB series is hidden rather than removed (it would form again by itself).
private func confirmDelete(_ name: String, auto: Bool) -> Bool {
    let a = NSAlert()
    a.messageText = "Delete “\(name)”?"
    a.informativeText = auto ? "This series collection was made from TMDB data. It will be hidden; the films stay in the library."
                             : "The films stay in the library."
    a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
    a.buttons.first?.hasDestructiveAction = true
    return a.runModal() == .alertFirstButtonReturn
}

/// Search the active database and pick the right entry by hand.
struct FixMatchSheet: View {
    let item: LibraryItem
    @State var query: String
    @State private var hits: [MatchCandidate] = []
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private func run() {
        busy = true
        Task { hits = await Metadata.candidates(query: query, tv: item.isEpisode); busy = false }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fix Match").font(.title2.bold())
            HStack {
                TextField("Title", text: $query).textFieldStyle(.roundedBorder).onSubmit(run)
                Button("Search", action: run).disabled(query.isEmpty || busy)
            }
            List(hits) { c in
                Button { Library.shared.fixMatch(item, to: c); dismiss() } label: {
                    HStack(spacing: 12) {
                        AsyncImage(url: c.image) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Color.gray.opacity(0.2) }
                            .frame(width: 40, height: 60)
                        VStack(alignment: .leading) { Text(c.title); Text(c.year ?? "").foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .overlay { if busy { ProgressView() } else if hits.isEmpty { Text("No results").foregroundStyle(.secondary) } }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 440, height: 480).onAppear { run() }
    }
}

