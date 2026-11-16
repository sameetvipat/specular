import SwiftUI
import CoreText
import MediaAccessibility

/// The user's system caption style (System Settings > Accessibility > Captions), the one AVKit and
/// the Apple TV app draw subtitles with.
struct CaptionStyle {
    let font: CTFontDescriptor
    let foreground, background, window: Color    // background: box behind each line; window: behind the block
    let windowRadius: Double
    let edge: MACaptionAppearanceTextEdgeStyle
    let relativeSize: Double

    private static var cached: CaptionStyle?
    private static let observer = NotificationCenter.default.addObserver(
        forName: .init(kMACaptionAppearanceSettingsChangedNotification as String), object: nil, queue: .main) { _ in cached = nil }

    /// Cached; re-read after the user changes the style in System Settings.
    static var current: CaptionStyle {
        _ = observer
        if let c = cached { return c }
        let d = MACaptionAppearanceDomain.user
        let c = CaptionStyle(
            font: MACaptionAppearanceCopyFontDescriptorForStyle(d, nil, .default).takeRetainedValue(),
            foreground: Color(cgColor: MACaptionAppearanceCopyForegroundColor(d, nil).takeRetainedValue())
                .opacity(MACaptionAppearanceGetForegroundOpacity(d, nil)),
            background: Color(cgColor: MACaptionAppearanceCopyBackgroundColor(d, nil).takeRetainedValue())
                .opacity(MACaptionAppearanceGetBackgroundOpacity(d, nil)),
            window: Color(cgColor: MACaptionAppearanceCopyWindowColor(d, nil).takeRetainedValue())
                .opacity(MACaptionAppearanceGetWindowOpacity(d, nil)),
            windowRadius: MACaptionAppearanceGetWindowRoundedCornerRadius(d, nil),
            edge: MACaptionAppearanceGetTextEdgeStyle(d, nil),
            relativeSize: MACaptionAppearanceGetRelativeCharacterSize(d, nil))
        cached = c
        return c
    }

    /// Breaks text into display lines no wider than `width`, so each line can get its own box.
    static func wrap(_ text: String, font: CTFont, width: Double) -> [String] {
        text.split(separator: "\n").flatMap { para -> [String] in
            let s = String(para) as NSString
            let setter = CTTypesetterCreateWithAttributedString(
                NSAttributedString(string: s as String, attributes: [.font: font]))
            var out: [String] = [], start = 0
            while start < s.length {
                let n = max(1, CTTypesetterSuggestLineBreak(setter, start, width))
                out.append(s.substring(with: NSRange(location: start, length: n)).trimmingCharacters(in: .whitespaces))
                start += n
            }
            return out
        }
    }
}
