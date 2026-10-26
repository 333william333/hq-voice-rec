import SwiftUI

struct RecordingsSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedRecording) {
            if model.isRecording, let url = model.currentRecordingURL {
                Section("Pågår") {
                    LiveRecordingRow(url: url)
                }
            }
            Section("Inspelningar") {
                ForEach(model.recordings) { item in
                    RecordingRow(item: item)
                        .tag(item.url)
                        .contextMenu {
                            Button(model.playingURL == item.url ? "Stoppa uppspelning" : "Spela upp") {
                                model.togglePlayback(item.url)
                            }
                            Button("Skapa komprimerad kopia…") { model.makeCompressedCopy(of: item) }
                            Button("Visa i Finder") { model.revealInFinder(item.url) }
                            Divider()
                            Button("Flytta till papperskorgen", role: .destructive) { model.moveToTrash(item.url) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if let url = model.selectedRecording { model.moveToTrash(url) }
        }
        .overlay {
            if model.recordings.isEmpty && !model.isRecording {
                ContentUnavailableView("Inga inspelningar",
                                       systemImage: "waveform",
                                       description: Text("Tryck på den röda knappen eller mellanslag för att börja spela in."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.revealInFinder()
            } label: {
                Label(model.folderDisplayName, systemImage: "folder")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .help("Öppna inspelningsmappen i Finder")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.refreshRecordings()
                } label: {
                    Label("Uppdatera", systemImage: "arrow.clockwise")
                }
                .help("Läs in mappen igen")
            }
        }
    }
}

struct RecordingRow: View {
    @Environment(AppModel.self) private var model
    let item: RecordingItem

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback(item.url)
            } label: {
                Image(systemName: model.playingURL == item.url ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(model.playingURL == item.url ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(model.playingURL == item.url ? "Stoppa" : "Spela upp")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.duration(item.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(item.formatDescription) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    static func duration(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LiveRecordingRow: View {
    @Environment(AppModel.self) private var model
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let s = model.processor.snapshot()
                    Text("Spelar in · \(RecordingRow.duration(s.recordingRate > 0 ? Double(s.recordedFrames) / s.recordingRate : 0))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
