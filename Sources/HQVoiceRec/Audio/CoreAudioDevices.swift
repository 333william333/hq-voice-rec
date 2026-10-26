import CoreAudio
import Foundation

/// An audio device that has at least one input channel.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let sampleRates: [Double]
    let transport: String
    let isDefault: Bool
}

/// Thin Swift wrappers around the CoreAudio HAL property API.
enum HAL {
    static let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = addr
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func getArray<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ zero: T) -> [T] {
        var a = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? items : []
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Devices

    static func defaultInputDevice() -> AudioDeviceID? {
        get(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0))
    }

    static func inputDevices() -> [AudioInputDevice] {
        let ids = getArray(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), AudioDeviceID(0))
        let defaultID = defaultInputDevice()
        return ids.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                name: string(id, kAudioObjectPropertyName) ?? "Okänd enhet",
                inputChannels: channels,
                sampleRates: availableSampleRates(id),
                transport: transportName(id),
                isDefault: id == defaultID
            )
        }
    }

    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        let ranges = getArray(id, address(kAudioDevicePropertyAvailableNominalSampleRates), AudioValueRange())
        let rates = standardRates.filter { rate in ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 } }
        return rates.isEmpty ? [nominalSampleRate(id)].filter { $0 > 0 } : rates
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        get(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    /// Switches the hardware clock and waits (briefly) until the device reports the new rate.
    @discardableResult
    static func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        if abs(nominalSampleRate(id) - rate) < 0.5 { return true }
        var a = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else { return false }
        for _ in 0..<50 {
            if abs(nominalSampleRate(id) - rate) < 0.5 { return true }
            usleep(20_000)
        }
        return false
    }

    static func transportName(_ id: AudioDeviceID) -> String {
        let type = get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "Inbyggd"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAggregate: return "Aggregat"
        case kAudioDeviceTransportTypeVirtual: return "Virtuell"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Ljud"
        }
    }

    // MARK: Hardware input gain

    /// Elements (master or per channel) where the device exposes a settable input volume.
    static func inputVolumeElements(_ id: AudioDeviceID, channels: Int) -> [AudioObjectPropertyElement] {
        func settable(_ element: AudioObjectPropertyElement) -> Bool {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            guard AudioObjectHasProperty(id, &a) else { return false }
            var isSettable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(id, &a, &isSettable) == noErr && isSettable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...max(1, channels)).map { AudioObjectPropertyElement($0) }.filter(settable)
    }

    static func inputVolume(_ id: AudioDeviceID, elements: [AudioObjectPropertyElement]) -> Float? {
        guard let first = elements.first else { return nil }
        return get(id, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, first), Float32(0))
    }

    static func setInputVolume(_ id: AudioDeviceID, elements: [AudioObjectPropertyElement], _ volume: Float) {
        for element in elements {
            var a = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element)
            var value = Float32(min(max(volume, 0), 1))
            AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    // MARK: Listeners

    @discardableResult
    static func observe(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                        _ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var a = addr
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        return AudioObjectAddPropertyListenerBlock(object, &a, .main, block) == noErr ? block : nil
    }

    static func removeObserver(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                               _ block: @escaping AudioObjectPropertyListenerBlock) {
        var a = addr
        AudioObjectRemovePropertyListenerBlock(object, &a, .main, block)
    }
}
