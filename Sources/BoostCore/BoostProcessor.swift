import Atomics
import CoreAudio
import Foundation

/// Real-time safe gain + peak limiter.
///
/// `process` runs on the audio I/O thread: it performs no allocation, locking,
/// or logging. `setTargetGain` may be called from any thread.
public final class BoostProcessor {
    /// Limiter ceiling: −1 dBFS.
    public static let ceiling: Float = 0.891

    /// Upper bound on channels handled per side; extra channels are silenced.
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

    /// Fills the lookup tables for `list`. Returns (channel count, frames available).
    private func map(_ list: UnsafeMutableAudioBufferListPointer,
                     into ptrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                     strides: UnsafeMutablePointer<Int>,
                     frameCount: Int) -> (channels: Int, frames: Int) {
        var channels = 0
        var frames = frameCount
        for buffer in list {
            let n = Int(buffer.mNumberChannels)
            guard n > 0 else { continue }
            let base = buffer.mData?.assumingMemoryBound(to: Float.self)
            if base == nil {
                frames = 0
            } else {
                frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n))
            }
            for k in 0..<n where channels < Self.maxChannels {
                ptrs[channels] = base.map { $0 + k }
                strides[channels] = n
                channels += 1
            }
        }
        return (channels, frames)
    }

    public func process(input: UnsafeMutableAudioBufferListPointer,
                        output: UnsafeMutableAudioBufferListPointer,
                        frameCount: Int) {
        let (inCh, inFrames) = map(input, into: inPtrs, strides: inStrides, frameCount: frameCount)
        let (outCh, outFrames) = map(output, into: outPtrs, strides: outStrides, frameCount: frameCount)
        guard outCh > 0, outFrames > 0 else { return }

        let target = Float(bitPattern: targetGainBits.load(ordering: .relaxed))
        let liveFrames = inCh > 0 ? min(inFrames, outFrames) : 0
        let ceiling = Self.ceiling

        for f in 0..<liveFrames {
            currentGain += (target - currentGain) * smoothCoeff

            var peak: Float = 0
            for c in 0..<inCh {
                peak = max(peak, abs(inPtrs[c]![f * inStrides[c]] * currentGain))
            }
            let wanted: Float = peak > ceiling ? ceiling / peak : 1
            envelope = wanted < envelope ? wanted : envelope + (wanted - envelope) * releaseCoeff
            let g = currentGain * envelope

            for c in 0..<outCh {
                let ic = min(c, inCh - 1)
                outPtrs[c]![f * outStrides[c]] = inPtrs[ic]![f * inStrides[ic]] * g
            }
        }

        // Anything without input (missing data / short buffer) is silence.
        if liveFrames < outFrames {
            for c in 0..<outCh {
                for f in liveFrames..<outFrames {
                    outPtrs[c]![f * outStrides[c]] = 0
                }
            }
        }
    }
}
