import AudioToolbox
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case noComponent

    var errorDescription: String? {
        switch self {
        case .noComponent: return "Hittade ingen CoreAudio-ingångsenhet (AUHAL)."
        case let .osStatus(step, status): return "CoreAudio-fel vid \(step) (\(status))."
        }
    }
}

/// Raw, unprocessed capture straight from the hardware through an AUHAL unit.
/// No voice processing, no AGC, no resampling: the device's native samples as 32-bit float.
final class AudioCapture {
    let deviceID: AudioDeviceID
    let sampleRate: Double
    let channels: Int
    let ring: RingBuffer

    private var unit: AudioUnit?
    private let maxFrames = 8192
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let channelBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let interleaved: UnsafeMutablePointer<Float>

    init(deviceID: AudioDeviceID, preferredSampleRate: Double?) throws {
        if let rate = preferredSampleRate { HAL.setNominalSampleRate(deviceID, rate) }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw CaptureError.noComponent }
        var maybeUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &maybeUnit), "skapa ljudenhet")
        guard let unit = maybeUnit else { throw CaptureError.noComponent }
        var configured = false
        defer { if !configured { AudioComponentInstanceDispose(unit) } }

        var enable: UInt32 = 1, disable: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, u32), "aktivera ingång")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, u32), "stänga av utgång")
        var device = deviceID
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                            &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "välja enhet")

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "läsa enhetsformat")
        let channels = Int(hardware.mChannelsPerFrame)
        guard channels > 0, hardware.mSampleRate > 0 else { throw CaptureError.osStatus("enhetsformat", -1) }

        var client = AudioStreamBasicDescription(
            mSampleRate: hardware.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "sätta klientformat")
        var maxSlice = UInt32(maxFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxSlice, u32)

        self.deviceID = deviceID
        self.sampleRate = hardware.mSampleRate
        self.channels = channels
        self.unit = unit
        // ~4 s of headroom so a stalled UI never costs samples.
        self.ring = RingBuffer(capacity: channels * Int(hardware.mSampleRate) * 4)
        self.bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        self.channelBuffers = .allocate(capacity: channels)
        for c in 0..<channels {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
            buffer.initialize(repeating: 0, count: maxFrames)
            channelBuffers[c] = buffer
        }
        self.interleaved = .allocate(capacity: maxFrames * channels)

        var callback = AURenderCallbackStruct(inputProc: captureInputProc,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "registrera callback")
        try Self.check(AudioUnitInitialize(unit), "initiera")
        configured = true
    }

    deinit {
        stop()
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        for c in 0..<channels { channelBuffers[c].deallocate() }
        channelBuffers.deallocate()
        interleaved.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    func start() throws {
        guard let unit else { return }
        try Self.check(AudioOutputUnitStart(unit), "starta inspelning")
    }

    func stop() {
        if let unit { AudioOutputUnitStop(unit) }
    }

    /// Called on the real-time I/O thread.
    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timeStamp: UnsafePointer<AudioTimeStamp>,
                            _ bus: UInt32, _ frameCount: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let frames = min(Int(frameCount), maxFrames)
        for c in 0..<channels {
            bufferList[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                        mData: UnsafeMutableRawPointer(channelBuffers[c]))
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, UInt32(frames), bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        if channels == 1 {
            ring.write(channelBuffers[0], count: frames)
        } else {
            for c in 0..<channels {
                let source = channelBuffers[c]
                var destination = interleaved + c
                for f in 0..<frames {
                    destination.pointee = source[f]
                    destination += channels
                }
            }
            ring.write(interleaved, count: frames * channels)
        }
        return noErr
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw CaptureError.osStatus(step, status) }
    }
}

private func captureInputProc(inRefCon: UnsafeMutableRawPointer,
                              ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              inTimeStamp: UnsafePointer<AudioTimeStamp>,
                              inBusNumber: UInt32,
                              inNumberFrames: UInt32,
                              ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let capture = Unmanaged<AudioCapture>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}
