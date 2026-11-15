import XCTest
import CoreAudio
@testable import BoostCore

/// Owns an AudioBufferList plus its sample storage for tests.
final class TestBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []
    let frames: Int

    /// `channels` logical channels; interleaved = one buffer with all channels.
    init(channels: Int, interleaved: Bool, frames: Int, fill: (_ frame: Int, _ channel: Int) -> Float = { _, _ in 0 }) {
        self.frames = frames
        let bufferCount = interleaved ? 1 : channels
        let perBuffer = interleaved ? channels : 1
        list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        for b in 0..<bufferCount {
            let count = frames * perBuffer
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            for f in 0..<frames {
                for k in 0..<perBuffer {
                    let ch = interleaved ? k : b
                    p[f * perBuffer + k] = fill(f, ch)
                }
            }
            storage.append(p)
            list[b] = AudioBuffer(mNumberChannels: UInt32(perBuffer),
                                  mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(p))
        }
    }

    /// Sample for logical channel `channel` at `frame`.
    func sample(_ frame: Int, _ channel: Int) -> Float {
        var ch = channel
        for b in 0..<list.count {
            let n = Int(list[b].mNumberChannels)
            if ch < n { return storage[b][frame * n + ch] }
            ch -= n
        }
        fatalError("channel out of range")
    }

    var channelCount: Int { list.reduce(0) { $0 + Int($1.mNumberChannels) } }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

final class BoostProcessorTests: XCTestCase {
    let sr = 48_000.0

    private func run(_ p: BoostProcessor, _ input: TestBuffers, outChannels: Int = 2, outInterleaved: Bool = false) -> TestBuffers {
        let out = TestBuffers(channels: outChannels, interleaved: outInterleaved, frames: input.frames, fill: { _, _ in 9 })
        p.process(input: input.list, output: out.list, frameCount: input.frames)
        return out
    }

    func testUnityGainIsTransparentBelowCeiling() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 1)
        let out = run(p, TestBuffers(channels: 2, interleaved: true, frames: 4800) { _, _ in 0.5 })
        for f in 0..<4800 { for c in 0..<2 { XCTAssertEqual(out.sample(f, c), 0.5, accuracy: 1e-6) } }
    }

    func testGainApplied() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 2)
        let out = run(p, TestBuffers(channels: 2, interleaved: true, frames: 4800) { _, _ in 0.25 })
        XCTAssertEqual(out.sample(0, 0), 0.5, accuracy: 1e-4)
        XCTAssertEqual(out.sample(4799, 1), 0.5, accuracy: 1e-4)
    }

    func testOutputNeverExceedsCeiling() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 4)
        let input = TestBuffers(channels: 2, interleaved: true, frames: 48_000) { f, _ in
            Float(sin(2 * Double.pi * 1000 * Double(f) / 48_000))
        }
        let out = run(p, input)
        var peak: Float = 0
        for f in 0..<48_000 { for c in 0..<2 { peak = max(peak, abs(out.sample(f, c))) } }
        XCTAssertLessThanOrEqual(peak, BoostProcessor.ceiling + 1e-6)
        XCTAssertGreaterThan(peak, 0.8)  // still loud, not silenced
    }

    func testGainChangeIsSmoothed() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 1)
        p.setTargetGain(4)
        let out = run(p, TestBuffers(channels: 2, interleaved: true, frames: 48_000) { _, _ in 0.1 })
        XCTAssertLessThan(out.sample(0, 0), 0.11)
        XCTAssertEqual(out.sample(47_999, 0), 0.4, accuracy: 1e-3)
    }

    func testLimiterReleasesAfterBurst() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 4)
        let burst = 4800
        let input = TestBuffers(channels: 2, interleaved: true, frames: burst + 48_000) { f, _ in f < burst ? 1.0 : 0.05 }
        let out = run(p, input)
        XCTAssertEqual(out.sample(burst + 47_999, 0), 0.2, accuracy: 1e-3)
    }

    func testSilenceInSilenceOut() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 4)
        let out = run(p, TestBuffers(channels: 2, interleaved: true, frames: 512))
        for f in 0..<512 { for c in 0..<2 { XCTAssertEqual(out.sample(f, c), 0) } }
    }

    func testInterleavedStereoToNonInterleavedStereo() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 1)
        let out = run(p, TestBuffers(channels: 2, interleaved: true, frames: 256) { _, c in c == 0 ? 0.1 : 0.2 },
                      outChannels: 2, outInterleaved: false)
        XCTAssertEqual(out.list.count, 2)
        for f in 0..<256 {
            XCTAssertEqual(out.sample(f, 0), 0.1, accuracy: 1e-6)
            XCTAssertEqual(out.sample(f, 1), 0.2, accuracy: 1e-6)
        }
    }

    func testMonoInputFillsAllOutputChannels() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 1)
        let out = run(p, TestBuffers(channels: 1, interleaved: true, frames: 256) { _, _ in 0.3 },
                      outChannels: 8, outInterleaved: true)
        for f in 0..<256 { for c in 0..<8 { XCTAssertEqual(out.sample(f, c), 0.3, accuracy: 1e-6) } }
    }

    func testStereoInputToMonoOutputUsesLeft() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 1)
        let out = run(p, TestBuffers(channels: 2, interleaved: true, frames: 256) { _, c in c == 0 ? 0.1 : 0.2 },
                      outChannels: 1, outInterleaved: true)
        for f in 0..<256 { XCTAssertEqual(out.sample(f, 0), 0.1, accuracy: 1e-6) }
    }

    func testNilInputDataWritesSilence() {
        let p = BoostProcessor(sampleRate: sr, initialGain: 2)
        let input = TestBuffers(channels: 2, interleaved: true, frames: 256) { _, _ in 0.5 }
        input.list[0].mData = nil
        let out = run(p, input)
        for f in 0..<256 { for c in 0..<2 { XCTAssertEqual(out.sample(f, c), 0) } }
    }
}
