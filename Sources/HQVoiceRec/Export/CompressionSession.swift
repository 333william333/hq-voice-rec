import Foundation
import Observation

/// State behind the "Skapa komprimerad kopia" sheet.
@MainActor
@Observable
final class CompressionSession: Identifiable {
    enum Phase {
        case analyzing(Double)
        case ready
        case exporting(Double)
        case finished(CompressionEngine.Result)
        case failed(String)
    }

    let id = UUID()
    let item: RecordingItem
    var phase: Phase = .analyzing(0)
    var info: SourceInfo?
    var variants: [ExportVariant] = []
    var rates: [String: SizeModel] = [:]

    var maxMB: Double { didSet { UserDefaults.standard.set(maxMB, forKey: "compressMaxMB") } }
    var trimSilence = true
    var balance: Double { didSet { UserDefaults.standard.set(balance, forKey: "compressBalance") } }
    /// 0 = keep the start, 1 = keep the end (when something has to be cut).
    var position = 0.0
    var fileType: FileTypeFilter {
        didSet {
            UserDefaults.standard.set(fileType.rawValue, forKey: "compressFileType")
            manualChoice = nil
        }
    }
    var limitLength: Bool { didSet { UserDefaults.standard.set(limitLength, forKey: "compressLimitLength") } }
    var maxMinutes: Double { didSet { UserDefaults.standard.set(maxMinutes, forKey: "compressMaxMinutes") } }
    /// Variant id picked by hand in the list; nil = automatic.
    var manualChoice: String?

    @ObservationIgnored private let cancelFlag = CancelFlag()
    @ObservationIgnored private var onFinished: ((URL) -> Void)?

    /// Length presets; a preset can also force a file type the target site accepts.
    static let lengthPresets: [(label: String, minutes: Double, fileType: FileTypeFilter?)] = [
        ("Higgsfield (3 min, MP3)", 3, .mp3),
        ("1 min", 1, nil), ("3 min", 3, nil), ("5 min", 5, nil), ("10 min", 10, nil), ("15 min", 15, nil),
    ]

    /// Length of the clip after silence trimming (before any cut).
    var totalSeconds: Double {
        guard let info else { return item.duration }
        return info.seconds(Int64(CompressionEngine.range(for: info, trimSilence: trimSilence).count))
    }

    static let presets: [(String, Double)] = [
        ("8 MB", 8), ("10 MB", 10), ("11 MB", 11), ("16 MB", 16), ("20 MB", 20), ("25 MB", 25), ("50 MB", 50),
    ]

    init(item: RecordingItem, onFinished: @escaping (URL) -> Void) {
        self.item = item
        self.onFinished = onFinished
        let defaults = UserDefaults.standard
        maxMB = defaults.object(forKey: "compressMaxMB") as? Double ?? 11
        balance = defaults.object(forKey: "compressBalance") as? Double ?? 0.5
        limitLength = defaults.bool(forKey: "compressLimitLength")
        fileType = defaults.string(forKey: "compressFileType").flatMap(FileTypeFilter.init) ?? .automatic
        maxMinutes = defaults.object(forKey: "compressMaxMinutes") as? Double ?? 3
    }

    var request: CompressionRequest {
        CompressionRequest(maxBytes: Int64(max(maxMB, 0.1) * 1_000_000), trimSilence: trimSilence,
                           balance: balance, position: position,
                           maxSeconds: limitLength ? max(maxMinutes, 0.1) * 60 : nil, fileType: fileType)
    }

    var options: [PlanOption] {
        guard let info else { return [] }
        return CompressionEngine.plan(info: info, variants: variants, rates: rates, request: request)
    }

    var automatic: PlanOption? { CompressionEngine.best(options) }

    var chosen: PlanOption? {
        if let manualChoice, let option = options.first(where: { $0.id == manualChoice }) { return option }
        return automatic
    }

    var isBusy: Bool {
        switch phase {
        case .analyzing, .exporting: return true
        default: return false
        }
    }

    // MARK: Actions

    func start() {
        let url = item.url
        let flag = cancelFlag
        Task.detached(priority: .userInitiated) { [weak self] in
            let throttle = ProgressThrottle()
            do {
                let info = try CompressionEngine.analyze(url: url, cancel: flag) { p in
                    if throttle.shouldReport(p) { Task { @MainActor in self?.phase = .analyzing(p * 0.4) } }
                }
                let variants = CompressionEngine.variants(for: info)
                let rates = try CompressionEngine.measureRates(info: info, variants: variants, cancel: flag) { p in
                    if throttle.shouldReport(p) { Task { @MainActor in self?.phase = .analyzing(0.4 + p * 0.6) } }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.info = info
                    self.variants = variants
                    self.rates = rates
                    self.phase = .ready
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func export() {
        guard let info, let option = chosen else { return }
        let request = request
        let destination = CompressionEngine.destinationURL(for: item.url, variant: option.variant,
                                                           maxBytes: request.maxBytes, maxSeconds: request.maxSeconds)
        let flag = cancelFlag
        phase = .exporting(0)
        Task.detached(priority: .userInitiated) { [weak self] in
            let throttle = ProgressThrottle()
            do {
                let result = try CompressionEngine.export(info: info, option: option, request: request,
                                                          destination: destination, cancel: flag) { p in
                    if throttle.shouldReport(p) { Task { @MainActor in self?.phase = .exporting(p) } }
                }
                await MainActor.run {
                    self?.phase = .finished(result)
                    self?.onFinished?(result.url)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
            } catch {
                await MainActor.run { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
    }
}

/// Limits progress updates to roughly every 1 %.
private final class ProgressThrottle: @unchecked Sendable {
    private var last = -1.0
    private let lock = NSLock()
    func shouldReport(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard value - last >= 0.01 || value >= 1 else { return false }
        last = value
        return true
    }
}
