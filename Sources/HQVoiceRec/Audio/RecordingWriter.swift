import AVFoundation

/// Streams captured audio to disk. Lives on the processing queue.
final class RecordingWriter {
    let url: URL
    let inputSampleRate: Double
    private(set) var framesWritten: Int64 = 0

    private let file: AVAudioFile
    private let channels: Int
    private let chunk = 16_384
    private let inBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let outBuffer: AVAudioPCMBuffer?
    private let dither: Bool
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(url: URL, settings: RecordingSettings, inputSampleRate: Double, channels: Int) throws {
        self.url = url
        self.inputSampleRate = inputSampleRate
        self.channels = channels
        self.dither = settings.shouldDither
        let fileRate = settings.fileSampleRate(forInputRate: inputSampleRate)
        file = try AVAudioFile(forWriting: url,
                               settings: settings.avSettings(sampleRate: fileRate, channels: channels),
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate,
                                        channels: AVAudioChannelCount(channels), interleaved: false)!
        inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk))!

        if abs(file.processingFormat.sampleRate - inputSampleRate) > 0.5,
           let converter = AVAudioConverter(from: inputFormat, to: file.processingFormat) {
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            self.converter = converter
            let ratio = file.processingFormat.sampleRate / inputSampleRate
            outBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(Double(chunk) * ratio) + 4096)
        } else {
            converter = nil
            outBuffer = nil
        }
    }

    /// `source` is interleaved with `deviceChannels` channels; `channelIndices` picks what is recorded.
    func append(_ source: UnsafePointer<Float>, frames: Int, deviceChannels: Int, channelIndices: [Int]) throws {
        var offset = 0
        while offset < frames {
            let n = min(chunk, frames - offset)
            let data = inBuffer.floatChannelData!
            for (i, channel) in channelIndices.prefix(channels).enumerated() {
                let destination = data[i]
                var s = source + offset * deviceChannels + channel
                for f in 0..<n {
                    destination[f] = s.pointee
                    s += deviceChannels
                }
                if dither { addTPDF(destination, count: n) }
            }
            inBuffer.frameLength = AVAudioFrameCount(n)
            try write(inBuffer)
            framesWritten += Int64(n)
            offset += n
        }
    }

    func finish() {
        if let converter, let outBuffer {
            var error: NSError?
            for _ in 0..<16 {
                outBuffer.frameLength = 0
                let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if outBuffer.frameLength > 0 { try? file.write(from: outBuffer) }
                if status != .haveData { break }
            }
        }
        file.close()
        if url.pathExtension.lowercased() == "m4a" { try? FastStart.apply(to: url) }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let converter, let outBuffer else {
            try file.write(from: buffer)
            return
        }
        var provided = false
        var error: NSError?
        outBuffer.frameLength = 0
        _ = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        if outBuffer.frameLength > 0 { try file.write(from: outBuffer) }
    }

    /// Triangular-PDF dither of ±1 LSB at 16-bit.
    private func addTPDF(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        let scale: Float = 1.0 / 32_768.0 / Float(UInt32.max)
        for i in 0..<count {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            let a = Float(UInt32(truncatingIfNeeded: rng))
            let b = Float(UInt32(truncatingIfNeeded: rng >> 32))
            samples[i] += (a - b) * scale
        }
    }
}
