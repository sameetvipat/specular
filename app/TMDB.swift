import Foundation

// Metadata, the way media servers such as Jellyfin gather it:
//   1. what is next to the file: an id tag in the name ([tmdbid-603]), an .nfo file, local
//      artwork (poster.jpg, fanart.jpg);
//   2. online. With no setup: TVmaze for shows (episodes, cast) and Wikipedia + Wikidata for
//      films (poster, summary, genres, cast, series). With the built-in TMDB key
//      (app/TMDBKey.swift): TMDB for both, which adds backdrops, cast photos for films and taglines.
// Only a cleaned title, a year or a database id is sent, never a file name or path.

struct CastMember: Codable, Hashable {
    var name: String
    var role: String
    var photo: String?          // TMDB image path ("/abc.jpg") or a full URL, loaded on demand
}
struct EpisodeMeta: Codable {
    var title: String
    var overview: String
    var still: String?          // TMDB image path or a full URL, loaded on demand
    var runtime: Int?           // minutes
}
struct SeasonMeta: Codable {
    var episodes: [Int: EpisodeMeta]
}

/// What the files themselves say, before any network lookup.
struct LocalInfo {
    var tmdbID: Int?
    var title: String?
    var year: String?
    var plot: String?
    var poster: String?         // absolute path
    var backdrop: String?       // absolute path

