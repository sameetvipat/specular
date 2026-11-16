import AppKit
import AetherEngine

// Stills from the playing file: the scrubber's hover thumbnail and Save Frame (Cmd-Shift-S).
extension PlayerModel {
    /// One extractor per opened file, made on first use (its own demuxer: any position, no playback).
    private var extractor: FrameExtractor? {
        if frames == nil { frames = engine.makeFrameExtractor() }
        return frames
    }

    /// Thumbnail for the scrubber at `t`. Latest wins: a newer request cancels the older one,
    /// and 60 ms of stillness is needed before a decode starts.
    func requestScrub(at t: Double) {
        guard !audioOnly, duration > 0 else { return }
        scrubTask?.cancel()
        scrubTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !Task.isCancelled else { return }
            // The playback cache first (no second reader); the extractor covers what is not cached.
            var img = await self.engine.scrubThumbnail(atSeconds: t, maxWidth: 320)
            if img == nil, !Task.isCancelled { img = await self.extractor?.thumbnail(at: t, maxWidth: 320) }
            if !Task.isCancelled { self.scrubImage = img }      // nil: the scrubber shows the time only
        }
    }
    func clearScrub() { scrubTask?.cancel(); scrubImage = nil }

    func closeFrames() {
        clearScrub()
        if let f = frames { frames = nil; Task { await f.shutdown() } }
    }

    static let framesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Specular")

    /// Save the frame on screen as "<title> <hh-mm-ss>.png" (HDR is tone-mapped to SDR by the engine).
    /// Returns the file, or nil when there is no picture or the write failed.
    @discardableResult
    func saveFrame(to dir: URL = PlayerModel.framesDir) async -> URL? {
        guard !audioOnly else { return nil }
        let t = position, s = Int(t)
        var cg = await extractor?.snapshot(at: t)
        if cg == nil { cg = await engine.scrubThumbnail(atSeconds: t, maxWidth: videoWidth) }
        let name = displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            + String(format: " %02d-%02d-%02d.png", s / 3600, (s % 3600) / 60, s % 60)
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let cg, let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            flash("Could not save the frame"); return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { flash("Could not save the frame"); return nil }
        flash("Saved \(name)")
        return url
    }

    /// Brief message at the top of the picture.
    func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
