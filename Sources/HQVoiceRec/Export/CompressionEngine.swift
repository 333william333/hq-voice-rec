import Accelerate
import AVFoundation
import os
import Synchronization

/// Everything the planner needs to know about a recording, gathered in one streaming pass.
struct SourceInfo: Sendable {
    let url: URL
    let frames: Int64
    let sampleRate: Double
    let channels: Int
    let fileSize: Int64
    let isLossless: Bool
    let sourceBits: Int
    let formatDescription: String
    /// RMS level (dBFS, loudest channel) per `blockFrames` block — drives silence trimming and the overview.
    let blockLevels: [Float]
    let blockFrames: Int
    /// Range left after cutting leading/trailing silence (with a little padding).
    let soundRange: Range<Int64>

    var duration: Double { Double(frames) / sampleRate }
    var hasSilenceToTrim: Bool { soundRange != 0..<frames }
    func seconds(_ frames: Int64) -> Double { Double(frames) / sampleRate }
}

struct ExportVariant: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case copy
        case flac(bits: Int, sampleRate: Double?)
        case wav(bits: Int, sampleRate: Double?)
        case mp3(bitrate: Int)
        case aac(bitrate: Int)
    }

    let id: String
    let kind: Kind
    let title: String
    let qualityLabel: String
    /// Perceived quality, 1 = bit-perfect.
    let quality: Double

    var isLossless: Bool {
        switch kind {
        case .aac, .mp3: return false
        default: return true
        }
    }

    var fileExtension: String {
        switch kind {
        case .copy: return ""
        case .flac: return "flac"
        case .wav: return "wav"
        case .mp3: return "mp3"
        case .aac: return "m4a"
        }
    }

    func settings(channels: Int) -> RecordingSettings {
        var s = RecordingSettings()
        s.channelMode = channels == 1 ? .mono : .stereo
        switch kind {
        case .copy, .mp3:
            break
        case let .flac(bits, rate):
            s.format = .flac
            s.bitDepth = bits == 16 ? .int16 : .int24
            s.exportSampleRate = rate
        case let .wav(bits, rate):
            s.format = .wav
            s.bitDepth = bits == 16 ? .int16 : .int24
            s.exportSampleRate = rate
        case let .aac(bitrate):
            s.format = .aac
            s.aacBitrate = bitrate
        }
        return s
    }

    func matches(_ filter: FileTypeFilter) -> Bool {
        switch (filter, kind) {
        case (.automatic, _), (.flac, .flac), (.wav, .wav), (.m4a, .aac), (.mp3, .mp3): return true
        default: return false
        }
    }
}

/// Lets the user force a file type the receiving site accepts.
enum FileTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case automatic, mp3, m4a, wav, flac
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatisk"
        case .mp3: return "MP3"
        case .m4a: return "M4A"
        case .wav: return "WAV"
        case .flac: return "FLAC"
        }
    }
}

/// File size model for one variant: `fixedBytes + bytesPerSecond × seconds`.
struct SizeModel: Sendable {
    var fixedBytes: Double
    var bytesPerSecond: Double
    func bytes(for seconds: Double) -> Double { fixedBytes + bytesPerSecond * seconds }
    func seconds(for bytes: Double) -> Double { (bytes - fixedBytes) / bytesPerSecond }
}

struct PlanOption: Identifiable, Sendable {
    let variant: ExportVariant
    let size: SizeModel
    /// Seconds of audio that fit in the budget (capped at the available length).
    let keptSeconds: Double
    let availableSeconds: Double
    let score: Double

    var id: String { variant.id }
    var keptFraction: Double { availableSeconds > 0 ? keptSeconds / availableSeconds : 0 }
    var isComplete: Bool { keptFraction >= 0.999 }
    var estimatedBytes: Double { size.bytes(for: keptSeconds) }
}

struct CompressionRequest: Sendable {
    var maxBytes: Int64
    var trimSilence: Bool
    /// 0 = keep the whole length (compress harder), 1 = keep the quality (cut more).
    var balance: Double
    /// Where the kept part sits when the clip has to be cut: 0 = start, 1 = end.
    var position: Double
    /// Hard limit on the length of the copy, e.g. 180 s for sites that accept at most 3 minutes.
    var maxSeconds: Double?
    var fileType: FileTypeFilter = .automatic

