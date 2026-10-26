import SwiftUI

/// Peak / RMS meters (−60…0 dBFS) for the channels being recorded, with peak-hold and clip latch.
struct LevelMeters: View {
    @Environment(AppModel.self) private var model

    private static let ticks: [Double] = [-60, -48, -36, -24, -18, -12, -6, -3, 0]
    private let floor: Double = -60

    var body: some View {
        TimelineView(.animation) { _ in
            let snapshot = model.processor.snapshot()
            let indices = model.settings.channelIndices(deviceChannels: max(model.activeChannels, 1))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(indices, id: \.self) { channel in
                    row(channel: channel, snapshot: snapshot)
                }
                scale.padding(.leading, 22).padding(.trailing, 92)
            }
        }
    }

    private func row(channel: Int, snapshot: VisualSnapshot) -> some View {
        let peak = value(snapshot.meterPeak, channel)
        let rms = value(snapshot.meterRMS, channel)
        let hold = value(snapshot.meterHold, channel)
        let clipped = channel < snapshot.clipped.count && snapshot.clipped[channel]
        return HStack(spacing: 8) {
            Text("\(channel + 1)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Canvas { gc, size in
                let rect = CGRect(origin: .zero, size: size)
                gc.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.primary.opacity(0.08)))
                let gradient = Gradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .green, location: position(-18)),
                    .init(color: .yellow, location: position(-9)),
                    .init(color: .orange, location: position(-4)),
                    .init(color: .red, location: 1),
                ])
                let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
                var bar = gc
                bar.clip(to: Path(roundedRect: rect, cornerRadius: 3))
                bar.opacity = 0.45
                bar.fill(Path(CGRect(x: 0, y: 0, width: size.width * position(peak), height: size.height)), with: shading)
                bar.opacity = 1
                bar.fill(Path(CGRect(x: 0, y: size.height * 0.2, width: size.width * position(rms), height: size.height * 0.6)), with: shading)
                let hx = size.width * position(hold)
                if hold > floor {
                    bar.fill(Path(CGRect(x: max(hx - 2, 0), y: 0, width: 2, height: size.height)), with: .color(.primary.opacity(0.85)))
                }
                for tick in Self.ticks.dropFirst().dropLast() {
                    let tx = size.width * position(tick)
                    bar.fill(Path(CGRect(x: tx, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.25)))
                }
            }
            .frame(height: 12)
            Text(Self.format(hold))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(hold > -3 ? .red : hold > -9 ? .orange : .primary)
                .frame(width: 52, alignment: .trailing)
            Button {
                model.processor.resetClipIndicators()
            } label: {
                Text("CLIP")
                    .font(.system(size: 9, weight: .heavy))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(clipped ? Color.red : Color.primary.opacity(0.08)))
                    .foregroundStyle(clipped ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .help("Signalen nådde 0 dBFS. Klicka (⌘K) för att nollställa.")
        }
    }

    private var scale: some View {
        GeometryReader { geo in
            ForEach(Self.ticks, id: \.self) { tick in
                Text(tick == 0 ? "0" : "\(Int(tick))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .position(x: geo.size.width * position(tick), y: 5)
            }
        }
        .frame(height: 10)
    }

    private func value(_ array: [Float], _ index: Int) -> Double {
        index < array.count ? Double(array[index]) : -120
    }

    private func position(_ db: Double) -> CGFloat {
        CGFloat(min(max((db - floor) / -floor, 0), 1))
    }

    static func format(_ db: Double) -> String {
        db <= -99 ? "−∞" : String(format: "%.1f", db).replacingOccurrences(of: "-", with: "−")
    }
}
