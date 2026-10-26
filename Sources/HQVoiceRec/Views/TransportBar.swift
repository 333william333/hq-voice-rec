import SwiftUI

struct TransportBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            LevelMeters()
                .frame(maxWidth: .infinity)
            RecordButton()
            RecordingInfo()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(height: 118)
        .background(.bar)
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            Button(action: model.toggleRecording) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 3.5)
                        .frame(width: 66, height: 66)
                    RoundedRectangle(cornerRadius: model.isRecording ? 7 : 27, style: .continuous)
                        .fill(Color.red.gradient)
                        .frame(width: model.isRecording ? 26 : 54, height: model.isRecording ? 26 : 54)
                        .shadow(color: .red.opacity(model.isRecording ? 0.6 : 0.25), radius: model.isRecording ? 8 : 3)
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.isRunning)
            .opacity(model.isRunning ? 1 : 0.4)
            .animation(.spring(duration: 0.35, bounce: 0.3), value: model.isRecording)
            .help(model.isRecording ? "Stoppa och spara (mellanslag)" : "Spela in (mellanslag)")
            .accessibilityLabel(model.isRecording ? "Stoppa inspelning" : "Starta inspelning")

            ElapsedTime()
        }
    }
}

struct ElapsedTime: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let snapshot = model.processor.snapshot()
            let seconds = model.isRecording && snapshot.recordingRate > 0
                ? Double(snapshot.recordedFrames) / snapshot.recordingRate : 0
            Text(Self.format(seconds))
                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(model.isRecording ? Color.red : Color.secondary)
        }
    }

    static func format(_ t: Double) -> String {
        let total = Int(t)
        let tenths = Int((t - Double(total)) * 10)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d.%d", h, m, s, tenths) : String(format: "%02d:%02d.%d", m, s, tenths)
    }
}

struct RecordingInfo: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            let rate = model.activeSampleRate > 0 ? model.activeSampleRate : model.settings.sampleRate
            Text(model.settings.summary(sampleRate: rate))
                .font(.callout.weight(.medium))
            channelText
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.isRecording, let url = model.currentRecordingURL {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    Label("\(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                          systemImage: "record.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let saved = model.savedMessage {
                Label(saved, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Label("Sparas automatiskt i \(model.folderDisplayName)", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DroppedWarning()
        }
    }

    private var channelText: Text {
        let indices = model.settings.channelIndices(deviceChannels: max(model.activeChannels, 1))
        let channels = indices.map { "\($0 + 1)" }.joined(separator: "+")
        let perMinute = ByteCountFormatter.string(fromByteCount: Int64(model.bytesPerMinute), countStyle: .file)
        return Text("Ingång \(channels) · ≈ \(perMinute)/min")
    }
}

struct DroppedWarning: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let dropped = model.processor.snapshot().dropped
            if dropped > 0 {
                Label("Ljudbortfall upptäckt", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
