import SwiftUI

struct SettingsInspector: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Ingång") {
                Picker("Enhet", selection: $model.selectedDeviceUID) {
                    ForEach(model.devices) { device in
                        Text(device.name).tag(Optional(device.uid))
                    }
                }
                if let device = model.selectedDevice {
                    LabeledContent("Hårdvara") {
                        Text("\(device.transport) · \(model.activeChannels) \(model.activeChannels == 1 ? "kanal" : "kanaler")")
                    }
                }
                Picker("Kanaler", selection: $model.settings.channelMode) {
                    ForEach(ChannelMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.activeChannels < 2)

                Picker(model.settings.channelMode == .mono ? "Mikrofon på ingång" : "Kanalpar",
                       selection: $model.settings.firstChannel) {
                    if model.settings.channelMode == .mono {
                        ForEach(0..<max(model.activeChannels, 1), id: \.self) { i in
                            Text("Ingång \(i + 1)").tag(i)
                        }
                    } else {
                        ForEach(Array(stride(from: 0, to: max(model.activeChannels - 1, 1), by: 2)), id: \.self) { i in
                            Text("\(i + 1)–\(i + 2)").tag(i)
                        }
                    }
                }
                .disabled(model.activeChannels < 2)

                if let volume = model.inputVolume {
                    LabeledContent("Förstärkning") {
                        HStack {
                            Slider(value: Binding(get: { Double(volume) },
                                                  set: { model.setInputVolume(Float($0)) }), in: 0...1)
                            Text("\(Int(volume * 100)) %")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
            }
            .disabled(model.isRecording)

            Section {
                Picker("Filformat", selection: $model.settings.format) {
                    ForEach(FileFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                Picker("Samplingsfrekvens", selection: $model.settings.sampleRate) {
                    ForEach(model.selectedDevice?.sampleRates ?? [model.settings.sampleRate], id: \.self) { rate in
                        Text(RecordingSettings.rateLabel(rate)).tag(rate)
                    }
                }
                if model.settings.format == .aac {
                    Picker("Bithastighet", selection: $model.settings.aacBitrate) {
                        ForEach(model.settings.aacBitrates, id: \.self) { rate in
                            Text("\(rate / 1000) kbit/s").tag(rate)
                        }
                    }
                } else {
                    Picker("Bitdjup", selection: $model.settings.bitDepth) {
                        ForEach(model.settings.format.bitDepths) { depth in
                            Text(depth.label).tag(depth)
                        }
                    }
                    if model.settings.effectiveBitDepth == .int16 {
                        Toggle("TPDF-dither", isOn: $model.settings.dither16)
                    }
                }
                LabeledContent("Datamängd") {
                    Text("≈ \(ByteCountFormatter.string(fromByteCount: Int64(model.bytesPerMinute * 60), countStyle: .file)) per timme")
                }
            } header: {
                Text("Format och kvalitet")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.settings.format.detail)
                    if model.settings.format == .aac && model.activeSampleRate > 48_000 {
                        Text("AAC sparas i högst 48 kHz – ljudet konverteras med mastering-kvalitet.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(model.isRecording)

            Section("Analysator") {
                Picker("FFT-storlek", selection: $model.analyzer.fftSize) {
                    ForEach(AnalyzerSettings.fftSizes, id: \.self) { size in
                        Text("\(size) · \(String(format: "%.1f", (model.activeSampleRate > 0 ? model.activeSampleRate : 48_000) / Double(size))) Hz").tag(size)
                    }
                }
                LabeledContent("Utjämning") {
                    Slider(value: $model.analyzer.smoothing, in: 0...0.95)
                }
                LabeledContent("Golv") {
                    HStack {
                        Slider(value: $model.analyzer.floorDB, in: -160...(-60), step: 10)
                        Text("\(Int(model.analyzer.floorDB)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Spektrogram min") {
                    HStack {
                        Slider(value: $model.analyzer.waterfallFloor, in: -160...(-40), step: 5)
                        Text("\(Int(model.analyzer.waterfallFloor)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                LabeledContent("Spektrogram max") {
                    HStack {
                        Slider(value: $model.analyzer.waterfallCeiling, in: -80...0, step: 5)
                        Text("\(Int(model.analyzer.waterfallCeiling)) dB").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Topphållning", isOn: $model.analyzer.showPeakHold)
            }

            Section {
                LabeledContent("Mapp") {
                    Text((model.recordingsFolder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Visa i Finder") { model.revealInFinder() }
            } header: {
                Text("Lagring")
            } footer: {
                Text("Ljudet skrivs direkt till disk medan du spelar in och filen stängs och sparas automatiskt när du stoppar – även om du avslutar appen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Utseende") {
                Picker("Tema", selection: $model.appearance) {
                    Text("System").tag("system")
                    Text("Ljust").tag("light")
                    Text("Mörkt").tag("dark")
                }
                .pickerStyle(.segmented)
            }

            Section("Tips för dynamisk mikrofon") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Ställ in gain på ljudkortet så att topparna landar runt −12 till −6 dBFS.", systemImage: "dial.medium")
                    Label("24-bit ger 144 dB dynamik – du behöver inte spela in nära 0 dB.", systemImage: "waveform.path.ecg")
                    Label("Ingen AGC, brusreducering eller röstbearbetning används – du får råsignalen.", systemImage: "checkmark.seal")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
