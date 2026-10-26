import AVFoundation

enum FileFormat: String, CaseIterable, Identifiable, Codable {
    case wav, aiff, caf, flac, alac, aac

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        case .flac: return "FLAC"
        case .alac: return "Apple Lossless"
        case .aac: return "AAC"
        }
    }

    var detail: String {
        switch self {
        case .wav: return "Okomprimerat · universellt studioformat"
        case .aiff: return "Okomprimerat · Apples studioformat"
        case .caf: return "Okomprimerat · inga storleksgränser"
        case .flac: return "Förlustfritt komprimerat · ~50–60 % mindre"
        case .alac: return "Förlustfritt komprimerat · .m4a"
        case .aac: return "Komprimerat med förlust · små filer"
        }
    }

    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf: return "caf"
        case .flac: return "flac"
        case .alac, .aac: return "m4a"
        }
    }

    var bitDepths: [BitDepth] {
        switch self {
        case .wav, .caf: return [.int16, .int24, .int32, .float32]
        case .aiff: return [.int16, .int24, .int32]
        case .flac, .alac: return [.int16, .int24]
        case .aac: return []
        }
    }

    var maxSampleRate: Double? { self == .aac ? 48_000 : nil }
}

enum BitDepth: String, CaseIterable, Identifiable, Codable {
    case int16, int24, int32, float32

    var id: String { rawValue }
    var bits: Int {
        switch self {
        case .int16: return 16
        case .int24: return 24
        case .int32, .float32: return 32
        }
    }
    var isFloat: Bool { self == .float32 }
    var label: String {
        switch self {
        case .int16: return "16-bit"
        case .int24: return "24-bit"
        case .int32: return "32-bit heltal"
        case .float32: return "32-bit flyttal"
        }
    }
    var shortLabel: String { self == .float32 ? "32f" : "\(bits)" }
}

enum ChannelMode: String, CaseIterable, Identifiable, Codable {
    case mono, stereo
    var id: String { rawValue }
    var label: String { self == .mono ? "Mono" : "Stereo" }
}

struct RecordingSettings: Codable, Equatable {
    var format: FileFormat = .wav
    var bitDepth: BitDepth = .int24
    var sampleRate: Double = 96_000
    var aacBitrate: Int = 256_000
    var channelMode: ChannelMode = .mono
    /// Zero-based first input channel (mono: the channel, stereo: left of the pair).
    var firstChannel: Int = 0
    var dither16: Bool = true
    /// Export-only: resample the file down to this rate (never up).
    var exportSampleRate: Double?

    var effectiveBitDepth: BitDepth {
        format.bitDepths.contains(bitDepth) ? bitDepth : (format.bitDepths.last ?? .int24)
    }

    var channelCount: Int { channelMode == .mono ? 1 : 2 }

    var aacBitrates: [Int] {
        channelMode == .mono ? [128_000, 192_000, 256_000] : [128_000, 192_000, 256_000, 320_000]
    }

    var effectiveAACBitrate: Int { min(aacBitrate, aacBitrates.last!) }

    func channelIndices(deviceChannels: Int) -> [Int] {
        let first = min(max(firstChannel, 0), max(deviceChannels - 1, 0))
        if channelMode == .mono || deviceChannels < 2 { return [first] }
        let left = min(first, deviceChannels - 2)
        return [left, left + 1]
    }

    func fileSampleRate(forInputRate rate: Double) -> Double {
        if let target = exportSampleRate, rate > target { return target }
        if let cap = format.maxSampleRate, rate > cap {
            return rate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000
        }
        return rate
    }

    func avSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        let depth = effectiveBitDepth
        switch format {
        case .wav, .aiff, .caf:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = depth.bits
            settings[AVLinearPCMIsFloatKey] = depth.isFloat
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = depth.bits
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = depth.bits
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = effectiveAACBitrate
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        }
        return settings
    }

    /// Whether TPDF dither should be added before reduction to 16-bit integer.
    var shouldDither: Bool { dither16 && format != .aac && effectiveBitDepth == .int16 }

    func summary(sampleRate: Double) -> String {
        let rate = Self.rateLabel(fileSampleRate(forInputRate: sampleRate))
        let quality = format == .aac ? "\(effectiveAACBitrate / 1000) kbit/s" : effectiveBitDepth.label
        return "\(format.label) · \(quality) · \(rate) · \(channelMode.label)"
    }

    static func rateLabel(_ rate: Double) -> String {
        let khz = rate / 1000
        return khz.rounded() == khz ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }
}
