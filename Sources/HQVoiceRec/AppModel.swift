import AppKit
import AVFoundation
import CoreAudio
import Observation

struct RecordingItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let name: String
    let date: Date
    let duration: TimeInterval
    let size: Int64
    let formatDescription: String
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let processor = AudioProcessor()
    let recordingsFolder: URL

    var devices: [AudioInputDevice] = []
    var selectedDeviceUID: String? {
        didSet {
            guard selectedDeviceUID != oldValue else { return }
            UserDefaults.standard.set(selectedDeviceUID, forKey: Keys.device)
            if !suppressRestart { restartCapture() }
        }
    }
    var settings: RecordingSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    var analyzer: AnalyzerSettings {
        didSet {
            processor.setAnalyzer(analyzer)
            Self.save(analyzer, key: Keys.analyzer)
        }
    }

    var activeSampleRate: Double = 0
    var activeChannels: Int = 0
    var isRunning = false
    var isRecording = false
    var currentRecordingURL: URL?
    var recordingStartedAt: Date?
    var recordings: [RecordingItem] = []
    var selectedRecording: URL?
    var playingURL: URL?
    var errorMessage: String?
    var savedMessage: String?
    var micPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    var inputVolume: Float?
    var showInspector = true
    /// "system", "light" or "dark".
    var appearance: String {
        didSet {
            UserDefaults.standard.set(appearance, forKey: "appearance")
            applyAppearance()
        }
    }
    var compressionSession: CompressionSession?
    /// Mouse position over the analyzer; the canvas redraws every frame anyway, so no observation needed.
    @ObservationIgnored var analyzerHover: CGPoint?

    /// "Dokument › Recordings" for the default folder, otherwise the folder's own name.
    var folderDisplayName: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if recordingsFolder.standardizedFileURL == documents.appendingPathComponent("Recordings").standardizedFileURL {
            return "Dokument › Recordings"
        }
        return recordingsFolder.lastPathComponent
    }

    var selectedDevice: AudioInputDevice? { devices.first { $0.uid == selectedDeviceUID } }

    @ObservationIgnored private var suppressRestart = false
    @ObservationIgnored private var volumeElements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let playerDelegate = PlayerDelegate()
    @ObservationIgnored private var devicesListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var rateListener: (AudioDeviceID, AudioObjectPropertyListenerBlock)?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var bootstrapped = false

    private enum Keys {
        static let device = "inputDeviceUID"
        static let settings = "recordingSettings"
        static let analyzer = "analyzerSettings"
    }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // `-RecordingsFolder <path>` (launch argument or `defaults write`) overrides the default folder.
        if let custom = UserDefaults.standard.string(forKey: "RecordingsFolder"), !custom.isEmpty {
            recordingsFolder = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            recordingsFolder = documents.appendingPathComponent("Recordings", isDirectory: true)
        }
        settings = Self.load(RecordingSettings.self, key: Keys.settings) ?? RecordingSettings()
        analyzer = Self.load(AnalyzerSettings.self, key: Keys.analyzer) ?? AnalyzerSettings()
        selectedDeviceUID = UserDefaults.standard.string(forKey: Keys.device)
        appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        processor.setAnalyzer(analyzer)
        playerDelegate.onFinish = { [weak self] in Task { @MainActor in self?.playingURL = nil } }
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        applyAppearance()
        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        refreshRecordings()
        refreshDevices()
        devicesListener = HAL.observe(AudioObjectID(kAudioObjectSystemObject),
                                      HAL.address(kAudioHardwarePropertyDevices)) { [weak self] in
            MainActor.assumeIsolated { self?.devicesChanged() }
        }

        if micPermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        if micPermission == .authorized { restartCapture() }
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// `hqvoicerec://record`, `stop`, `toggle` or `compress` (opens the compress sheet for the
    /// selected, or else newest, recording) — for Shortcuts, Stream Deck and similar.
    func handle(_ url: URL) {
        guard url.scheme == "hqvoicerec" else { return }
        switch url.host?.lowercased() {
        case "record": startRecording()
        case "stop": stopRecording()
        case "toggle": toggleRecording()
        case "compress":
            if let item = recordings.first(where: { $0.url == selectedRecording }) ?? recordings.first {
                selectedRecording = item.url
                makeCompressedCopy(of: item)
            }
        default: break
        }
    }

    func shutdown() {
        stopRecording()
        processor.stop()
    }

    // MARK: Devices

    func refreshDevices() {
        devices = HAL.inputDevices().sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if selectedDevice == nil {
            suppressRestart = true
            selectedDeviceUID = (devices.first { $0.isDefault } ?? devices.first)?.uid
            suppressRestart = false
        }
    }

    private func devicesChanged() {
        let previous = selectedDeviceUID
        let wasPresent = selectedDevice != nil
        refreshDevices()
        if wasPresent && selectedDevice == nil || previous != selectedDeviceUID {
            if isRecording {
                stopRecording()
                errorMessage = "Ingångsenheten kopplades bort – inspelningen stoppades och sparades."
            }
            restartCapture()
        }
    }

    func restartCapture() {
        guard micPermission == .authorized, !isRecording else { return }
        guard let device = selectedDevice ?? devices.first else {
            processor.stop()
            isRunning = false
            errorMessage = "Ingen ingångsenhet hittades."
            return
        }
        do {
            let result = try processor.start(deviceID: device.id, preferredSampleRate: preferredRate(for: device))
            activeSampleRate = result.sampleRate
            activeChannels = result.channels
            isRunning = true
            errorMessage = nil
            if settings.firstChannel >= result.channels { settings.firstChannel = 0 }
            if result.channels < 2 && settings.channelMode == .stereo { settings.channelMode = .mono }
            if !device.sampleRates.contains(settings.sampleRate) {
                suppressRestart = true
                settings.sampleRate = result.sampleRate
                suppressRestart = false
            }
            processor.setChannels(settings.channelIndices(deviceChannels: result.channels))
            observeSampleRate(of: device.id)
            volumeElements = HAL.inputVolumeElements(device.id, channels: result.channels)
            inputVolume = HAL.inputVolume(device.id, elements: volumeElements)
        } catch {
            isRunning = false
            errorMessage = "Kunde inte starta \(device.name): \(error.localizedDescription)"
        }
    }

    private func preferredRate(for device: AudioInputDevice) -> Double? {
        let rates = device.sampleRates
        if rates.contains(settings.sampleRate) { return settings.sampleRate }
        return rates.last { $0 <= settings.sampleRate } ?? rates.max()
    }

    private func observeSampleRate(of id: AudioDeviceID) {
        if let (old, block) = rateListener {
            HAL.removeObserver(old, HAL.address(kAudioDevicePropertyNominalSampleRate), block)
        }
        rateListener = nil
        if let block = HAL.observe(id, HAL.address(kAudioDevicePropertyNominalSampleRate), { [weak self] in
            MainActor.assumeIsolated {
                guard let self, abs(HAL.nominalSampleRate(id) - self.activeSampleRate) > 0.5 else { return }
                if self.isRecording {
                    self.stopRecording()
                    self.errorMessage = "Enhetens samplingsfrekvens ändrades utifrån – inspelningen stoppades och sparades."
                }
                self.restartCapture()
            }
        }) {
            rateListener = (id, block)
        }
    }

    func setInputVolume(_ value: Float) {
        guard let device = selectedDevice else { return }
        HAL.setInputVolume(device.id, elements: volumeElements, value)
        inputVolume = value
    }

    // MARK: Settings

    private func settingsDidChange(from old: RecordingSettings) {
        if !settings.format.bitDepths.isEmpty && !settings.format.bitDepths.contains(settings.bitDepth) {
            settings.bitDepth = settings.effectiveBitDepth
            return
        }
        Self.save(settings, key: Keys.settings)
        if settings.sampleRate != old.sampleRate && !suppressRestart {
            restartCapture()
        } else if settings.channelMode != old.channelMode || settings.firstChannel != old.firstChannel {
            processor.setChannels(settings.channelIndices(deviceChannels: activeChannels))
        }
    }

    var statusLine: String {
        guard isRunning, let device = selectedDevice else { return "Ingen aktiv ingång" }
        return "\(device.name) · \(RecordingSettings.rateLabel(activeSampleRate))"
    }

    /// Approximate bytes per minute for the current settings.
    var bytesPerMinute: Double {
        let rate = settings.fileSampleRate(forInputRate: activeSampleRate > 0 ? activeSampleRate : settings.sampleRate)
        let channels = Double(settings.channelCount)
        let pcm = rate * Double(settings.effectiveBitDepth.bits) / 8 * channels * 60
        switch settings.format {
        case .wav, .aiff, .caf: return pcm
        case .flac, .alac: return pcm * 0.55
        case .aac: return Double(settings.effectiveAACBitrate) / 8 * 60
        }
    }

    // MARK: Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard isRunning, !isRecording else { return }
        stopPlayback()
        try? FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let url = nextRecordingURL()
        do {
            try processor.startRecording(url: url, settings: settings)
            currentRecordingURL = url
            recordingStartedAt = Date()
            isRecording = true
            savedMessage = nil
            startWatchdog()
        } catch {
            errorMessage = "Kunde inte skapa inspelningsfilen: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        watchdog?.invalidate()
        watchdog = nil
        let url = processor.stopRecording()
        isRecording = false
        currentRecordingURL = nil
        recordingStartedAt = nil
        refreshRecordings(select: url)
        if let url { savedMessage = "Sparad som \(url.lastPathComponent)" }
    }

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                if let error = self.processor.snapshot().writeError {
                    self.stopRecording()
                    self.errorMessage = "Skrivfel – inspelningen stoppades: \(error)"
                }
            }
        }
    }

    private func nextRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sv_SE")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Inspelning \(formatter.string(from: Date()))"
        let ext = settings.format.fileExtension
        var url = recordingsFolder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = recordingsFolder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: Library

    nonisolated static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "flac", "m4a", "mp3"]

    func refreshRecordings(select: URL? = nil) {
        let folder = recordingsFolder
        let exclude = currentRecordingURL
        Task.detached(priority: .userInitiated) {
            let items = Self.scan(folder: folder, excluding: exclude)
            await MainActor.run {
                self.recordings = items
                if let select { self.selectedRecording = select }
            }
        }
    }

    nonisolated private static func scan(folder: URL, excluding: URL?) -> [RecordingItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) && $0 != excluding }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                var duration: TimeInterval = 0
                var description = url.pathExtension.uppercased()
                if let file = try? AVAudioFile(forReading: url) {
                    let format = file.fileFormat
                    duration = Double(file.length) / format.sampleRate
                    description = describe(format: format, ext: url.pathExtension)
                }
                return RecordingItem(url: url, name: url.deletingPathExtension().lastPathComponent,
                                     date: values?.creationDate ?? .distantPast, duration: duration,
                                     size: Int64(values?.fileSize ?? 0), formatDescription: description)
            }
            .sorted { $0.date > $1.date }
    }

    nonisolated private static func describe(format: AVAudioFormat, ext: String) -> String {
        let asbd = format.streamDescription.pointee
        var parts: [String] = []
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            parts.append(ext.uppercased())
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            parts.append(isFloat ? "\(asbd.mBitsPerChannel)-bit float" : "\(asbd.mBitsPerChannel)-bit")
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            parts.append(asbd.mFormatID == kAudioFormatFLAC ? "FLAC" : "ALAC")
            let bits = [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)]
            if let bits { parts.append("\(bits)-bit") }
        case kAudioFormatMPEG4AAC:
            parts.append("AAC")
        default:
            parts.append(ext.uppercased())
        }
        parts.append(RecordingSettings.rateLabel(asbd.mSampleRate))
        parts.append(asbd.mChannelsPerFrame == 1 ? "Mono" : asbd.mChannelsPerFrame == 2 ? "Stereo" : "\(asbd.mChannelsPerFrame) kan.")
        return parts.joined(separator: " · ")
    }

    func togglePlayback(_ url: URL) {
        if playingURL == url {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = playerDelegate
            player.play()
            self.player = player
            playingURL = url
        } catch {
            errorMessage = "Kunde inte spela upp filen: \(error.localizedDescription)"
        }
    }

    func makeCompressedCopy(of item: RecordingItem) {
        compressionSession = CompressionSession(item: item) { [weak self] url in
            self?.refreshRecordings(select: url)
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    func revealInFinder(_ url: URL? = nil) {
        if let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(recordingsFolder)
        }
    }

    func moveToTrash(_ url: URL) {
        if playingURL == url { stopPlayback() }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if selectedRecording == url { selectedRecording = nil }
            refreshRecordings()
        } catch {
            errorMessage = "Kunde inte flytta till papperskorgen: \(error.localizedDescription)"
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Persistence

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
}
