import Foundation
import AetherEngine

/// A ripped Blu-ray (BDMV) or DVD (VIDEO_TS) folder on disk, handed to Aether as
/// `load(source: .custom(DiscFolder(root)))`. The engine picks titles and joins clips itself;
/// we only list the files and open them. (ISOs need none of this: they load by URL.)
final class DiscFolder: DiscDirectoryReader, @unchecked Sendable {
    let root: URL
    let discFiles: [(path: String, size: Int64)]
    var preferredPlaylist: String? { nil }

    /// The disc root for `path` (the folder itself, or the parent of a BDMV / VIDEO_TS folder), or nil.
    static func root(of path: String) -> URL? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let u = URL(fileURLWithPath: path)
        if ["bdmv", "video_ts"].contains(u.lastPathComponent.lowercased()) { return u.deletingLastPathComponent() }
        for sub in ["BDMV", "VIDEO_TS"] where FileManager.default.fileExists(atPath: u.appendingPathComponent(sub).path) { return u }
        return nil
    }

    init(_ root: URL) {
        self.root = root
        var files: [(String, Int64)] = []
        let base = root.standardizedFileURL.path + "/"
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let u as URL in en {
                guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                files.append((String(u.standardizedFileURL.path.dropFirst(base.count)), Int64(v.fileSize ?? 0)))
            }
        }
        discFiles = files
    }

    func openDiscFile(_ path: String) -> IOReader? {
        guard let match = discFiles.first(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) else { return nil }
        return LocalFileReader(root.appendingPathComponent(match.path))
    }

    // The folder itself carries no bytes: the engine never reads it.
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { -1 }
    func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
    func close() {}
}

/// Plain file reader for one disc file (seekable, independent readers for the side demuxer).
final class LocalFileReader: IOReader, @unchecked Sendable {
    private let url: URL
    private let fh: FileHandle?
    private let size: Int64
    init?(_ url: URL) {
        self.url = url
        fh = try? FileHandle(forReadingFrom: url)
        guard fh != nil else { return nil }
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size n: Int32) -> Int32 {
        guard let fh, let buffer, n > 0 else { return -1 }
        guard let d = try? fh.read(upToCount: Int(n)) else { return -1 }
        d.copyBytes(to: buffer, count: d.count)
        return Int32(d.count)
    }
    func seek(offset: Int64, whence: Int32) -> Int64 {
        guard let fh else { return -1 }
        let cur = Int64((try? fh.offset()) ?? 0)
        let target: Int64
        switch whence {
        case 65536: return size                          // AVSEEK_SIZE
        case SEEK_SET: target = offset
        case SEEK_CUR: target = cur + offset
        case SEEK_END: target = size + offset
        default: return -1
        }
        guard target >= 0, (try? fh.seek(toOffset: UInt64(target))) != nil else { return -1 }
        return target
    }
    func close() { try? fh?.close() }
    func makeIndependentReader() -> IOReader? { LocalFileReader(url) }
    var discImageProbeEnabled: Bool { false }            // one clip of a folder, never an image
}
