import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            RecordingsSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
        } detail: {
            RecorderView()
                .inspector(isPresented: $model.showInspector) {
                    SettingsInspector()
                        .inspectorColumnWidth(min: 280, ideal: 310, max: 400)
                }
        }
        .navigationTitle("HQ Voice Rec")
        .navigationSubtitle(model.statusLine)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(selection: $model.selectedDeviceUID) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                } label: {
                    Label("Ingång", systemImage: "mic")
                }
                .pickerStyle(.menu)
                .frame(minWidth: 200)
                .disabled(model.isRecording)
                .help("Välj ingångsenhet")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inställningar", systemImage: "sidebar.right")
                }
                .help("Visa/dölj inställningar")
            }
        }
        .task { await model.bootstrap() }
        .onOpenURL { model.handle($0) }
        .sheet(item: $model.compressionSession) { session in
            CompressSheet(session: session)
                .environment(model)
        }
        .alert("Något gick fel", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct RecorderView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.micPermission == .denied || model.micPermission == .restricted {
                PermissionBanner()
            }
            SpectrumCanvas()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
                .padding([.horizontal, .top], 14)
                .padding(.bottom, 10)
            Divider()
            TransportBar()
        }
        .background(.background)
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mikrofonåtkomst saknas").font(.headline)
                Text("Ge HQ Voice Rec tillgång till mikrofonen i Systeminställningar och starta om appen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Öppna Systeminställningar") { model.openMicrophoneSettings() }
        }
        .padding(14)
        .background(.orange.opacity(0.12))
    }
}
