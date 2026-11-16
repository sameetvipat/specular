import SwiftUI
import AetherEngine
import MediaAccessibility

/// Draws the engine's subtitle cues over the picture (AetherEngine leaves drawing to the host).
/// Text cues use the system caption style (as the Apple TV app does) or the custom style from
/// Settings; bitmap cues (PGS, VobSub, DVB) are placed where
/// the disc authored them. Styled ASS / SSA goes through libass (ASSOverlay) when it is active.
struct SubtitleOverlay: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        GeometryReader { geo in
            let rect = videoRect(in: geo.size)
            // While the controls are up, bottom subtitles rise so they clear the scrubber (its top
            // sits about 135 pt above the window bottom); letterbox bars already give some room.
            let lift = model.controlsVisible ? max(0, 150 - (geo.size.height - rect.maxY)) : 0
            if let r = model.assRenderer {
                ASSLayerView(renderer: r)           // libass draws top and bottom lines in one layer: it all moves
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .offset(y: -lift)
            }
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                let t = model.engine.clock.sourceTime - model.subtitleDelay
                let cues = model.currentSubtitle >= 0
                    ? model.engine.subtitleCues.filter { $0.startTime <= t && t < $0.endTime } : []
                ZStack {
                    ForEach(cues, id: \.id) { cue in
                        if case .image(let img) = cue.body {
                            let r = imageRect(img, in: rect)
                            Image(decorative: img.cgImage, scale: 1).resizable()
                                .frame(width: r.width, height: r.height)
                                .position(x: r.midX, y: r.midY)
                                .offset(y: r.midY > rect.midY ? -lift : 0)      // only bitmaps in the lower half
                        }
                    }
                    let lines = cues.compactMap(\.text).filter { !$0.isEmpty }
                    if !lines.isEmpty, !model.assActive {
                        let text = lines.joined(separator: "\n")
                        let top = (cues.first?.placement?.alignment ?? 2) >= 7
                        Group {
                            if Settings.subStyle == 0 {
                                systemBlock(text, in: rect, placement: cues.first?.placement)
                            } else {
                                textBlock(text, in: rect, placement: cues.first?.placement)
                            }
                        }
                        .offset(y: top ? 0 : -lift)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.35), value: model.controlsVisible)
    }

    /// The picture's rect inside the view: aspect fit, as the engine's layer draws it.
    private func videoRect(in size: CGSize) -> CGRect {
        guard model.videoWidth > 0, model.videoHeight > 0 else { return CGRect(origin: .zero, size: size) }
        let a = Double(model.videoWidth) / Double(model.videoHeight)
        var w = size.width, h = w / a
        if h > size.height { h = size.height; w = h * a }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Bitmap position is normalized to its canvas; the canvas maps width-aligned and centred onto
    /// the picture (a cropped rip can have a canvas taller than the video).
    private func imageRect(_ img: SubtitleImage, in video: CGRect) -> CGRect {
        var canvas = video
        if img.canvasSize.width > 0, img.canvasSize.height > 0 {
            let h = video.width * img.canvasSize.height / img.canvasSize.width
            canvas = CGRect(x: video.minX, y: video.midY - h / 2, width: video.width, height: h)
        }
        let p = img.position
        return CGRect(x: canvas.minX + p.minX * canvas.width, y: canvas.minY + p.minY * canvas.height,
                      width: p.width * canvas.width, height: p.height * canvas.height)
    }

    /// The Apple TV look: system caption style, text 5% of the picture height, lines wrapped at 80%
    /// of its width, 8% bottom margin, a background box per line and one window box behind them.
    private func systemBlock(_ text: String, in video: CGRect, placement: SubtitleTextPlacement?) -> some View {
        let st = CaptionStyle.current
        let size = max(14, video.height * 0.05 * st.relativeSize * model.subtitleScale)
        let font = CTFontCreateWithFontDescriptor(st.font, size, nil)
        let lines = CaptionStyle.wrap(text, font: font, width: video.width * 0.8)
        let top = (placement?.alignment ?? 2) >= 7
        return VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                edged(Text(line).font(Font(font)).foregroundStyle(st.foreground), st.edge, max(1, size * 0.04))
                    .fixedSize()
                    .padding(.horizontal, size * 0.3)
                    .padding(.vertical, size * 0.06)
                    .background(st.background, in: RoundedRectangle(cornerRadius: size * 0.15))
            }
        }
        .padding(.horizontal, size * 0.15)
        .padding(.vertical, size * 0.1)
        .background(st.window, in: RoundedRectangle(cornerRadius: st.windowRadius))
        .padding(.vertical, video.height * 0.08)
        .frame(width: video.width, height: video.height, alignment: top ? .top : .bottom)
        .position(x: video.midX, y: video.midY)
    }

    /// The system text edge styles; `d` is the edge offset in points.
    @ViewBuilder private func edged(_ t: Text, _ edge: MACaptionAppearanceTextEdgeStyle, _ d: Double) -> some View {
        switch edge {
        case .uniform:
            t.shadow(color: .black, radius: 0, x: d, y: d).shadow(color: .black, radius: 0, x: -d, y: -d)
                .shadow(color: .black, radius: 0, x: d, y: -d).shadow(color: .black, radius: 0, x: -d, y: d)
        case .dropShadow: t.shadow(color: .black.opacity(0.8), radius: d * 2, x: d, y: d)
        case .raised: t.shadow(color: .black, radius: 0, x: d, y: d)
        case .depressed: t.shadow(color: .black, radius: 0, x: -d, y: -d)
        default: t
        }
    }

    private func textBlock(_ text: String, in video: CGRect, placement: SubtitleTextPlacement?) -> some View {
        let size = max(14, video.height * 0.048 * model.subtitleScale)
        let color = Color(rgb: Settings.subColor)
        let edge = Settings.subOutline           // 0 none, 1 outline, 2 shadow, 3 box
        let label = Text(text)
            .font(.system(size: size, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(color)
            .padding(.horizontal, edge == 3 ? size * 0.35 : 0)
            .padding(.vertical, edge == 3 ? size * 0.12 : 0)
            .background(edge == 3 ? Color.black.opacity(Double(Settings.subBgPct) / 100) : .clear,
                        in: RoundedRectangle(cornerRadius: size * 0.15))
            .shadow(color: .black.opacity(edge == 1 ? 0.95 : 0), radius: 0, x: 1, y: 1)
            .shadow(color: .black.opacity(edge == 1 ? 0.95 : 0), radius: 0, x: -1, y: -1)
            .shadow(color: .black.opacity(edge == 1 ? 0.95 : 0), radius: 0, x: 1, y: -1)
            .shadow(color: .black.opacity(edge == 1 ? 0.95 : 0), radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(edge == 2 ? 0.8 : 0), radius: size * 0.12, x: 0, y: size * 0.06)
            .frame(maxWidth: video.width * 0.9)
        // ASS \an top alignments (7-9) go to the top; everything else sits at the bottom, raised by
        // the Position setting (Low / Higher / Highest).
        let top = (placement?.alignment ?? 2) >= 7
        let margin = video.height * (0.05 + Double(Settings.subPosition) / 1000)
        return label
            .fixedSize(horizontal: false, vertical: true)
            .position(x: video.midX, y: top ? video.minY + margin + size : video.maxY - margin - size)
    }
}

extension Color {
    init(rgb: Int) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}