    /// What the planner aims for; the export then verifies against the hard `maxBytes`.
    var budget: Double { Double(maxBytes) * 0.985 - 16_384 }
}

final class CancelFlag: Sendable {
    private let flag = Atomic(false)
    var isCancelled: Bool { flag.load(ordering: .relaxed) }
    func cancel() { flag.store(true, ordering: .relaxed) }
}

enum CompressionEngine {
    struct Result: Sendable {
        let url: URL
        let bytes: Int64
        let seconds: Double
        let variant: ExportVariant
    }

    // MARK: Analysis

    static func analyze(url: URL, cancel: CancelFlag, progress: @Sendable (Double) -> Void) throws -> SourceInfo {
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat
        let asbd = format.streamDescription.pointee
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        let frames = file.length
        let size = fileSize(url)

        let lossless: Bool
        var bits = 16
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            lossless = true
            bits = Int(asbd.mBitsPerChannel)
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            lossless = true
            bits = [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)] ?? 24
        default:
            lossless = false
        }

        let blockFrames = max(Int(rate * 0.05), 256)
        let blocksPerRead = 40
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(blockFrames * blocksPerRead))!
        var levels: [Float] = []
        levels.reserveCapacity(Int(frames) / blockFrames + 1)
        var position: Int64 = 0
        while position < frames {
            if cancel.isCancelled { throw CancellationError() }
            try file.read(into: buffer)
            let got = Int(buffer.frameLength)
            guard got > 0 else { break }
            var offset = 0
            while offset < got {
                let n = min(blockFrames, got - offset)
                var loudest: Float = 0
                for c in 0..<channels {
                    var meanSquare: Float = 0
                    vDSP_measqv(buffer.floatChannelData![c] + offset, 1, &meanSquare, vDSP_Length(n))
                    loudest = max(loudest, meanSquare)
                }
                levels.append(10 * log10(max(loudest, 1e-14)))
                offset += n
            }
            position += Int64(got)
            progress(Double(position) / Double(max(frames, 1)))
        }

        return SourceInfo(url: url, frames: frames, sampleRate: rate, channels: channels, fileSize: size,
                          isLossless: lossless, sourceBits: bits,
                          formatDescription: describe(asbd: asbd, ext: url.pathExtension),
                          blockLevels: levels, blockFrames: blockFrames,
                          soundRange: soundRange(levels: levels, blockFrames: blockFrames, frames: frames, rate: rate))
    }

    /// Finds where the sound starts and ends: anything quieter than 40 dB below the loudest
    /// passage (and below −65 dBFS at worst) counts as silence, keeping 0.3 s of air on each side.
    static func soundRange(levels: [Float], blockFrames: Int, frames: Int64, rate: Double) -> Range<Int64> {
        guard let loudest = levels.max(), loudest > -90 else { return 0..<frames }
        let threshold = max(loudest - 40, -65)
        guard let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold }) else { return 0..<frames }
        let pad = Int64(rate * 0.3)
        let start = max(Int64(first * blockFrames) - pad, 0)
        let end = min(Int64((last + 1) * blockFrames) + pad, frames)
        return end > start ? start..<end : 0..<frames
    }

    static func range(for info: SourceInfo, trimSilence: Bool) -> Range<Int64> {
        trimSilence ? info.soundRange : 0..<info.frames
    }

    /// Frames the copy may contain: the (silence-trimmed) clip, capped by the length limit.
    /// The cap keeps 0.3 s in hand because AAC adds encoder priming to the reported duration.
    static func availableFrames(info: SourceInfo, request: CompressionRequest) -> Int64 {
        let base = Int64(range(for: info, trimSilence: request.trimSilence).count)
        guard let maxSeconds = request.maxSeconds else { return base }
        return min(base, Int64(max(maxSeconds - 0.3, 1) * info.sampleRate))
    }

    /// The part of the clip that is kept when only `keep` frames fit.
    static func keptRange(info: SourceInfo, request: CompressionRequest, keep: Int64) -> Range<Int64> {
        let base = range(for: info, trimSilence: request.trimSilence)
        let keep = min(max(keep, 0), Int64(base.count))
        let slack = Double(Int64(base.count) - keep)
        let start = base.lowerBound + Int64(slack * min(max(request.position, 0), 1))
        return start..<(start + keep)
    }

    // MARK: Candidates

    static func variants(for info: SourceInfo) -> [ExportVariant] {
        var list: [ExportVariant] = [
            ExportVariant(id: "copy", kind: .copy, title: "Oförändrad kopia (\(info.formatDescription))",
                          qualityLabel: "Originalet – exakt samma fil", quality: 1.0),
        ]
        let rate = info.sampleRate
        let rateLabel = RecordingSettings.rateLabel(rate)
        let downRate: Double? = rate > 48_000 ? (rate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000) : nil

        if info.isLossless {
            let bits = min(info.sourceBits, 24)
            list.append(ExportVariant(id: "flac\(bits)", kind: .flac(bits: bits, sampleRate: nil),
                                      title: "FLAC \(bits)-bit · \(rateLabel)",
                                      qualityLabel: "Förlustfritt – bitperfekt", quality: 1.0))
            if bits > 16 {
                list.append(ExportVariant(id: "flac16", kind: .flac(bits: 16, sampleRate: nil),
                                          title: "FLAC 16-bit · \(rateLabel)",
                                          qualityLabel: "Förlustfritt i 16-bit (96 dB dynamik)", quality: 0.98))
            }
            if let downRate {
                let label = RecordingSettings.rateLabel(downRate)
                list.append(ExportVariant(id: "flac16down", kind: .flac(bits: 16, sampleRate: downRate),
                                          title: "FLAC 16-bit · \(label)",
                                          qualityLabel: "Förlustfritt i CD-format – hela det hörbara området",
                                          quality: 0.96))
            }
            // Uncompressed, for sites that don't take FLAC. Listed after FLAC so equal quality prefers FLAC.
            list.append(ExportVariant(id: "wav\(bits)", kind: .wav(bits: bits, sampleRate: nil),
                                      title: "WAV \(bits)-bit · \(rateLabel)",
                                      qualityLabel: "Okomprimerat – bitperfekt", quality: 1.0))
            if bits > 16 {
                list.append(ExportVariant(id: "wav16", kind: .wav(bits: 16, sampleRate: nil),
                                          title: "WAV 16-bit · \(rateLabel)",
                                          qualityLabel: "Okomprimerat i 16-bit (96 dB dynamik)", quality: 0.98))
            }
            if let downRate {
                list.append(ExportVariant(id: "wav16down", kind: .wav(bits: 16, sampleRate: downRate),
                                          title: "WAV 16-bit · \(RecordingSettings.rateLabel(downRate))",
                                          qualityLabel: "Okomprimerat i CD-format", quality: 0.96))
            }
        }

        let ladder: [(Int, Double, String)] = info.channels > 1
            ? [(320, 0.93, "Transparent – ingen hörbar skillnad"), (256, 0.90, "Utmärkt"), (192, 0.86, "Mycket bra"),
               (160, 0.80, "Bra"), (128, 0.70, "Bra för tal"), (96, 0.55, "Godtagbart för tal"), (64, 0.40, "Hörbar förlust")]
            : [(256, 0.93, "Transparent – ingen hörbar skillnad"), (192, 0.90, "Utmärkt"), (160, 0.86, "Mycket bra"),
               (128, 0.80, "Bra"), (96, 0.70, "Bra för tal"), (64, 0.55, "Godtagbart för tal"),
               (48, 0.40, "Hörbar förlust"), (32, 0.25, "Tydlig förlust")]
        // Re-encoding a lossy file above its own bitrate only wastes space.
        let sourceKbps = info.duration > 0 ? Double(info.fileSize) * 8 / info.duration / 1000 : .infinity
        let aacRate = RecordingSettings.rateLabel(min(rate, downRate ?? rate))
        for (kbps, quality, label) in ladder where info.isLossless || Double(kbps) < sourceKbps * 0.95 {
            list.append(ExportVariant(id: "aac\(kbps)", kind: .aac(bitrate: kbps * 1000),
                                      title: "AAC \(kbps) kbit/s · \(aacRate)", qualityLabel: label, quality: quality))
        }
        // MP3 (CBR, LAME) for sites that only take MP3/WAV. Rated a notch below AAC at the same bitrate.
        let mp3Ladder: [(Int, Double, String)] = [
            (320, 0.91, "Utmärkt – i stort sett transparent"), (256, 0.88, "Utmärkt"), (192, 0.84, "Mycket bra"),
            (160, 0.78, "Bra"), (128, 0.70, "Bra för tal"), (96, 0.55, "Godtagbart för tal"), (64, 0.40, "Hörbar förlust"),
        ]
        for (kbps, quality, label) in mp3Ladder where info.isLossless || Double(kbps) < sourceKbps * 0.95 {
            list.append(ExportVariant(id: "mp3\(kbps)", kind: .mp3(bitrate: kbps * 1000),
                                      title: "MP3 \(kbps) kbit/s · \(aacRate)", qualityLabel: label, quality: quality))
        }
        return list
    }

    /// Size model for each candidate, measured on the actual audio: every format encodes a ≈60 s
    /// sample spread over the clip plus a 1 s piece, which separates the container's fixed overhead
    /// (≈60 kB for m4a) from the real bytes per second. Probes run in parallel.
    static func measureRates(info: SourceInfo, variants: [ExportVariant], cancel: CancelFlag,
                             progress: @escaping @Sendable (Double) -> Void) throws -> [String: SizeModel] {
        let sample = sampleRanges(in: info.soundRange, rate: info.sampleRate)
        let sampleSeconds = max(info.seconds(sample.reduce(0) { $0 + Int64($1.count) }), 0.001)
        let tinyFrames = min(Int64(info.sampleRate), Int64(info.soundRange.count) / 2)
        let tiny = info.soundRange.lowerBound..<(info.soundRange.lowerBound + tinyFrames)
        let tinySeconds = info.seconds(tinyFrames)
        let probes = variants.filter { if case .copy = $0.kind { return false } else { return true } }
        let jobs = probes.flatMap { [($0, sample), ($0, [tiny])] }

        struct Shared { var bytes: [String: [Double]] = [:]; var done = 0; var error: Error? }
        let shared = OSAllocatedUnfairLock(initialState: Shared())
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let (variant, ranges) = jobs[index]
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hqvr-measure-\(UUID().uuidString).\(variant.fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try encode(info: info, ranges: ranges, variant: variant,
                           to: url, fades: false, cancel: cancel) { _ in }
                let bytes = Double(fileSize(url))
                let done = shared.withLock { state -> Int in
                    state.bytes[variant.id + (index % 2 == 0 ? ".sample" : ".tiny")] = [bytes]
                    state.done += 1
                    return state.done
                }
                progress(Double(done) / Double(jobs.count))
            } catch {
                shared.withLock { $0.error = $0.error ?? error }
            }
        }
        let result = shared.withLock { $0 }
        if let error = result.error { throw error }

        var models: [String: SizeModel] = [:]
        for variant in variants {
            if case .copy = variant.kind {
                models[variant.id] = SizeModel(fixedBytes: 0, bytesPerSecond: Double(info.fileSize) / max(info.duration, 0.001))
                continue
            }
            let big = result.bytes[variant.id + ".sample"]?.first ?? 0
            let small = result.bytes[variant.id + ".tiny"]?.first ?? 0
            var perSecond = sampleSeconds > tinySeconds + 1 ? (big - small) / (sampleSeconds - tinySeconds) : big / sampleSeconds
            if perSecond <= 0 { perSecond = big / sampleSeconds }
            let fixed = max(small - perSecond * tinySeconds, 0)
            // 3 % margin on the rate: density varies a little between the sample and the whole clip.
            models[variant.id] = SizeModel(fixedBytes: fixed + 4096, bytesPerSecond: perSecond * 1.03)
        }
        return models
    }

    private static func sampleRanges(in range: Range<Int64>, rate: Double) -> [Range<Int64>] {
        let length = Int64(range.count)
        let window = Int64(rate * 10)
        guard length > window * 6 else { return [range] }
        let step = (length - window) / 5
        return (0..<6).map { i in
            let start = range.lowerBound + Int64(i) * step
            return start..<(start + window)
        }
    }

    // MARK: Planning

    /// Scores every candidate by `balance·quality + (1−balance)·share of the clip kept`.
    static func plan(info: SourceInfo, variants: [ExportVariant], rates: [String: SizeModel],
                     request: CompressionRequest) -> [PlanOption] {
        let available = info.seconds(availableFrames(info: info, request: request))
        let w = min(max(request.balance, 0), 1)
        return variants.compactMap { variant in
            guard variant.matches(request.fileType),
                  let size = rates[variant.id], size.bytesPerSecond > 0 else { return nil }
            if case .copy = variant.kind {
                // Only when the untouched file already fits and nothing is to be trimmed.
                guard Double(info.fileSize) <= Double(request.maxBytes),
                      !request.trimSilence || !info.hasSilenceToTrim,
                      request.maxSeconds.map({ info.duration <= $0 }) ?? true else { return nil }
                return PlanOption(variant: variant, size: size, keptSeconds: available,
                                  availableSeconds: available, score: w * 1.0 + (1 - w) + 0.001)
            }
            let kept = min(available, max(size.seconds(for: request.budget), 0))
            guard kept >= 1 else { return nil }
            let fraction = kept / available
            return PlanOption(variant: variant, size: size, keptSeconds: kept,
                              availableSeconds: available, score: w * variant.quality + (1 - w) * fraction)
        }
    }

    static func best(_ options: [PlanOption]) -> PlanOption? {
        // `max` keeps the first of equal scores; the list is ordered best quality first.
        options.reduce(nil) { current, option in
            guard let current else { return option }
            return option.score > current.score + 1e-9 ? option : current
        }
    }

    // MARK: Export

    /// Encodes `option`, then checks the real size and re-cuts until the file is under `maxBytes`
    /// (and, when the clip had to be shortened, as close to the limit as possible).
    static func export(info: SourceInfo, option: PlanOption, request: CompressionRequest, destination: URL,
                       cancel: CancelFlag, progress: @Sendable (Double) -> Void) throws -> Result {
        let fm = FileManager.default
        if case .copy = option.variant.kind {
            try fm.copyItem(at: info.url, to: destination)
            progress(1)
            return Result(url: destination, bytes: info.fileSize, seconds: info.duration, variant: option.variant)
        }

        let available = availableFrames(info: info, request: request)
        var keep = min(available, Int64(option.keptSeconds * info.sampleRate))
        let limit = Double(request.maxBytes)
        // The planner keeps a safety margin; with real files to measure we can aim right under the limit.
        let target = limit * 0.997
        let temp = fm.temporaryDirectory.appendingPathComponent("hqvr-export-\(UUID().uuidString).\(option.variant.fileExtension)")
        defer { try? fm.removeItem(at: temp) }

        var accepted: (bytes: Int64, keep: Int64)?
        for attempt in 0..<6 {
            let range = keptRange(info: info, request: request, keep: keep)
            try encode(info: info, ranges: [range], variant: option.variant, to: temp, fades: true, cancel: cancel) { p in
                progress(min((Double(attempt) + p) / Double(attempt + 1), 0.99))
            }
            let bytes = Int64(fileSize(temp))
            // Re-fit the size model to what this encode really produced.
            let fixed = min(option.size.fixedBytes, Double(bytes) * 0.5)
            let actualRate = max((Double(bytes) - fixed) / max(info.seconds(keep), 0.001), 1)
            let fitted = Int64((target - fixed) / actualRate * info.sampleRate)
            if Double(bytes) <= limit {
                if accepted == nil || keep > accepted!.keep {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.copyItem(at: temp, to: destination)
                    accepted = (bytes, keep)
                }
                // Good enough: everything kept, or within 1.5 % of the limit.
                if keep >= available || Double(bytes) >= target * 0.985 || attempt >= 4 { break }
                keep = min(available, max(fitted, keep + 1))
            } else {
                keep = min(fitted, Int64(Double(keep) * 0.98))
                guard keep > Int64(info.sampleRate) else { break }
            }
        }
        guard let accepted else {
            throw NSError(domain: "HQVoiceRec", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Det gick inte att få filen under \(ByteCountFormatter.string(fromByteCount: request.maxBytes, countStyle: .decimal))."])
        }
        progress(1)
        return Result(url: destination, bytes: accepted.bytes, seconds: info.seconds(accepted.keep), variant: option.variant)
    }

    static func encode(info: SourceInfo, ranges: [Range<Int64>], variant: ExportVariant, to url: URL,
                       fades: Bool, cancel: CancelFlag, progress: (Double) -> Void) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forReading: info.url)
        let channels = info.channels
        let writer: any AudioSink
        if case let .mp3(bitrate) = variant.kind {
            writer = try MP3Encoder(url: url, inputSampleRate: info.sampleRate, channels: channels, bitrate: bitrate)
        } else {
            writer = try RecordingWriter(url: url, settings: variant.settings(channels: channels),
                                         inputSampleRate: info.sampleRate, channels: channels)
        }
        let chunk = 32_768
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
        var interleaved = [Float](repeating: 0, count: chunk * channels)
        let indices = Array(0..<channels)

        let total = Double(ranges.reduce(0) { $0 + Int64($1.count) })
        var done: Int64 = 0
        let fadeFrames = Int64(info.sampleRate * 0.015)
        let first = ranges.first?.lowerBound ?? 0, last = ranges.last?.upperBound ?? 0
        let fadeIn = fades && first > 0, fadeOut = fades && last < info.frames

        for range in ranges {
            file.framePosition = range.lowerBound
            var position = range.lowerBound
            while position < range.upperBound {
                if cancel.isCancelled {
                    try? writer.finish()
                    throw CancellationError()
                }
                let n = AVAudioFrameCount(min(Int64(chunk), range.upperBound - position))
                try file.read(into: buffer, frameCount: n)
                let got = Int(buffer.frameLength)
                guard got > 0 else { break }
                let data = buffer.floatChannelData!
                for f in 0..<got {
                    let absolute = position + Int64(f)
                    var gain: Float = 1
                    if fadeIn, absolute - first < fadeFrames { gain = Float(absolute - first) / Float(fadeFrames) }
                    if fadeOut, last - absolute <= fadeFrames { gain = min(gain, Float(last - absolute - 1) / Float(fadeFrames)) }
                    for c in 0..<channels { interleaved[f * channels + c] = data[c][f] * gain }
                }
                try interleaved.withUnsafeBufferPointer {
                    try writer.append($0.baseAddress!, frames: got, deviceChannels: channels, channelIndices: indices)
                }
                position += Int64(got)
                done += Int64(got)
                progress(Double(done) / max(total, 1))
            }
        }
        try writer.finish()
    }

    // MARK: Helpers

    /// Reads the size from disk every time (URL resource values are cached per URL instance).
    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func describe(asbd: AudioStreamBasicDescription, ext: String) -> String {
        let rate = RecordingSettings.rateLabel(asbd.mSampleRate)
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return "\(ext.uppercased()) \(asbd.mBitsPerChannel)\(isFloat ? "f" : "")-bit · \(rate)"
        case kAudioFormatFLAC: return "FLAC · \(rate)"
        case kAudioFormatAppleLossless: return "ALAC · \(rate)"
        case kAudioFormatMPEG4AAC: return "AAC · \(rate)"
        default: return "\(ext.uppercased()) · \(rate)"
        }
    }

    static func destinationURL(for source: URL, variant: ExportVariant, maxBytes: Int64, maxSeconds: Double?) -> URL {
        let folder = source.deletingLastPathComponent()
        let ext = variant.fileExtension.isEmpty ? source.pathExtension : variant.fileExtension
        let mb = Double(maxBytes) / 1_000_000
        let limit = mb.rounded() == mb ? "\(Int(mb))" : String(format: "%.1f", mb)
        let length = maxSeconds.map { ", \(RecordingRow.duration($0))" } ?? ""
        let base = "\(source.deletingPathExtension().lastPathComponent) (max \(limit) MB\(length))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// Anything the exporter can stream interleaved float audio into.
protocol AudioSink {
    func append(_ source: UnsafePointer<Float>, frames: Int, deviceChannels: Int, channelIndices: [Int]) throws
    func finish() throws
}

extension RecordingWriter: AudioSink {}

extension MP3Encoder: AudioSink {
    func append(_ source: UnsafePointer<Float>, frames: Int, deviceChannels: Int, channelIndices: [Int]) throws {
        try append(source, frames: frames)
    }
}
