import Foundation
import Security

// One Jellyfin server, direct play only. The access token lives in the Keychain; the server
// address, user id and a stable device id in UserDefaults. The password is never stored.
// Playback is reported back (start / progress / stopped / played) so other clients see the
// resume point and watched state. Not done: Quick Connect, several servers, transcoding.

struct JellyfinItem: Decodable, Identifiable, Hashable {
    let Id: String
    let Name: String
    let ProductionYear: Int?
    let Overview: String?
    let IndexNumber: Int?           // episode number
    let ParentIndexNumber: Int?     // season number
    let RunTimeTicks: Int64?        // length, 10 000 000 ticks per second
    let UserData: UD?
    struct UD: Decodable, Hashable { let PlaybackPositionTicks: Int64?; let Played: Bool? }
    var id: String { Id }
    var played: Bool { UserData?.Played == true }
    /// 0...1 of the way through, nil when not started (or no length known).
    var progress: Double? {
        guard let p = UserData?.PlaybackPositionTicks, p > 0, let r = RunTimeTicks, r > 0 else { return nil }
        return min(Double(p) / Double(r), 1)
    }
}

struct JellyfinError: Error { let message: String }

@MainActor
final class Jellyfin: ObservableObject {
    static let shared = Jellyfin()

    /// "https://host:8096" (no trailing slash); nil = not signed in.
    @Published private(set) var server: String?
    private var userId = ""
    private var token = ""

    struct Auth: Decodable { struct U: Decodable { let Id: String }; let User: U; let AccessToken: String }
    struct Items: Decodable { let Items: [JellyfinItem] }
    /// Body of the /Sessions/Playing* reports.
    struct Report: Encodable { let ItemId: String; let PositionTicks: Int64; let IsPaused: Bool; var PlayMethod = "DirectPlay"; var CanSeek = true }

    /// Stream URL handed to the player -> server item id, so playback can be reported back.
    /// Memory only (the URL carries the token).
    private var streams: [String: String] = [:]
    /// Item id -> resume point in seconds, from the last listing.
    private var resume: [String: Double] = [:]

    private init() {
        let d = UserDefaults.standard
        // The Keychain is read only when a server is set, so a fresh install never touches it.
        if let s = d.string(forKey: "jellyfinServer"), let u = d.string(forKey: "jellyfinUser"), let t = Keychain.get() {
            server = s; userId = u; token = t
        }
    }

