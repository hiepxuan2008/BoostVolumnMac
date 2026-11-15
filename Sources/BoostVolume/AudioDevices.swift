import BoostCore
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "\(operation): \(status)" }
}

@discardableResult
func check(_ status: OSStatus, _ operation: String) throws -> OSStatus {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
    return status
}

/// Prefix of the private aggregate devices TapEngine creates; hidden from device lists.
let boostAggregateUIDPrefix = "com.boostvolume.aggregate."

enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value.
    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Number of streams the device has in `scope` (input or output).
    static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func hasOutputStreams(_ id: AudioObjectID) -> Bool {
        streamCount(id, scope: kAudioObjectPropertyScopeOutput) > 0
    }

    private static func isVirtual(_ id: AudioObjectID) -> Bool {
        get(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) == kAudioDeviceTransportTypeVirtual
    }

    /// All devices that can play audio, excluding our own aggregate devices.
    static func outputDevices() -> [OutputDevice] {
        allDeviceIDs().compactMap { id in
            guard hasOutputStreams(id),
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(boostAggregateUIDPrefix) else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? uid
            return OutputDevice(id: id, uid: uid, name: name, isVirtual: isVirtual(id))
        }
    }

    static func defaultOutputUID() -> String? {
        guard let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)),
              id != kAudioObjectUnknown else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    /// The Core Audio process object for this app (used to exclude ourselves from the tap).
    static func ownProcessObjectID() throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "TranslatePIDToProcessObject")
        guard object != kAudioObjectUnknown else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "TranslatePIDToProcessObject")
        }
        return object
    }
}

/// Calls `onChange` on the main queue when devices are added/removed or the default output changes.
final class DeviceChangeObserver {
    private let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
    private let block: AudioObjectPropertyListenerBlock

    init(onChange: @escaping @MainActor () -> Void) {
        block = { _, _ in MainActor.assumeIsolated { onChange() } }
        for selector in selectors {
            var addr = AudioDevices.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    deinit {
        for selector in selectors {
            var addr = AudioDevices.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }
}
