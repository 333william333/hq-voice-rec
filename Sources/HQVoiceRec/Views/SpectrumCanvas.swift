import SwiftUI

/// Spectroid-style real-time analyzer: log-frequency spectrum on top, scrolling spectrogram below.
struct SpectrumCanvas: View {
    @Environment(AppModel.self) private var model

    private let insets = EdgeInsets(top: 10, leading: 46, bottom: 22, trailing: 12)
    private let spectrumShare: CGFloat = 0.58
    private let gap: CGFloat = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas(rendersAsynchronously: false) { gc, size in
                _ = timeline.date
                draw(in: &gc, size: size, snapshot: model.processor.snapshot())
            }
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.05))
        .onContinuousHover { phase in
            switch phase {
            case let .active(point): model.analyzerHover = point
            case .ended: model.analyzerHover = nil
            }
        }
    }

    // MARK: Layout

    private func spectrumRect(_ size: CGSize) -> CGRect {
        let height = (size.height - insets.top - insets.bottom - gap) * spectrumShare
        return CGRect(x: insets.leading, y: insets.top,
                      width: size.width - insets.leading - insets.trailing, height: height)
    }

    private func waterfallRect(_ size: CGSize) -> CGRect {
        let top = spectrumRect(size)
        let y = top.maxY + gap
        return CGRect(x: top.minX, y: y, width: top.width, height: size.height - y - 8)
    }

    // MARK: Drawing

    private func draw(in gc: inout GraphicsContext, size: CGSize, snapshot: VisualSnapshot) {
        let plot = spectrumRect(size)
        let fall = waterfallRect(size)
        guard plot.width > 20, plot.height > 20 else { return }

        let fMin = snapshot.minFrequency
        let fMax = snapshot.sampleRate / 2
        let dbMax: Double = 0
        let dbMin = model.analyzer.floorDB
        let logSpan = log(fMax / fMin)
        func x(_ f: Double) -> CGFloat { plot.minX + plot.width * CGFloat(log(f / fMin) / logSpan) }
        func y(_ db: Double) -> CGFloat {
            plot.minY + plot.height * CGFloat((dbMax - min(max(db, dbMin), dbMax)) / (dbMax - dbMin))
        }

        drawGrid(&gc, plot: plot, fall: fall, fMin: fMin, fMax: fMax, dbMin: dbMin, x: x, y: y)

        // Spectrum
        let values = snapshot.spectrum
        if values.count > 1 {
            let step = plot.width / CGFloat(values.count)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: plot.minX + (CGFloat(i) + 0.5) * step, y: y(Double(v)))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            fill.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
            fill.closeSubpath()

            var clipped = gc
            clipped.clip(to: Path(plot))
            clipped.fill(fill, with: .linearGradient(
                Gradient(colors: [Color(red: 0.25, green: 0.8, blue: 1).opacity(0.55),
                                  Color(red: 0.1, green: 0.3, blue: 0.9).opacity(0.08)]),
                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))

            if model.analyzer.showPeakHold, snapshot.peakHold.count == values.count {
                var hold = Path()
                for (i, v) in snapshot.peakHold.enumerated() {
                    let p = CGPoint(x: plot.minX + (CGFloat(i) + 0.5) * step, y: y(Double(v)))
                    i == 0 ? hold.move(to: p) : hold.addLine(to: p)
                }
                clipped.stroke(hold, with: .color(Color(red: 1, green: 0.78, blue: 0.25).opacity(0.65)), lineWidth: 1)
            }
            clipped.stroke(line, with: .color(Color(red: 0.45, green: 0.9, blue: 1)), lineWidth: 1.5)
        }

        // Dominant peak
        if snapshot.peakLevel > Float(dbMin + 20), snapshot.peakFrequency > fMin {
            let px = x(snapshot.peakFrequency), py = y(Double(snapshot.peakLevel))
            gc.fill(Path(ellipseIn: CGRect(x: px - 3.5, y: py - 3.5, width: 7, height: 7)), with: .color(.white))
            let text = Text("\(Self.formatFrequency(snapshot.peakFrequency))  \(Self.noteName(snapshot.peakFrequency))  \(Self.formatDB(Double(snapshot.peakLevel)))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            gc.draw(text, at: CGPoint(x: plot.maxX - 8, y: plot.minY + 8), anchor: .topTrailing)
            gc.draw(Text("TOPP").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.45)),
                    at: CGPoint(x: plot.maxX - 8, y: plot.minY + 25), anchor: .topTrailing)
        }

        // Spectrogram
        if let image = snapshot.waterfall, fall.height > 10 {
            gc.draw(Image(decorative: image, scale: 1).interpolation(.medium), in: fall)
        }
        gc.stroke(Path(fall), with: .color(.white.opacity(0.08)), lineWidth: 1)

        // Hover read-out
        if let hover = model.analyzerHover {
            let inPlot = plot.contains(hover), inFall = fall.contains(hover)
            if inPlot || inFall {
                let fraction = Double((hover.x - plot.minX) / plot.width)
                let frequency = fMin * pow(fMax / fMin, fraction)
                var cross = Path()
                cross.move(to: CGPoint(x: hover.x, y: plot.minY))
                cross.addLine(to: CGPoint(x: hover.x, y: fall.maxY))
                if inPlot {
                    cross.move(to: CGPoint(x: plot.minX, y: hover.y))
                    cross.addLine(to: CGPoint(x: plot.maxX, y: hover.y))
                }
                gc.stroke(cross, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                var label = "\(Self.formatFrequency(frequency))  \(Self.noteName(frequency))"
                if inPlot {
                    let db = dbMax - Double((hover.y - plot.minY) / plot.height) * (dbMax - dbMin)
                    label += "  \(Self.formatDB(db))"
                }
                let text = gc.resolve(Text(label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.white))
                let textSize = text.measure(in: CGSize(width: 400, height: 40))
                var origin = CGPoint(x: hover.x + 10, y: max(hover.y - textSize.height - 10, plot.minY + 2))
                if origin.x + textSize.width + 12 > plot.maxX { origin.x = hover.x - textSize.width - 18 }
                let bubble = CGRect(x: origin.x - 6, y: origin.y - 3, width: textSize.width + 12, height: textSize.height + 6)
                gc.fill(Path(roundedRect: bubble, cornerRadius: 5), with: .color(.black.opacity(0.75)))
                gc.draw(text, at: origin, anchor: .topLeading)
            }
        }
    }

    private func drawGrid(_ gc: inout GraphicsContext, plot: CGRect, fall: CGRect,
                          fMin: Double, fMax: Double, dbMin: Double,
                          x: (Double) -> CGFloat, y: (Double) -> CGFloat) {
        let minor = Color.white.opacity(0.045)
        let major = Color.white.opacity(0.11)
        let labelColor = Color.white.opacity(0.5)

        // Frequency lines (1-2-5 majors, every integer multiple as minor)
        var minorPath = Path(), majorPath = Path()
        var decade = 10.0
        while decade < fMax {
            for m in 1...9 {
                let f = decade * Double(m)
                guard f >= fMin, f <= fMax else { continue }
                let px = x(f)
                let isMajor = m == 1 || m == 2 || m == 5
                var p = isMajor ? majorPath : minorPath
                p.move(to: CGPoint(x: px, y: plot.minY))
                p.addLine(to: CGPoint(x: px, y: plot.maxY))
                if isMajor { majorPath = p } else { minorPath = p }
                if isMajor {
                    let label = Text(Self.axisFrequency(f)).font(.system(size: 10, weight: .medium)).foregroundColor(labelColor)
                    gc.draw(label, at: CGPoint(x: px, y: plot.maxY + 5), anchor: .top)
                    var tick = Path()
                    tick.move(to: CGPoint(x: px, y: fall.minY))
                    tick.addLine(to: CGPoint(x: px, y: fall.minY + 5))
                    gc.stroke(tick, with: .color(.white.opacity(0.3)), lineWidth: 1)
                }
            }
            decade *= 10
        }

        // Level lines every 10 dB, labelled every 20 dB
        var db = 0.0
        while db >= dbMin - 0.1 {
            let py = y(db)
            var p = Int(db) % 20 == 0 ? majorPath : minorPath
            p.move(to: CGPoint(x: plot.minX, y: py))
            p.addLine(to: CGPoint(x: plot.maxX, y: py))
            if Int(db) % 20 == 0 {
                majorPath = p
                let label = Text("\(Int(db))").font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundColor(labelColor)
                gc.draw(label, at: CGPoint(x: plot.minX - 7, y: py), anchor: .trailing)
            } else {
                minorPath = p
            }
            db -= 10
        }
        gc.stroke(minorPath, with: .color(minor), lineWidth: 1)
        gc.stroke(majorPath, with: .color(major), lineWidth: 1)
        let unit = Color.white.opacity(0.35)
        gc.draw(Text("dBFS").font(.system(size: 9, weight: .bold)).foregroundColor(unit),
                at: CGPoint(x: plot.minX + 8, y: plot.minY + 6), anchor: .topLeading)
        gc.draw(Text("Hz").font(.system(size: 9, weight: .bold)).foregroundColor(unit),
                at: CGPoint(x: plot.maxX - 8, y: plot.maxY - 6), anchor: .bottomTrailing)
        gc.draw(Text("tid ↓").font(.system(size: 9, weight: .bold)).foregroundColor(unit),
                at: CGPoint(x: plot.minX - 7, y: fall.minY + 4), anchor: .topTrailing)
        gc.stroke(Path(plot), with: .color(.white.opacity(0.08)), lineWidth: 1)
    }

    // MARK: Formatting

    static func axisFrequency(_ f: Double) -> String {
        f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    static func formatFrequency(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.2f kHz", f / 1000) : String(format: "%.1f Hz", f)
    }

    static func formatDB(_ db: Double) -> String {
        String(format: "%.1f dB", db).replacingOccurrences(of: "-", with: "−")
    }

    static func noteName(_ f: Double) -> String {
        guard f > 0 else { return "" }
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "H"]
        let midi = 12 * log2(f / 440) + 69
        let nearest = Int(midi.rounded())
        let cents = Int(((midi - Double(nearest)) * 100).rounded())
        let name = names[((nearest % 12) + 12) % 12] + "\(nearest / 12 - 1)"
        return cents == 0 ? name : "\(name) \(cents > 0 ? "+" : "−")\(abs(cents))¢"
    }
}