    private static var deviceId: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: "jellyfinDeviceId") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "jellyfinDeviceId")
        return id
    }

    // MARK: pure helpers (checked offline by selfTestIfAsked)
    nonisolated static func authHeader(deviceId: String, token: String?) -> String {
        "MediaBrowser Client=\"Specular\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"0.1\"" + (token.map { ", Token=\"\($0)\"" } ?? "")
    }
    /// "host:8096/" -> "http://host:8096"; nil when there is no host.
    nonisolated static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)?.host?.isEmpty == false ? s : nil
    }
    /// Direct-play URL. The trailing `title` parameter is ignored by the server; it is there so
    /// the player, which names a stream by the text after the last "/", shows the title and not
    /// the token. Every non-alphanumeric is percent-encoded so a "." is not read as an extension.
    nonisolated static func streamURL(server: String, id: String, token: String, title: String) -> String {
        let t = title.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "\(server)/Videos/\(id)/stream?static=true&api_key=\(token)&title=/\(t)"
    }
    nonisolated static func message(_ error: Error) -> String {
        if let e = error as? JellyfinError { return e.message }
        if error is DecodingError { return "Unreadable reply. Is this a Jellyfin server?" }
        return error.localizedDescription
    }

    private nonisolated static func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data         // the report endpoints answer 204
        case 401, 403: throw JellyfinError(message: "The server refused the sign-in.")
        case let code: throw JellyfinError(message: "Unexpected reply (\(code)).")
        }
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String], as: T.Type) async throws -> T {
        guard let server, var c = URLComponents(string: server + path) else { throw JellyfinError(message: "Not signed in.") }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw JellyfinError(message: "Bad request.") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Jellyfin.authHeader(deviceId: Jellyfin.deviceId, token: token), forHTTPHeaderField: "Authorization")
        return try JSONDecoder().decode(T.self, from: try await Jellyfin.send(req))
    }

    /// POST with an optional JSON body; the reply is ignored.
    private func post(_ path: String, _ body: (any Encodable)?) async throws {
        guard let server, let url = URL(string: server + path) else { throw JellyfinError(message: "Not signed in.") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(Jellyfin.authHeader(deviceId: Jellyfin.deviceId, token: token), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        _ = try await Jellyfin.send(req)
    }

    // MARK: sign in / out
    /// Returns nil on success, else a short message for the sheet.
    func signIn(server raw: String, user: String, password: String) async -> String? {
        guard let base = Jellyfin.normalize(raw), let url = URL(string: base + "/Users/AuthenticateByName") else {
            return "That server address is not valid."
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Jellyfin.authHeader(deviceId: Jellyfin.deviceId, token: nil), forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(["Username": user, "Pw": password])
        do {
            let auth = try JSONDecoder().decode(Auth.self, from: try await Jellyfin.send(req))
            guard Keychain.set(auth.AccessToken) else { return "Could not save the sign-in in the Keychain." }
            UserDefaults.standard.set(base, forKey: "jellyfinServer")
            UserDefaults.standard.set(auth.User.Id, forKey: "jellyfinUser")
            userId = auth.User.Id; token = auth.AccessToken; server = base
            return nil
        } catch let e as JellyfinError where e.message.hasPrefix("The server refused") {
            return "Wrong user name or password."
        } catch { return Jellyfin.message(error) }
    }

    /// Forgets the server on this Mac. shortcut: the token is not revoked on the server
    /// (POST /Sessions/Logout); add that if a stale session in the dashboard matters.
    func signOut() {
        _ = Keychain.set(nil)
        UserDefaults.standard.removeObject(forKey: "jellyfinServer")
        UserDefaults.standard.removeObject(forKey: "jellyfinUser")
        server = nil; userId = ""; token = ""; streams = [:]; resume = [:]
    }

    // MARK: browse and play
    /// `type` is "Movie" or "Series". shortcut: one request, no paging; page with StartIndex /
    /// Limit if a library of many thousands of titles loads slowly.
    func items(_ type: String) async throws -> [JellyfinItem] {
        remember(try await get("/Users/\(userId)/Items", ["IncludeItemTypes": type, "Recursive": "true", "Fields": "Overview,ProductionYear",
                                                          "SortBy": "SortName", "EnableUserData": "true"], as: Items.self).Items)
    }
    func episodes(of seriesId: String) async throws -> [JellyfinItem] {
        remember(try await get("/Shows/\(seriesId)/Episodes", ["userId": userId, "EnableUserData": "true"], as: Items.self).Items)
    }
    private func remember(_ items: [JellyfinItem]) -> [JellyfinItem] {
        for it in items { resume[it.Id] = it.UserData?.PlaybackPositionTicks.map { Double($0) / 1e7 } }
        return items
    }
    func posterURL(_ id: String) -> URL? { server.flatMap { URL(string: "\($0)/Items/\(id)/Images/Primary?maxWidth=400") } }
    func streamURL(_ id: String, title: String) -> String? {
        guard let server else { return nil }
        let u = Jellyfin.streamURL(server: server, id: id, token: token, title: title)
        streams[u] = id
        return u
    }

    // MARK: playback reports (call on the main actor; each is fire-and-forget)
    // `url` is the stream string the player was given; anything that is not a Jellyfin stream
    // is ignored, so the player can call these for every file. `position` is in seconds.
    // A failed report is dropped silently: it must never interrupt playback.

    /// Server item id behind a stream URL, nil for a local file.
    func itemID(forStream url: String) -> String? { streams[url] }
    /// Where the server says to resume (seconds), nil when not started or a local file.
    func resumePosition(forStream url: String) -> Double? { streams[url].flatMap { resume[$0] }.flatMap { $0 > 0 ? $0 : nil } }

    func reportStart(url: String, position: Double) { report("/Sessions/Playing", url, position, paused: false) }
    /// Every ~10 s while playing, and on pause / resume.
    func reportProgress(url: String, position: Double, paused: Bool) { report("/Sessions/Playing/Progress", url, position, paused: paused) }
    /// On close / switching file / end. `finished` = played to the end: also marks it watched.
    func reportStopped(url: String, position: Double, finished: Bool) {
        guard let id = streams[url] else { return }
        report("/Sessions/Playing/Stopped", url, position, paused: false)
        resume[id] = finished ? nil : position
        if finished { Task { try? await post("/Users/\(userId)/PlayedItems/\(id)", nil) } }
    }
    private func report(_ path: String, _ url: String, _ position: Double, paused: Bool) {
        guard let id = streams[url] else { return }
        let body = Report(ItemId: id, PositionTicks: Jellyfin.ticks(position), IsPaused: paused)
        Task { try? await post(path, body) }
    }
    nonisolated static func ticks(_ seconds: Double) -> Int64 { seconds.isFinite && seconds > 0 ? Int64(seconds * 1e7) : 0 }

    // MARK: offline self-check
    /// PLAYER_JELLYTEST=1: decode canned replies and build the URLs (no server, no Keychain),
    /// print JELLYTEST PASS / FAIL lines, quit. Called from showLibrary().
    static func selfTestIfAsked() {
        guard ProcessInfo.processInfo.environment["PLAYER_JELLYTEST"] != nil else { return }
        func check(_ name: String, _ ok: Bool) { print("JELLYTEST \(ok ? "PASS" : "FAIL") \(name)") }
        let authJSON = #"{"User":{"Name":"sam","Id":"u1","HasPassword":true},"SessionInfo":{"Id":"s"},"AccessToken":"tok123","ServerId":"srv"}"#
        let itemsJSON = #"""
        {"Items":[{"Name":"Mr. Robot","Id":"abc","ProductionYear":2015,"Overview":"A hacker.","Type":"Series"},
                  {"Name":"Pilot","Id":"e1","IndexNumber":1,"ParentIndexNumber":1,"Type":"Episode","RunTimeTicks":36000000000,
                   "UserData":{"PlaybackPositionTicks":9000000000,"PlayCount":0,"IsFavorite":false,"Played":false,"Key":"k"}}],
         "TotalRecordCount":2,"StartIndex":0}
        """#
        let auth = try? JSONDecoder().decode(Auth.self, from: Data(authJSON.utf8))
        check("auth reply", auth?.AccessToken == "tok123" && auth?.User.Id == "u1")
        let items = (try? JSONDecoder().decode(Items.self, from: Data(itemsJSON.utf8)))?.Items ?? []
        check("items reply", items.count == 2 && items[0].Name == "Mr. Robot" && items[0].ProductionYear == 2015
              && items[1].ProductionYear == nil && items[1].IndexNumber == 1 && items[1].ParentIndexNumber == 1)
        check("user data", items.count == 2 && items[0].progress == nil && !items[0].played
              && items[1].progress == 0.25 && items[1].UserData?.PlaybackPositionTicks == 9_000_000_000)
        let body = (try? JSONEncoder().encode(Report(ItemId: "e1", PositionTicks: ticks(90.5), IsPaused: true)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check("playback report", body["ItemId"] as? String == "e1" && body["PositionTicks"] as? Int64 == 905_000_000
              && body["IsPaused"] as? Bool == true && body["PlayMethod"] as? String == "DirectPlay" && ticks(.nan) == 0 && ticks(-3) == 0)
        check("not JSON is an error, not a crash", (try? JSONDecoder().decode(Items.self, from: Data("<html>".utf8))) == nil)
        check("server address", normalize(" jelly.local:8096/ ") == "http://jelly.local:8096"
              && normalize("https://media.example/jellyfin") == "https://media.example/jellyfin" && normalize("") == nil)
        check("auth header", authHeader(deviceId: "D", token: nil) == #"MediaBrowser Client="Specular", Device="Mac", DeviceId="D", Version="0.1""#
              && authHeader(deviceId: "D", token: "t").hasSuffix(#", Token="t""#))
        let u = streamURL(server: "http://jelly.local:8096", id: "abc", token: "tok123", title: "Mr. Robot (2015)")
        check("stream URL", u == "http://jelly.local:8096/Videos/abc/stream?static=true&api_key=tok123&title=/Mr%2E%20Robot%20%282015%29"
              && URL(string: u) != nil)
        let shown = cleanTitle(u)
        check("player shows the title, not the token", shown.0 == "Mr. Robot" && shown.1 == "2015")
        exit(0)
    }
}

/// The access token, as one generic-password item.
private enum Keychain {
    private static var item: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "Specular.Jellyfin", kSecAttrAccount: "token"]
    }
    /// nil removes it.
    static func set(_ token: String?) -> Bool {
        SecItemDelete(item as CFDictionary)
        guard let token else { return true }
        return SecItemAdd(item.merging([kSecValueData: Data(token.utf8)]) { a, _ in a } as CFDictionary, nil) == errSecSuccess
    }
    static func get() -> String? {
        var out: AnyObject?
        guard SecItemCopyMatching(item.merging([kSecReturnData: true]) { a, _ in a } as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
