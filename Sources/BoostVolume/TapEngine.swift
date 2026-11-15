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
            try startIO(gain: gain)
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

    private func startIO(gain: Float) throws {
        let sampleRate = AudioDevices.get(aggregateID, kAudioDevicePropertyNominalSampleRate,
                                          initial: Float64(0)) ?? 48_000
        let processor = BoostProcessor(sampleRate: sampleRate > 0 ? sampleRate : 48_000, initialGain: gain)
        self.processor = processor

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, inInput, _, outOutput, _ in
            let output = UnsafeMutableAudioBufferListPointer(outOutput)
            guard output.count > 0 else { return }
            let first = output[0]
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            processor.process(input: input, output: output, frameCount: frames)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = proc

        try check(AudioDeviceStart(aggregateID, proc), "AudioDeviceStart")
    }
}
