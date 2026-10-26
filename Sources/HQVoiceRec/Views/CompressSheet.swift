import SwiftUI

struct CompressSheet: View {
    let session: CompressionSession
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 18) {
            header

            switch session.phase {
            case let .analyzing(progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                    Text("Analyserar ljudet och mäter hur väl det går att komprimera…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 30)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.vertical, 20)
            case let .finished(result):
                finished(result)
            case .ready, .exporting:
                controls
            }

            footer
        }
        .padding(22)
        .frame(width: 660)
        .onAppear { session.start() }
        .onDisappear { session.cancel() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.right.and.arrow.up.left.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Skapa komprimerad kopia").font(.title3.weight(.semibold))
                Text("\(session.item.name) · \(RecordingRow.duration(session.item.duration)) · \(session.item.formatDescription) · \(ByteCountFormatter.string(fromByteCount: session.item.size, countStyle: .decimal))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        @Bindable var session = session
        let exporting: Bool = { if case .exporting = session.phase { return true }; return false }()

        if let info = session.info {
            WaveformOverview(info: info, option: session.chosen, request: session.request)
                .frame(height: 64)
            WaveformOverview.legendRow
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, -10)
        }

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                Text("Max filstorlek").gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    TextField("MB", value: $session.maxMB, format: .number.precision(.fractionLength(0...1)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                    Stepper("", value: $session.maxMB, in: 0.5...2000, step: 1).labelsHidden()
                    Text("MB").foregroundStyle(.secondary)
                    Menu("Förval") {
                        ForEach(CompressionSession.presets, id: \.1) { label, value in
                            Button(label) { session.maxMB = value }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            GridRow {
                Text("Prioritera")
                VStack(spacing: 2) {
                    Slider(value: $session.balance, in: 0...1)
                    HStack {
                        Text("Hela längden")
                        Spacer()
                        Text("Balanserat")
                        Spacer()
                        Text("Ljudkvaliteten")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Max längd")
                HStack(spacing: 8) {
                    Toggle("", isOn: $session.limitLength).labelsHidden()
                    TextField("min", value: $session.maxMinutes, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .disabled(!session.limitLength)
                    Stepper("", value: $session.maxMinutes, in: 0.25...600, step: 0.5).labelsHidden()
                        .disabled(!session.limitLength)
                    Text("min").foregroundStyle(.secondary)
                    Menu("Förval") {
                        ForEach(CompressionSession.lengthPresets, id: \.label) { preset in
                            Button(preset.label) {
                                session.maxMinutes = preset.minutes
                                session.limitLength = true
                                if let type = preset.fileType { session.fileType = type }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            GridRow {
                Text("Filtyp")
                Picker("", selection: $session.fileType) {
                    ForEach(FileTypeFilter.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Välj M4A eller WAV om sidan du laddar upp till inte tar emot FLAC.")
            }
            if let option = session.chosen, option.keptSeconds < session.totalSeconds - 0.5 {
                GridRow {
                    Text("Del att behålla")
                    VStack(spacing: 2) {
                        Slider(value: $session.position, in: 0...1)
                        HStack {
                            Text("Början")
                            Spacer()
                            Text(partLabel(option))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("Slutet")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle(isOn: $session.trimSilence) {
                    if let info = session.info, info.hasSilenceToTrim {
                        let saved = info.duration - info.seconds(Int64(info.soundRange.count))
                        Text("Ta bort tystnad i början och slutet (\(String(format: "%.1f", saved)) s)")
                    } else {
                        Text("Ta bort tystnad i början och slutet")
                    }
                }
            }
        }
        .disabled(exporting)

        if let option = session.chosen {
            ResultCard(option: option, isAutomatic: session.manualChoice == nil, maxBytes: session.request.maxBytes,
                       totalSeconds: session.totalSeconds)
        } else {
            Label("Inget format får plats inom \(session.maxMB.formatted()) MB – öka storleken.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

        DisclosureGroup("Alla alternativ") {
            AlternativesList(session: session)
                .padding(.top, 6)
        }
        .disabled(exporting)
    }

    private func partLabel(_ option: PlanOption) -> String {
        guard let info = session.info else { return "" }
        let range = CompressionEngine.keptRange(info: info, request: session.request,
                                                keep: Int64(option.keptSeconds * info.sampleRate))
        return "\(RecordingRow.duration(info.seconds(range.lowerBound))) – \(RecordingRow.duration(info.seconds(range.upperBound)))"
    }

    private func finished(_ result: CompressionEngine.Result) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(result.variant.title) · \(RecordingRow.duration(result.seconds)) · \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .decimal))")
                    .foregroundStyle(.secondary)
                Text("Sparad bredvid originalet i \(model.folderDisplayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack {
            if case let .exporting(progress) = session.phase {
                ProgressView(value: progress).frame(width: 200)
                Text("Skapar kopia…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .finished(result) = session.phase {
                Button("Visa i Finder") { model.revealInFinder(result.url) }
                Button("Klar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Avbryt") {
                    session.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Skapa kopia") { session.export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(session.chosen == nil || session.isBusy)
            }
        }
    }
}

// MARK: - Result card

private struct ResultCard: View {
    let option: PlanOption
    let isAutomatic: Bool
    let maxBytes: Int64
    let totalSeconds: Double

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            QualityGauge(quality: option.variant.quality)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(option.variant.title).font(.headline)
                    if isAutomatic {
                        Text("BÄST")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(option.variant.qualityLabel).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label(lengthText, systemImage: isWhole ? "checkmark.circle" : "scissors")
                        .foregroundStyle(isWhole ? Color.green : Color.orange)
                    Label("≈ \(ByteCountFormatter.string(fromByteCount: Int64(option.estimatedBytes), countStyle: .decimal)) av \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .decimal))",
                          systemImage: "internaldrive")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
    }

    private var isWhole: Bool { option.keptSeconds >= totalSeconds - 0.5 }

    private var lengthText: String {
        let kept = RecordingRow.duration(option.keptSeconds)
        if isWhole { return "Hela klippet (\(kept))" }
        let reason = option.isComplete ? "max längd" : "filstorlek"
        return "\(kept) av \(RecordingRow.duration(totalSeconds)) · begränsat av \(reason)"
    }
}

private struct QualityGauge: View {
    let quality: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 5)
            Circle()
                .trim(from: 0, to: quality)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((quality * 100).rounded()))")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(width: 46, height: 46)
        .help("Uppskattad ljudkvalitet (100 = bitperfekt)")
    }

    private var color: Color {
        quality >= 0.93 ? .green : quality >= 0.8 ? .mint : quality >= 0.6 ? .yellow : .orange
    }
}

// MARK: - Alternatives

private struct AlternativesList: View {
    let session: CompressionSession

    var body: some View {
        let automatic = session.automatic?.id
        let chosen = session.chosen?.id
        VStack(spacing: 0) {
            row(title: "Automatiskt (rekommenderas)", detail: session.automatic?.variant.title ?? "–",
                length: nil, selected: session.manualChoice == nil) {
                session.manualChoice = nil
            }
            ForEach(session.options) { option in
                Divider()
                row(title: option.variant.title + (option.id == automatic ? "  ★" : ""),
                    detail: option.variant.qualityLabel,
                    length: option,
                    selected: session.manualChoice != nil && option.id == chosen) {
                    session.manualChoice = option.id
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func row(title: String, detail: String, length: PlanOption?, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let length {
                    Text(length.isComplete ? "Hela" : "\(Int(length.keptFraction * 100)) %")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(length.isComplete ? Color.green : Color.orange)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Waveform overview

/// Level overview of the whole file: dimmed where silence or the cut removes audio.
private struct WaveformOverview: View {
    let info: SourceInfo
    let option: PlanOption?
    let request: CompressionRequest

    var body: some View {
        Canvas { gc, size in
            let levels = info.blockLevels
            guard !levels.isEmpty, info.frames > 0 else { return }
            let base = CompressionEngine.range(for: info, trimSilence: request.trimSilence)
            let kept = option.map {
                CompressionEngine.keptRange(info: info, request: request, keep: Int64($0.keptSeconds * info.sampleRate))
            } ?? base
            let columns = max(Int(size.width / 2), 1)
            let total = Double(info.frames)
            for x in 0..<columns {
                let lo = levels.count * x / columns
                let hi = max(levels.count * (x + 1) / columns, lo + 1)
                let level = levels[lo..<min(hi, levels.count)].max() ?? -100
                let height = max(CGFloat((Double(level) + 70) / 70), 0.02) * size.height
                let frame = Int64(Double(x) / Double(columns) * total)
                let color: Color = kept.contains(frame) ? .accentColor : base.contains(frame) ? .orange.opacity(0.35) : .secondary.opacity(0.3)
                let rect = CGRect(x: CGFloat(x) * 2, y: (size.height - height) / 2, width: 1.4, height: height)
                gc.fill(Path(rect), with: .color(color))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    static var legendRow: some View {
        HStack(spacing: 12) {
            legend(.accentColor, "Behålls")
            legend(.orange.opacity(0.5), "Klipps bort")
            legend(.secondary.opacity(0.4), "Tystnad")
        }
        .font(.caption2)
    }

    private static func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
