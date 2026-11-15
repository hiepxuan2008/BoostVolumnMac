import Atomics
import CoreAudio
import Foundation

/// Real-time safe gain + peak limiter.
///
/// The source is treated as stereo (the process tap delivers stereo): input
/// channel 0 is L, channel 1 is R (a mono source feeds both). Output mapping:
/// a mono device gets (L+R)/2; otherwise channels 0/1 get L/R and any further
/// channels are silenced.
///
/// `process` runs on the audio I/O thread: it performs no allocation, locking,
/// or logging. `setTargetGain` may be called from any thread.
public final class BoostProcessor {
    /// Limiter ceiling for boosted audio: −1 dBFS. Audio is never pulled below
    /// its own un-boosted level (so at 100% the processor is transparent), and
    /// output never exceeds full scale (1.0).
    public static let ceiling: Float = 0.891

    /// Upper bound on output channels handled; extra channels are left untouched.
    static let maxChannels = 64

    private let targetGainBits: ManagedAtomic<UInt32>
    private var currentGain: Float
    private var envelope: Float = 1
    private let smoothCoeff: Float
    private let releaseCoeff: Float

    // Preallocated per-channel lookup tables (filled at the start of each callback).
    private let inPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let inStrides: UnsafeMutablePointer<Int>
    private let outPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
    private let outStrides: UnsafeMutablePointer<Int>

    public init(sampleRate: Double, initialGain: Float) {
        targetGainBits = ManagedAtomic(initialGain.bitPattern)
        currentGain = initialGain
        smoothCoeff = Float(1 - exp(-1 / (0.020 * sampleRate)))
        releaseCoeff = Float(1 - exp(-1 / (0.150 * sampleRate)))
        let n = Self.maxChannels
        inPtrs = .allocate(capacity: n)
        inStrides = .allocate(capacity: n)
        outPtrs = .allocate(capacity: n)
        outStrides = .allocate(capacity: n)
    }

    deinit {
        inPtrs.deallocate()
        inStrides.deallocate()
        outPtrs.deallocate()
        outStrides.deallocate()
    }

    public func setTargetGain(_ gain: Float) {
        targetGainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Fills the lookup tables for buffers `range` of `list`.
    /// Buffers with nil data map to nil pointers (read as silence) and don't limit `frames`.
    private func map(_ list: UnsafeMutableAudioBufferListPointer,
                     range: Range<Int>,
                     into ptrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                     strides: UnsafeMutablePointer<Int>,
                     frameCount: Int) -> (channels: Int, frames: Int, anyData: Bool) {
        var channels = 0
        var frames = frameCount
        var anyData = false
        for b in range.clamped(to: 0..<list.count) {
            let buffer = list[b]
            let n = Int(buffer.mNumberChannels)
            guard n > 0 else { continue }
            let base = buffer.mData?.assumingMemoryBound(to: Float.self)
            if base != nil {
                anyData = true
                frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n))
            }
            for k in 0..<n where channels < Self.maxChannels {
                ptrs[channels] = base.map { $0 + k }
                strides[channels] = n
                channels += 1
            }
        }
        return (channels, frames, anyData)
    }

    @inline(__always)
    private func read(_ c: Int, _ f: Int) -> Float {
        guard let p = inPtrs[c] else { return 0 }
        return p[f * inStrides[c]]
    }

    /// - Parameter inputBuffers: which buffers of `input` carry the source audio
    ///   (an aggregate device's input list may also contain other devices' streams).
    public func process(input: UnsafeMutableAudioBufferListPointer,
                        inputBuffers: Range<Int>,
                        output: UnsafeMutableAudioBufferListPointer,
                        frameCount: Int) {
        let (inCh, inFrames, anyData) = map(input, range: inputBuffers, into: inPtrs,
                                            strides: inStrides, frameCount: frameCount)
        let (outCh, outFrames, outData) = map(output, range: 0..<output.count, into: outPtrs,
                                              strides: outStrides, frameCount: frameCount)
        guard outCh > 0, outData, outFrames > 0 else { return }

        let target = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        let liveFrames = (inCh > 0 && anyData) ? min(inFrames, outFrames) : 0
        let ceiling = Self.ceiling
        let rightIndex = inCh >= 2 ? 1 : 0
        let mono = outCh == 1
        var gain = currentGain
        var env = envelope

        for f in 0..<liveFrames {
            gain += (target - gain) * smoothCoeff

            var l = read(0, f)
            var r = read(rightIndex, f)
            if mono {
                l = (l + r) * 0.5
                r = l
            }
            let inPeak = max(abs(l), abs(r))
            let peak = inPeak * gain
            // Never limit below the un-boosted level (transparent at gain 1),
            // but never exceed full scale either.
            let wanted: Float = peak > ceiling ? max(ceiling, min(inPeak, 1)) / peak : 1
            env = wanted < env ? wanted : env + (wanted - env) * releaseCoeff
            let g = gain * env

            if let p = outPtrs[0] { p[f * outStrides[0]] = l * g }
            if outCh >= 2, let p = outPtrs[1] { p[f * outStrides[1]] = r * g }
        }
        currentGain = gain
        envelope = env

        for c in 0..<outCh {
            guard let p = outPtrs[c] else { continue }
            let start = c < 2 ? liveFrames : 0  // channels 2+ are always silent
            for f in start..<outFrames { p[f * outStrides[c]] = 0 }
        }
    }
}
