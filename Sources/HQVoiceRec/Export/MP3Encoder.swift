import CLame
import Foundation

/// Constant-bitrate MP3 writer built on LAME. CBR keeps the size exactly predictable, and the
/// LAME "Info" frame at the start carries the frame count so the duration is readable from the
/// first bytes of the file (upload sites often inspect only those).
final class MP3Encoder {
    private let lame: lame_t
    private let handle: FileHandle
    private let channels: Int
    private var output = [UInt8](repeating: 0, count: 1 << 20)
    private var right = [Float]()
    private var left = [Float]()

    init(url: URL, inputSampleRate: Double, channels: Int, bitrate: Int) throws {
        guard let lame = lame_init() else { throw Self.error("Kunde inte starta MP3-kodaren.") }
        self.lame = lame
        self.channels = min(channels, 2)
        let outRate = inputSampleRate > 48_000
            ? (inputSampleRate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000) : inputSampleRate
        lame_set_in_samplerate(lame, Int32(inputSampleRate))
        lame_set_out_samplerate(lame, Int32(outRate))
        lame_set_num_channels(lame, Int32(self.channels))
        lame_set_mode(lame, self.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, Int32(bitrate / 1000))
        lame_set_quality(lame, 2)          // 0 = best/slowest, 2 = recommended high quality
        lame_set_bWriteVbrTag(lame, 1)
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw Self.error("MP3-kodaren accepterade inte inställningarna.")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            lame_close(lame)
            throw Self.error("Kunde inte skapa \(url.lastPathComponent).")
        }
        self.handle = handle
    }

    /// `samples` is interleaved with `channels` channels.
    func append(_ samples: UnsafePointer<Float>, frames: Int) throws {
        var offset = 0
        while offset < frames {
            let n = min(frames - offset, 65_536)
            let needed = n * 5 / 4 + 7200
            if output.count < needed { output = [UInt8](repeating: 0, count: needed) }
            let written: Int32
            if channels == 1 {
                written = output.withUnsafeMutableBufferPointer {
                    lame_encode_buffer_ieee_float(lame, samples + offset, samples + offset, Int32(n),
                                                  $0.baseAddress, Int32($0.count))
                }
            } else {
                written = output.withUnsafeMutableBufferPointer {
                    lame_encode_buffer_interleaved_ieee_float(lame, samples + offset * 2, Int32(n),
                                                              $0.baseAddress, Int32($0.count))
                }
            }
            guard written >= 0 else { throw Self.error("MP3-kodningen misslyckades (\(written)).") }
            try handle.write(contentsOf: output[0..<Int(written)])
            offset += n
        }
    }

    func finish() throws {
        let written = output.withUnsafeMutableBufferPointer {
            lame_encode_flush(lame, $0.baseAddress, Int32($0.count))
        }
        if written > 0 { try handle.write(contentsOf: output[0..<Int(written)]) }
        // Fill in the placeholder Info frame LAME wrote at offset 0 now that the frame count is known.
        let tagSize = output.withUnsafeMutableBufferPointer {
            lame_get_lametag_frame(lame, $0.baseAddress, $0.count)
        }
        if tagSize > 0 && tagSize <= output.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: output[0..<tagSize])
        }
        lame_close(lame)
        try handle.close()
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "HQVoiceRec.MP3", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