    /// `folder` is the film's own folder or the show's folder; `base` the file name without
    /// extension (films only). Folder-wide artwork is used only when `ownFolder` is true.
    static func read(path: String, folder: String, base: String?, ownFolder: Bool, tv: Bool) -> LocalInfo {
        var info = LocalInfo()
        let fm = FileManager.default
        func first(_ names: [String]) -> String? {
            for n in names { let p = folder + "/" + n; if fm.fileExists(atPath: p) { return p } }
            return nil
        }
        let exts = ["jpg", "jpeg", "png", "webp"]
        var posters: [String] = [], backdrops: [String] = [], nfos: [String] = []
        if let base {
            posters += exts.map { "\(base)-poster.\($0)" }; backdrops += exts.flatMap { ["\(base)-fanart.\($0)", "\(base)-backdrop.\($0)"] }
            nfos.append("\(base).nfo")
        }
        if ownFolder {
            posters += exts.flatMap { ["poster.\($0)", "folder.\($0)", "cover.\($0)"] }
            backdrops += exts.flatMap { ["fanart.\($0)", "backdrop.\($0)"] }
            nfos.append(tv ? "tvshow.nfo" : "movie.nfo")
        }
        info.poster = first(posters); info.backdrop = first(backdrops)

        // "[tmdbid-603]", "{tmdb-603}", "tmdbid=603" in the file or folder name
        let hint = path as NSString
        if let re = try? NSRegularExpression(pattern: #"(?i)[\[{(]tmdb(?:id)?[-=](\d+)[\]})]"#),
           let m = re.firstMatch(in: path, range: NSRange(location: 0, length: hint.length)) {
            info.tmdbID = Int(hint.substring(with: m.range(at: 1)))
        }
        if let nfo = first(nfos), let text = try? String(contentsOfFile: nfo, encoding: .utf8) {
            func tag(_ name: String) -> String? {
                guard let r = text.range(of: "<\(name)[^>]*>([^<]*)</\(name)>", options: .regularExpression) else { return nil }
                let inner = text[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let t = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            info.title = tag("title"); info.plot = tag("plot"); info.year = tag("year")
            // Some tools write the folder name as the title ("(2017) Blade Runner 2049 [1080p]") and a year parsed
            // from it ("2049"): such a title and year are not metadata, so the file name and online data decide.
            if let t = info.title, t.range(of: #"[\[\]{}]|^\s*\((19|20)\d{2}\)"#, options: .regularExpression) != nil {
                info.title = nil; info.year = nil
            }
            if info.tmdbID == nil {
                if let id = tag("tmdbid") { info.tmdbID = Int(id) }
                else if let r = text.range(of: #"<uniqueid[^>]*type="tmdb"[^>]*>(\d+)</uniqueid>"#, options: .regularExpression) {
                    info.tmdbID = Int(text[r].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                }
            }
        }
        return info
    }
}

enum TMDB {
    /// Built into the app (app/TMDBKey.swift, gitignored): a v3 API key, or a v4 read-access token (the long one).
    static let key = builtInTMDBKey.trimmingCharacters(in: .whitespacesAndNewlines)
    static func imageURL(_ path: String, width: Int) -> URL? {
        path.hasPrefix("http") ? URL(string: path) : URL(string: "https://image.tmdb.org/t/p/w\(width)\(path)")
    }

    enum Result { case found(LibraryMeta), notFound, failed(String) }
    private enum Fetch<T> { case ok(T), missing, failed(String) }

    private struct Search: Decodable {
        struct Hit: Decodable {
            let id: Int
            let title: String?; let name: String?
            let release_date: String?; let first_air_date: String?
            let poster_path: String?
        }
        let results: [Hit]
    }
    private struct Collection: Decodable { let name: String }
    private struct Details: Decodable {
        struct Genre: Decodable { let name: String }
        struct Credits: Decodable { struct Person: Decodable { let name: String; let character: String?; let profile_path: String? }; let cast: [Person] }
        let id: Int
        let title: String?; let name: String?
        let overview: String?; let tagline: String?
        let poster_path: String?; let backdrop_path: String?
        let release_date: String?; let first_air_date: String?
        let runtime: Int?; let episode_run_time: [Int]?
        let vote_average: Double?
        let genres: [Genre]?
        let credits: Credits?
        let belongs_to_collection: Collection?
        struct External: Decodable { let imdb_id: String? }
        let imdb_id: String?            // films
        let external_ids: External?     // shows
    }
    private struct Season: Decodable {
        struct Episode: Decodable { let episode_number: Int; let name: String?; let overview: String?; let still_path: String?; let runtime: Int? }
        let episodes: [Episode]
    }

    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], as: T.Type) async -> Fetch<T> {
        let k = key
        var c = URLComponents(string: "https://api.themoviedb.org/3/" + path)
        // The Language setting's metadata choice wins; "auto" follows the system.
        let pick = UserDefaults.standard.string(forKey: "metadataLanguage") ?? "auto"
        let lang = pick != "auto" && !pick.isEmpty ? pick : Locale.preferredLanguages.first ?? "en-US"
        c?.queryItems = query + [URLQueryItem(name: "language", value: lang)] + (k.count > 40 ? [] : [URLQueryItem(name: "api_key", value: k)])
        guard let url = c?.url else { return .failed("bad request") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        if k.count > 40 { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { return .failed(error.localizedDescription) }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: return .failed("the API key was refused")
        case 404: return .missing
        case 429: return .failed("too many requests, try Rescan later")
        case let code: return .failed("unexpected reply (\(code))")
        }
        guard let v = try? JSONDecoder().decode(T.self, from: data) else { return .failed("unreadable reply") }
        return .ok(v)
    }

    /// Download an image into the cache folder once; returns its file name.
    static func store(_ tmdbPath: String?, width: Int, as name: String, in dir: URL) async -> String? {
        guard let p = tmdbPath, let url = imageURL(p, width: width) else { return nil }
        let dest = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return name }
        guard let (img, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200,
              (try? img.write(to: dest, options: .atomic)) != nil else { return nil }
        return name
    }

    /// Identify (id hint, else search by title and year), then fetch details, cast, artwork and
    /// — for a show — the episodes of the seasons that are in the library.
    static func lookup(title: String, year: String?, tv: Bool, knownID: Int?, seasons: [Int], imageDir: URL) async -> Result {
        let kind = tv ? "tv" : "movie"
        var id = knownID
        // "Kotonoha no Niwa - The Garden of Words": the whole name, then each half.
        let names = [title] + (title.contains(" - ") ? title.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) } : [])
        for name in names where id == nil && !name.isEmpty {
            var q = [URLQueryItem(name: "query", value: name), URLQueryItem(name: "include_adult", value: "false")]
            if let year { q.append(URLQueryItem(name: tv ? "first_air_date_year" : "year", value: year)) }
            switch await get("search/\(kind)", q, as: Search.self) {
            case .ok(let s): id = s.results.first?.id
            case .missing: break
            case .failed(let why): return .failed(why)
            }
            if id == nil, year != nil {                 // the year in the file name can be off by one
                let q2 = [URLQueryItem(name: "query", value: name), URLQueryItem(name: "include_adult", value: "false")]
                if case .ok(let s) = await get("search/\(kind)", q2, as: Search.self) { id = s.results.first?.id }
            }
        }
        guard let id else { return .notFound }

        let d: Details
        switch await get("\(kind)/\(id)", [URLQueryItem(name: "append_to_response", value: "credits,external_ids")], as: Details.self) {
        case .ok(let v): d = v
        case .missing: return .notFound
        case .failed(let why): return .failed(why)
        }
        let date = (tv ? d.first_air_date : d.release_date) ?? ""
        var m = LibraryMeta(tmdbID: d.id, title: (tv ? d.name : d.title) ?? title, overview: d.overview ?? "",
                            poster: nil, year: date.count >= 4 ? String(date.prefix(4)) : year)
        m.poster = await store(d.poster_path, width: 500, as: "\(kind)-\(d.id).jpg", in: imageDir)
        m.backdrop = await store(d.backdrop_path, width: 1280, as: "\(kind)-\(d.id)-backdrop.jpg", in: imageDir)
        m.tagline = d.tagline
        m.genres = d.genres?.map(\.name)
        m.runtime = tv ? d.episode_run_time?.first : d.runtime
        m.rating = d.vote_average
        m.cast = d.credits?.cast.prefix(12).map { CastMember(name: $0.name, role: $0.character ?? "", photo: $0.profile_path) }
        m.collection = d.belongs_to_collection?.name
        m.imdbID = [d.imdb_id, d.external_ids?.imdb_id].compactMap { $0 }.first { !$0.isEmpty }
        if let i = m.imdbID { (m.imdbRating, m.rottenTomatoes) = await OMDb.ratings(imdbID: i); m.ratingsChecked = Date() }
        m.source = "tmdb"
        if tv {
            var all: [Int: SeasonMeta] = [:]
            for s in seasons {
                guard case .ok(let season) = await get("tv/\(id)/season/\(s)", as: Season.self) else { continue }
                var eps: [Int: EpisodeMeta] = [:]
                for e in season.episodes {
                    eps[e.episode_number] = EpisodeMeta(title: e.name ?? "", overview: e.overview ?? "", still: e.still_path, runtime: e.runtime)
                }
                all[s] = SeasonMeta(episodes: eps)
            }
            m.seasons = all
        }
        m.detailed = true
        return .found(m)
    }

    /// Possible matches for "Fix Match".
    static func candidates(query: String, tv: Bool) async -> [MatchCandidate] {
        let q = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "include_adult", value: "false")]
        guard case .ok(let s) = await get("search/\(tv ? "tv" : "movie")", q, as: Search.self) else { return [] }
        return s.results.prefix(12).map { h in
            let date = (tv ? h.first_air_date : h.release_date) ?? ""
            return MatchCandidate(source: "tmdb", id: h.id, title: (tv ? h.name : h.title) ?? "?",
                                  year: date.count >= 4 ? String(date.prefix(4)) : nil,
                                  image: h.poster_path.flatMap { imageURL($0, width: 185) })
        }
    }
}

