import AppKit
import SwiftUI

// Jellyfin pages in the library window: sign-in sheet, film / show grids, episode list.

/// Server address, user name and password. Only the access token is kept (Keychain).
struct JellyfinSheet: View {
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private func signIn() {
        busy = true; error = nil
        Task {
            error = await Jellyfin.shared.signIn(server: server, user: user, password: password)
            busy = false
            if error == nil { dismiss() }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Jellyfin Server").font(.title2.bold())
            TextField("Server (http://192.168.1.10:8096)", text: $server).textFieldStyle(.roundedBorder)
            TextField("User name", text: $user).textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(signIn)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In", action: signIn).keyboardShortcut(.defaultAction).disabled(server.isEmpty || user.isEmpty || busy)
            }
        }
        .padding(20).frame(width: 400)
    }
}

/// Films or shows on the server, in the look of the local grid.
struct JellyfinGrid: View {
    let films: Bool
    let search: String
    let open: (JellyfinItem) -> Void
    @State private var items: [JellyfinItem]?       // nil = loading
    @State private var error: String?

    var body: some View {
        let list = (items ?? []).filter { search.isEmpty || $0.Name.localizedCaseInsensitiveContains(search) }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error { Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80) }
                else if items == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
                else if list.isEmpty { Text("Nothing here yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                    ForEach(list) { it in JellyfinCard(item: it) { open(it) } }
                }
            }
            .padding(.horizontal, sidePadding).padding(.top, 20).padding(.bottom, 40)
        }
        .navigationTitle(films ? "Films" : "Shows")
        .navigationSubtitle(items == nil ? "" : list.count == 1 ? "1 item" : "\(list.count) items")
        .task(id: films) {
            items = nil; error = nil
            do { items = try await Jellyfin.shared.items(films ? "Movie" : "Series") }
            catch { if !Task.isCancelled { self.error = Jellyfin.message(error) } }     // a cancelled load belongs to a view that is gone
        }
    }
}

/// PosterCard's look for a server item (poster loaded from the server on demand).
private struct JellyfinCard: View {
    let item: JellyfinItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                placeholder
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: Jellyfin.shared.posterURL(item.Id)) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
                            Text(item.Name).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center).padding(12)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let p = item.progress, !item.played { ProgressView(value: p).tint(.white).padding(10) }
                    }
                    .overlay(alignment: .topTrailing) {
                        if item.played { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, .tint).padding(8) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(hover ? 0.35 : 0.15), radius: hover ? 18 : 8, y: hover ? 10 : 4)
                    .scaleEffect(hover ? 1.04 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.Name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(item.ProductionYear.map(String.init) ?? " ").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
    }
}

/// A server show: its summary, a season picker and that season's episodes; a click plays one.
struct JellyfinEpisodes: View {
    let series: JellyfinItem
    let onPlay: (String) -> Void
    @State private var episodes: [JellyfinItem]?    // nil = loading
    @State private var error: String?
    @State private var season: Int?

    var body: some View {
        let seasons = Array(Set((episodes ?? []).map { $0.ParentIndexNumber ?? 0 })).sorted()
        let current = season ?? seasons.first
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(series.Name).font(.system(size: 40, weight: .heavy)).lineLimit(2)
                if let o = series.Overview, !o.isEmpty {
                    Text(o).font(.system(size: 15)).lineSpacing(3).frame(maxWidth: 760, alignment: .leading)
                }
                if let error { Text(error).foregroundStyle(.secondary) }
                else if episodes == nil { ProgressView() }
                else if episodes?.isEmpty == true { Text("No episodes.").foregroundStyle(.secondary) }
                if seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { current }, set: { season = $0 })) {
                        ForEach(seasons, id: \.self) { Text(seasonName($0)).tag(Int?.some($0)) }
                    }
                    .pickerStyle(.menu).labelsHidden().fixedSize()
                } else if let s = seasons.first {
                    Text(seasonName(s)).font(.title2.bold())
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach((episodes ?? []).filter { ($0.ParentIndexNumber ?? 0) == current }) { ep in
                        let label = "S\(ep.ParentIndexNumber ?? 0) · E\(ep.IndexNumber ?? 0)"
                        Button {
                            if let u = Jellyfin.shared.streamURL(ep.Id, title: "\(series.Name) \(label) \(ep.Name)") { onPlay(u) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "play.fill").foregroundStyle(.secondary)
                                Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                                Text(ep.Name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if ep.played { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                                else if let p = ep.progress { ProgressView(value: p).frame(width: 60) }
                            }
                            .padding(.vertical, 9).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, sidePadding).padding(.top, 20).padding(.bottom, 40)
        }
        .task {
            do { episodes = try await Jellyfin.shared.episodes(of: series.Id) }
            catch { if !Task.isCancelled { self.error = Jellyfin.message(error) } }     // a cancelled load belongs to a view that is gone
        }
    }

    /// Jellyfin keeps specials in season 0.
    private func seasonName(_ n: Int) -> String { n == 0 ? "Specials" : "Season \(n)" }
}
