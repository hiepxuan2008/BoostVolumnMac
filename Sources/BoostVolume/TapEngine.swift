import BoostCore
import CoreAudio
import Foundation

/// Captures all system audio with a Core Audio process tap (muting the original),
/// boosts it through `BoostProcessor`, and plays it on a chosen output device.
final class TapEngine {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var processor: BoostProcessor?
    private let ioQueue = DispatchQueue(label: "boostvolume.io", qos: .userInteractive)

    private(set) var isRunning = false

    init() {}

    deinit { stop() }

    func setGain(_ gain: Float) {
        processor?.setTargetGain(gain)
    }

    func start(output: OutputDevice, gain: Float) throws {
        stop()
        do {
            try createTap()
            try createAggregate(outputUID: output.uid)
            try startIO(gain: gain, outputDeviceID: output.id)
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// Idempotent; tears down whatever exists, in reverse order of creation.
    func stop() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        processor = nil
        isRunning = false
    }

    // MARK: - Steps

    private var tapUUID = UUID()

    private func createTap() throws {
        let own = try AudioDevices.ownProcessObjectID()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
        tapUUID = UUID()
        desc.uuid = tapUUID
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "BoostVolume Tap"
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &id), "AudioHardwareCreateProcessTap")
        tapID = id
    }

    private func createAggregate(outputUID: String) throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BoostVolume",
            kAudioAggregateDeviceUIDKey: boostAggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id),
                  "AudioHardwareCreateAggregateDevice")
        aggregateID = id
    }

    /// The aggregate's input list holds the output device's own input streams (e.g. a
    /// headset mic) followed by the tap's stream. Returns the buffer range of the tap.
    private func tapBufferRange(outputDeviceID: AudioObjectID) -> Range<Int> {
        let deviceInputs = AudioDevices.streamCount(outputDeviceID, scope: kAudioObjectPropertyScopeInput)
        let aggregateInputs = AudioDevices.streamCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard aggregateInputs > deviceInputs else { return 0..<aggregateInputs }
        return deviceInputs..<aggregateInputs
    }

    /// Turns off the aggregate's non-tap input streams so the device's mic isn't
    /// started (which would, e.g., force AirPods into low-quality headset mode).
    private func disableInputStreams(outside tapRange: Range<Int>, proc: AudioDeviceIOProcID) {
        let count = AudioDevices.streamCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
        guard count > 0, tapRange.count < count else { return }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = offset + count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let flags = (raw + offset).bindMemory(to: UInt32.self, capacity: count)
        for i in 0..<count { flags[i] = tapRange.contains(i) ? 1 : 0 }
        var addr = AudioDevices.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        // Best effort: if this fails the mic may run, but only tap buffers are used.
        AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(size), raw)
    }

    private func startIO(gain: Float, outputDeviceID: AudioObjectID) throws {
        let sampleRate = AudioDevices.get(aggregateID, kAudioDevicePropertyNominalSampleRate,
                                          initial: Float64(0)) ?? 48_000
        let processor = BoostProcessor(sampleRate: sampleRate > 0 ? sampleRate : 48_000, initialGain: gain)
        self.processor = processor
        let tapRange = tapBufferRange(outputDeviceID: outputDeviceID)

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, inInput, _, outOutput, _ in
            let output = UnsafeMutableAudioBufferListPointer(outOutput)
            guard output.count > 0 else { return }
            let first = output[0]
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            processor.process(input: input, inputBuffers: tapRange, output: output, frameCount: frames)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = proc
        if let proc { disableInputStreams(outside: tapRange, proc: proc) }

        try check(AudioDeviceStart(aggregateID, proc), "AudioDeviceStart")
    }
}