/// One search result the user can pick in "Fix Match".
struct MatchCandidate: Identifiable, Hashable {
    let source: String          // "tmdb", "tvmaze", "wiki"
    let id: Int
    let title: String
    let year: String?
    let image: URL?
}
/// A match chosen by hand; wins over searching by title.
struct MatchOverride: Codable { var source: String; var id: Int }

private func plainText(_ html: String?) -> String {       // TVmaze summaries are small HTML snippets
    guard let html else { return "" }
    return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func fetchJSON<T: Decodable>(_ url: URL?, as: T.Type) async -> T? {
    guard let url, let (data, r) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15)),
          (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

/// OMDb (omdbapi.com, built-in key): IMDb rating and Rotten Tomatoes score by IMDb id.
/// Optional extras: any failure just leaves them out.
enum OMDb {
    static let key = builtInOMDbKey.trimmingCharacters(in: .whitespacesAndNewlines)
    private struct Reply: Decodable {
        struct Rating: Decodable { let Source: String; let Value: String }
        let Response: String; let imdbRating: String?; let Ratings: [Rating]?
    }
    static func ratings(imdbID: String) async -> (imdb: Double?, rt: Int?) {
        guard !key.isEmpty, var c = URLComponents(string: "https://www.omdbapi.com/") else { return (nil, nil) }
        c.queryItems = [URLQueryItem(name: "i", value: imdbID), URLQueryItem(name: "apikey", value: key)]
        guard let r = await fetchJSON(c.url, as: Reply.self), r.Response == "True" else { return (nil, nil) }
        let rt = r.Ratings?.first { $0.Source == "Rotten Tomatoes" }.flatMap { Int($0.Value.replacingOccurrences(of: "%", with: "")) }
        return (r.imdbRating.flatMap(Double.init), rt)       // "N/A" -> nil
    }
}

/// TVmaze (tvmaze.com, no key needed): shows with episodes and cast. Data is CC BY-SA.
enum TVmaze {
    private struct Img: Decodable { let medium: String?; let original: String? }
    private struct Show: Decodable {
        struct Rating: Decodable { let average: Double? }
        struct Episode: Decodable { let season: Int; let number: Int?; let name: String?; let summary: String?; let runtime: Int?; let image: Img? }
        struct Role: Decodable { struct Person: Decodable { let name: String; let image: Img? }; struct Char: Decodable { let name: String? }
                                 let person: Person; let character: Char? }
        struct Embedded: Decodable { let episodes: [Episode]?; let cast: [Role]? }
        let id: Int; let name: String
        let premiered: String?; let summary: String?
        let genres: [String]?; let averageRuntime: Int?; let rating: Rating?
        let image: Img?
        let _embedded: Embedded?
    }
    private struct Hit: Decodable { let show: Show }

    private static func url(_ path: String, _ q: [URLQueryItem]) -> URL? {
        var c = URLComponents(string: "https://api.tvmaze.com/" + path)
        c?.queryItems = q
        return c?.url
    }

    static func lookup(title: String, knownID: Int?, imageDir: URL) async -> TMDB.Result {
        let embed = [URLQueryItem(name: "embed[]", value: "episodes"), URLQueryItem(name: "embed[]", value: "cast")]
        let u = knownID.map { url("shows/\($0)", embed) } ?? url("singlesearch/shows", [URLQueryItem(name: "q", value: title)] + embed)
        guard let s = await fetchJSON(u, as: Show.self) else { return .notFound }
        var m = LibraryMeta(tmdbID: s.id, title: s.name, overview: plainText(s.summary), poster: nil,
                            year: s.premiered.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil })
        m.poster = await TMDB.store(s.image?.original ?? s.image?.medium, width: 0, as: "tvmaze-\(s.id).jpg", in: imageDir)
        m.genres = s.genres; m.runtime = s.averageRuntime; m.rating = s.rating?.average
        m.cast = s._embedded?.cast?.prefix(12).map { CastMember(name: $0.person.name, role: $0.character?.name ?? "", photo: $0.person.image?.medium) }
        var seasons: [Int: SeasonMeta] = [:]
        for e in s._embedded?.episodes ?? [] {
            guard let n = e.number else { continue }            // specials have no number
            seasons[e.season, default: SeasonMeta(episodes: [:])].episodes[n] =
                EpisodeMeta(title: e.name ?? "", overview: plainText(e.summary), still: e.image?.medium, runtime: e.runtime)
        }
        m.seasons = seasons
        m.source = "tvmaze"; m.detailed = true
        return .found(m)
    }

    static func candidates(query: String) async -> [MatchCandidate] {
        guard let hits = await fetchJSON(url("search/shows", [URLQueryItem(name: "q", value: query)]), as: [Hit].self) else { return [] }
        return hits.prefix(12).map { h in
            MatchCandidate(source: "tvmaze", id: h.show.id, title: h.show.name,
                           year: h.show.premiered.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil },
                           image: h.show.image?.medium.flatMap { URL(string: $0) })
        }
    }
}

