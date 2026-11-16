// sckcap — capture the real HDR pixel values a window shows, past screenshot clipping.
// macOS 15+ gives canonical HDR (1.0 = 100 nits) so values are display-independent.
// Samples a horizontal line and writes each column's R,G,B in nits.
//
// Usage: sckcap <window-title-substring> <out.csv> [row-fraction 0..1]
import ScreenCaptureKit
import CoreVideo
import CoreMedia
import AppKit

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

_ = NSApplication.shared   // connect a CLI tool to the window server
NSApp.setActivationPolicy(.accessory)
let args = CommandLine.arguments
guard args.count >= 3 else { eprint("usage: sckcap <window-title-substring> <out.csv> [row-fraction]"); exit(2) }
let needle = args[1], outPath = args[2]
let rowFrac = args.count > 3 ? (Double(args[3]) ?? 0.5) : 0.5

func capture() async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let win = content.windows.first(where: { ($0.title ?? "").contains(needle) && $0.frame.width > 100 })
        ?? content.windows.first(where: { ($0.owningApplication?.applicationName ?? "").contains(needle) }) else {
        eprint("windows seen: " + content.windows.compactMap { $0.title }.filter { !$0.isEmpty }.joined(separator: " | "))
        exit(1)
    }
    eprint("capturing '\(win.title ?? "?")' \(Int(win.frame.width))x\(Int(win.frame.height))")
    let filter = SCContentFilter(desktopIndependentWindow: win)
    let cfg = SCStreamConfiguration()
    cfg.width = Int(win.frame.width); cfg.height = Int(win.frame.height)
    cfg.pixelFormat = kCVPixelFormatType_64RGBAHalf
    cfg.colorSpaceName = CGColorSpace.extendedLinearDisplayP3
    cfg.showsCursor = false
    if #available(macOS 15.0, *) { cfg.captureDynamicRange = .hdrLocalDisplay }   // what the panel actually shows
    else { eprint("note: macOS < 15 — SDR capture, HDR values clipped") }
    let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: cfg)
    guard let pb = sample.imageBuffer else { eprint("no image buffer"); exit(1) }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let base = CVPixelBufferGetBaseAddress(pb) else { eprint("no base addr"); exit(1) }
    let row = min(h - 1, max(0, Int(Double(h) * rowFrac)))
    let p = base.advanced(by: row * bpr).assumingMemoryBound(to: UInt16.self)
    func half(_ x: UInt16) -> Float { Float(Float16(bitPattern: x)) }
    var out = "x,R_nits,G_nits,B_nits\n"
    for x in 0..<w {
        out += "\(x),\(half(p[x*4]) * 100),\(half(p[x*4+1]) * 100),\(half(p[x*4+2]) * 100)\n"
    }
    try out.write(toFile: outPath, atomically: true, encoding: .utf8)
    eprint("wrote \(w) columns (row \(row)) -> \(outPath)")
}

do { try await capture() } catch { eprint("error: \(error)"); exit(1) }
