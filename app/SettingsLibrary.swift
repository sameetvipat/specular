import AppKit
import SwiftUI

// Settings tabs for the library (settings-v2 step 3; toolbar tabs in ui-round-3). Rows in the settings
// window's two-column form. Library and LibraryView read the same keys; defaults keep the old behaviour.

struct LibrarySettingsSection: View {
    @AppStorage("showFilenames") private var showFilenames = false
    @AppStorage("showPosterTitles") private var showPosterTitles = true
    @AppStorage("showWatchedIndicators") private var showWatched = true
    @AppStorage("showUpNext") private var showUpNext = true
    @AppStorage("hideSpoilers") private var hideSpoilers = false
    @AppStorage("tmdbCollections") private var tmdbCollections = true
    @AppStorage("customCollections") private var customCollections = true

    @ObservedObject private var library = Library.shared

    var body: some View {
        settingsRow("Folders") {
            ForEach(library.folders, id: \.self) { f in
                HStack {
                    Label((f as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    Button("Remove") { library.removeFolder(f) }
                }
            }
            Button("Add Folder…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
                if p.runModal() == .OK { for u in p.urls { library.addFolder(u.path) } }
            }
        }
        settingsDivider()
        settingsRow("Display") {
            Toggle("Show filenames", isOn: $showFilenames)
            Toggle("Show poster titles", isOn: $showPosterTitles)
            Toggle("Watched indicators", isOn: $showWatched)
            Toggle("Up Next (Continue Watching)", isOn: $showUpNext)
            Toggle("Hide spoilers", isOn: $hideSpoilers)
        }
        settingsNote("Hide spoilers blurs the pictures and hides the summaries of episodes you have not watched.")
        settingsDivider()
        settingsRow("Collections") {
            Toggle("TMDB collections", isOn: $tmdbCollections)
            Toggle("Custom collections", isOn: $customCollections)
        }
    }
}

struct MetadataSettingsSection: View {
    @AppStorage("preferEmbeddedArtwork") private var preferEmbedded = false
    @AppStorage("preferLocalArtwork") private var preferLocalArt = true
    @AppStorage("preferLocalMetadata") private var preferLocalMeta = true
    @AppStorage("ratingIMDb") private var ratingIMDb = true
    @AppStorage("ratingRT") private var ratingRT = true
    @AppStorage("ratingTMDB") private var ratingTMDB = true
    @ObservedObject private var lib = Library.shared
    @State private var cacheBytes: Int64 = 0

    var body: some View {
        settingsRow("Artwork & details") {
            Toggle("Prefer embedded artwork", isOn: $preferEmbedded)
            Toggle("Prefer local artwork", isOn: $preferLocalArt)
            Toggle("Prefer local metadata (.nfo)", isOn: $preferLocalMeta)
        }
        settingsNote("Embedded artwork is the cover inside an MKV or MP4 file. Local files sit next to the video "
                     + "(poster.jpg, movie.nfo). Turned off, online details replace them where they exist.")
        settingsDivider()
        settingsRow("Rating sources") {
            Toggle("IMDb", isOn: $ratingIMDb)
            Toggle("Rotten Tomatoes", isOn: $ratingRT)
            Toggle("TMDB", isOn: $ratingTMDB)
        }
        settingsDivider()
        settingsRow("Metadata") { Text(TMDB.key.isEmpty ? "TVmaze, Wikipedia" : "TMDB") }
        settingsRow("Library cache") {
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                Button("Clear") { lib.clearImageCache(); cacheBytes = 0 }
            }
            // Local values are merged in during a scan; turning a preference off needs the online values fetched again.
            .onChange(of: preferLocalArt) { _, on in on ? lib.rescan() : lib.refetchOnline() }
            .onChange(of: preferLocalMeta) { _, on in on ? lib.rescan() : lib.refetchOnline() }
            .onAppear { cacheBytes = cacheSize() }
        }
        settingsNote("Covers and details are fetched automatically. "
                     + "Only the title, year or a database id is sent, never file names. "
                     + "This product uses the TMDB API but is not endorsed or certified by TMDB. "
                     + "Show data by TVmaze.com; film text from Wikipedia (CC BY-SA).")
    }

    /// Bytes in the image cache (posters, backdrops, frame grabs, embedded covers).
    private func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: lib.imageDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