/// Wikipedia + Wikidata (no key needed): film poster, summary, year, genres, cast, runtime, series.
/// Text and data are CC BY-SA / CC0; posters are the article's lead image.
enum Wiki {
    private struct Query: Decodable {
        struct Pages: Decodable { let pages: [String: Page]? }
        let query: Pages?
    }
    private struct Page: Decodable {
        struct Thumb: Decodable { let source: String }
        struct Props: Decodable { let wikibase_item: String? }
        let pageid: Int; let index: Int?; let title: String
        let description: String?; let extract: String?
        let thumbnail: Thumb?; let pageprops: Props?
        var isFilm: Bool { let d = (description ?? "").lowercased(); return d.contains("film") || d.contains("movie") }
        var year: String? { description.flatMap { d in d.range(of: #"(19|20)\d{2}"#, options: .regularExpression).map { String(d[$0]) } } }
        var cleanTitle: String { title.replacingOccurrences(of: #"\s*\([^)]*film[^)]*\)$"#, with: "", options: .regularExpression) }
    }
    private struct Entities: Decodable {
        struct Entity: Decodable {
            struct Claim: Decodable {
                struct Snak: Decodable { struct Value: Decodable { let value: V? }; let datavalue: Value? }
                let mainsnak: Snak
            }
            struct Label: Decodable { let value: String }
            let claims: [String: [Claim]]?
            let labels: [String: Label]?
        }
        let entities: [String: Entity]
    }
    /// A Wikidata value: an item id, or a quantity / time string.
    private struct V: Decodable {
        var id: String?; var amount: String?; var time: String?
        private enum K: String, CodingKey { case id, amount, time }
        init(from d: Decoder) throws {
            guard let c = try? d.container(keyedBy: K.self) else { return }     // plain strings etc.: ignore
            id = try? c.decode(String.self, forKey: .id)
            amount = try? c.decode(String.self, forKey: .amount)
            time = try? c.decode(String.self, forKey: .time)
        }
    }

    private static func get<T: Decodable>(_ host: String, _ q: [String: String], as: T.Type) async -> T? {
        var c = URLComponents(string: "https://\(host)/w/api.php")
        c?.queryItems = (q.merging(["format": "json"]) { a, _ in a }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Specular/0.1 (macOS video player; library metadata)", forHTTPHeaderField: "User-Agent")   // Wikimedia asks for one
        guard let (data, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let pageProps = ["action": "query", "prop": "pageimages|extracts|pageprops|description", "exintro": "1", "explaintext": "1",
                                    "exsentences": "4", "piprop": "thumbnail", "pithumbsize": "500", "pilicense": "any", "ppprop": "wikibase_item"]

    private static func search(_ text: String) async -> [Page] {
        let q = pageProps.merging(["generator": "search", "gsrsearch": text, "gsrlimit": "8"]) { a, _ in a }
        let pages = (await get("en.wikipedia.org", q, as: Query.self))?.query?.pages ?? [:]
        return pages.values.filter(\.isFilm).sorted { ($0.index ?? 99) < ($1.index ?? 99) }
    }

    static func lookup(title: String, year: String?, knownID: Int?, imageDir: URL) async -> TMDB.Result {
        var page: Page?
        if let id = knownID {
            page = (await get("en.wikipedia.org", pageProps.merging(["pageids": String(id)]) { a, _ in a }, as: Query.self))?.query?.pages?.values.first
        } else {
            let hits = await search("\(title) \(year ?? "") film")
            // Take a result only if its name really is this title, preferring the right year.
            func same(_ p: Page) -> Bool { p.cleanTitle.localizedCaseInsensitiveCompare(title) == .orderedSame }
            page = hits.first { same($0) && year != nil && $0.year == year } ?? hits.first(where: same)
        }
        guard let p = page else { return .notFound }
        var m = LibraryMeta(tmdbID: p.pageid, title: p.cleanTitle, overview: p.extract ?? "", poster: nil, year: p.year ?? year)
        m.poster = await TMDB.store(p.thumbnail?.source, width: 0, as: "wiki-\(p.pageid).jpg", in: imageDir)
        if let qid = p.pageprops?.wikibase_item,
           let e = (await get("www.wikidata.org", ["action": "wbgetentities", "ids": qid, "props": "claims"], as: Entities.self))?.entities[qid] {
            func ids(_ prop: String, _ n: Int) -> [String] { Array((e.claims?[prop] ?? []).compactMap { $0.mainsnak.datavalue?.value?.id }.prefix(n)) }
            let genres = ids("P136", 4), cast = ids("P161", 10), series = ids("P179", 1)
            if let mins = e.claims?["P2047"]?.first?.mainsnak.datavalue?.value?.amount { m.runtime = Int(Double(mins) ?? 0) }
            let wanted = genres + cast + series
            if !wanted.isEmpty,
               let names = (await get("www.wikidata.org", ["action": "wbgetentities", "ids": wanted.joined(separator: "|"), "props": "labels", "languages": "en"],
                                      as: Entities.self))?.entities {
                func label(_ id: String) -> String? { names[id]?.labels?["en"]?.value }
                m.genres = genres.compactMap(label).map { g in                 // "science fiction film" -> "Science Fiction"
                    g.replacingOccurrences(of: #"\s+(film|movie)$"#, with: "", options: .regularExpression).capitalized
                }
                m.cast = cast.compactMap(label).map { CastMember(name: $0, role: "", photo: nil) }
                m.collection = series.first.flatMap(label)
            }
        }
        m.source = "wiki"; m.detailed = true
        return .found(m)
    }

    static func candidates(query: String) async -> [MatchCandidate] {
        await search(query + " film").map {
            MatchCandidate(source: "wiki", id: $0.pageid, title: $0.cleanTitle, year: $0.year, image: $0.thumbnail.flatMap { URL(string: $0.source) })
        }
    }
}

/// Picks the provider: TMDB when the user has a key, else the two that need none.
enum Metadata {
    static func provider(tv: Bool) -> String { !TMDB.key.isEmpty ? "tmdb" : tv ? "tvmaze" : "wiki" }

    static func lookup(title: String, year: String?, tv: Bool, known: MatchOverride?, seasons: [Int], imageDir: URL) async -> TMDB.Result {
        let p = provider(tv: tv)
        let id = known?.source == p ? known?.id : nil          // an id only means something to its own database
        switch p {
        case "tmdb":   return await TMDB.lookup(title: title, year: year, tv: tv, knownID: id, seasons: seasons, imageDir: imageDir)
        case "tvmaze": return await TVmaze.lookup(title: title, knownID: id, imageDir: imageDir)
        default:       return await Wiki.lookup(title: title, year: year, knownID: id, imageDir: imageDir)
        }
    }
    static func candidates(query: String, tv: Bool) async -> [MatchCandidate] {
        switch provider(tv: tv) {
        case "tmdb":   return await TMDB.candidates(query: query, tv: tv)
        case "tvmaze": return await TVmaze.candidates(query: query)
        default:       return await Wiki.candidates(query: query)
        }
    }
}
