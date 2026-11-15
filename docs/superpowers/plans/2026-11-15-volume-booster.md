# Volume Booster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar macOS app that boosts all system audio 100%–400% using a Core Audio process tap, with a limiter so boosted audio doesn't clip.

**Architecture:** A Swift package with two targets. `BoostCore` (library) holds everything testable without audio hardware: gain math, the real-time `BoostProcessor` (gain smoothing + peak limiter + buffer-layout mapping), persisted settings, and output-device fallback logic. `BoostVolume` (executable) holds the SwiftUI `MenuBarExtra` UI, the Core Audio device layer, and `TapEngine` (process tap → private aggregate device → IOProc that calls `BoostProcessor`). A shell script assembles the executable into `build/BoostVolume.app` with an Info.plist and signs it.

**Tech Stack:** Swift 6.2 toolchain (language mode 5), SwiftUI, Core Audio (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`), ServiceManagement (`SMAppService`), XCTest, [swift-atomics](https://github.com/apple/swift-atomics) 1.2+.

**Spec:** `docs/superpowers/specs/2026-11-15-volume-booster-design.md`

## Global Constraints

- Minimum OS: macOS 14.4 (`platforms: [.macOS("14.4")]`).
- Menu bar only: `LSUIElement` = `YES`; no Dock icon, no main window.
- Info.plist must contain `NSAudioCaptureUsageDescription`: "BoostVolume needs to capture system audio so it can make it louder."
- Boost range 100%–400% (gain 1.0–4.0). Default boost 200%, Boost off on first launch (my call; spec only says "remembered").
- The audio thread (IOProc) must not allocate, lock, log, or call into Swift runtime features that may allocate (no arrays created per callback, no `print`, no `DispatchQueue.main.sync`).
- Tap must exclude our own process and use `muteBehavior = .mutedWhenTapped`; tap and aggregate must be private.
- No sandbox, no App Store. Bundle id `com.boostvolume.app`. App name `BoostVolume`.
- Work on a feature branch (`feat/volume-booster`), not `main`.

## Review Focus

1. **Headphones unplugged / output switched while boosting** → audio keeps playing on the new output within ~1 s, never stuck muted. Pinned by `resolveOutputDevice` fallback tests (Task 3) and manual check in Task 6.
2. **Quitting the app while boosting** → original system audio is audible again immediately. Pinned by manual check in Task 6 (teardown in `applicationWillTerminate`; process death also frees the private tap).
3. **Dragging the slider quickly** → no clicks or zipper noise. Pinned by `testGainChangeIsSmoothed` (Task 2).
4. **Already-loud audio at 400%** → never exceeds the ceiling, no wraparound/crackle. Pinned by `testOutputNeverExceedsCeiling` (Task 2).
5. **Output device with different channel count than the tap (mono speaker, 8-ch HDMI, non-interleaved buffers)** → each output channel gets sensible audio, no garbage. Pinned by the channel-mapping tests (Task 2).

Known limitation (spec deviation): macOS offers no public API to check System Audio Recording permission. Instead of detecting denial, the menu always shows a one-line hint ("No sound? Allow BoostVolume in Privacy & Security") with a button that opens the settings pane.

---

## File Structure

```
Package.swift
Resources/Info.plist
scripts/build-app.sh                        → build/BoostVolume.app
Sources/BoostCore/BoostMath.swift           percent ↔ gain, clamping
Sources/BoostCore/BoostProcessor.swift      RT-safe gain smoothing + limiter + channel mapping
Sources/BoostCore/BoostSettings.swift       UserDefaults-backed settings
Sources/BoostCore/OutputDevice.swift        OutputDevice model + resolveOutputDevice()
Sources/BoostVolume/BoostVolumeApp.swift    @main, MenuBarExtra, app delegate
Sources/BoostVolume/MenuView.swift          popover UI
Sources/BoostVolume/AudioDevices.swift      Core Audio device enumeration + change listeners
Sources/BoostVolume/TapEngine.swift         process tap + aggregate + IOProc lifecycle
Sources/BoostVolume/BoostController.swift   @MainActor state; wires settings, devices, engine
Sources/BoostVolume/LaunchAtLogin.swift     SMAppService wrapper
Tests/BoostCoreTests/BoostMathTests.swift
Tests/BoostCoreTests/BoostProcessorTests.swift
Tests/BoostCoreTests/BoostSettingsTests.swift
Tests/BoostCoreTests/OutputDeviceTests.swift
```

---

### Task 1: Package scaffold, gain math, and a launchable menu bar app

**Files:**
- Create: `Package.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `.gitignore`
- Create: `Sources/BoostCore/BoostMath.swift`, `Sources/BoostVolume/BoostVolumeApp.swift`
- Test: `Tests/BoostCoreTests/BoostMathTests.swift`

**Interfaces:**
- Produces: `BoostMath.range: ClosedRange<Double>` (= `100...400`), `BoostMath.clampPercent(_ p: Double) -> Double`, `BoostMath.gain(forPercent p: Double) -> Float` (clamps, then `p / 100`).
- Produces: `scripts/build-app.sh` — `swift build -c release`, copies binary to `build/BoostVolume.app/Contents/MacOS/BoostVolume`, copies `Resources/Info.plist` to `Contents/Info.plist`, then `codesign --force --sign "${SIGN_IDENTITY:--}" build/BoostVolume.app`. Ad-hoc signing means macOS re-asks for audio permission after each rebuild; setting `SIGN_IDENTITY` to a valid dev identity avoids that.

- [ ] **Step 1: Create branch** — `git checkout -b feat/volume-booster`.
- [ ] **Step 2: Write `Package.swift`** — tools 6.0, `swiftLanguageModes: [.v5]`, platforms `.macOS("14.4")`, dependency `swift-atomics` from `1.2.0`, library target `BoostCore` (depends on `Atomics`), executable target `BoostVolume` (depends on `BoostCore`), test target `BoostCoreTests`. `.gitignore`: `.build/`, `build/`, `.swiftpm/`.
- [ ] **Step 3: Write the failing test**

```swift
final class BoostMathTests: XCTestCase {
    func testGainAtEndsOfRange() {
        XCTAssertEqual(BoostMath.gain(forPercent: 100), 1.0)
        XCTAssertEqual(BoostMath.gain(forPercent: 250), 2.5)
        XCTAssertEqual(BoostMath.gain(forPercent: 400), 4.0)
    }
    func testOutOfRangeIsClamped() {
        XCTAssertEqual(BoostMath.clampPercent(50), 100)
        XCTAssertEqual(BoostMath.clampPercent(900), 400)
        XCTAssertEqual(BoostMath.gain(forPercent: .nan), 1.0)  // NaN → 100%
    }
}
```

- [ ] **Step 4: Run** `swift test --filter BoostMathTests` → FAIL (no `BoostMath`).
- [ ] **Step 5: Implement `BoostMath`** in `Sources/BoostCore/BoostMath.swift`.
- [ ] **Step 6: Run** `swift test --filter BoostMathTests` → PASS.
- [ ] **Step 7: Minimal app** — `BoostVolumeApp` with `MenuBarExtra("BoostVolume", systemImage: "speaker.wave.3.fill") { Button("Quit") { NSApp.terminate(nil) } }.menuBarExtraStyle(.window)`. Info.plist: `CFBundleIdentifier`, `CFBundleName`, `CFBundleExecutable` = `BoostVolume`, `CFBundlePackageType` = `APPL`, `CFBundleShortVersionString` = `0.1.0`, `LSMinimumSystemVersion` = `14.4`, `LSUIElement` = `true`, `NSAudioCaptureUsageDescription` (exact copy from Global Constraints).
- [ ] **Step 8: Verify** — `./scripts/build-app.sh && open build/BoostVolume.app`; expected: speaker icon in menu bar, no Dock icon, Quit works. `pgrep -x BoostVolume` shows a PID while running.
- [ ] **Step 9: Commit** — `feat: scaffold package, gain math, menu bar shell`.

---

### Task 2: BoostProcessor (gain smoothing, limiter, channel mapping)

**Files:**
- Create: `Sources/BoostCore/BoostProcessor.swift`
- Test: `Tests/BoostCoreTests/BoostProcessorTests.swift`

**Interfaces:**
- Consumes: `BoostMath.gain(forPercent:)`.
- Produces:
  - `final class BoostProcessor` — `init(sampleRate: Double, initialGain: Float)`
  - `func setTargetGain(_ gain: Float)` — callable from any thread; stores into a `ManagedAtomic<UInt32>` (float bit pattern).
  - `func process(input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer, frameCount: Int)` — audio-thread only; Float32 samples; buffers may be interleaved (`mNumberChannels > 1`) or not. Missing/nil input data → writes silence.
  - `static let ceiling: Float = 0.891` (−1 dBFS).

**Algorithm (decided here, not left open):**
- Per sample: `currentGain += (targetGain - currentGain) * smoothCoeff`, `smoothCoeff = 1 - exp(-1 / (0.020 * sampleRate))` (20 ms).
- Stereo-linked peak limiter, instant attack, exponential release: `peak = max over channels |x·currentGain|`; `wanted = peak > ceiling ? ceiling / peak : 1`; `env = wanted < env ? wanted : env + (wanted - env) * releaseCoeff`, `releaseCoeff = 1 - exp(-1 / (0.150 * sampleRate))` (150 ms); `out = x · currentGain · env`. Instant attack guarantees `|out| ≤ ceiling`.
- Channel mapping: logical input channels = concatenation of all input buffers' channels; output channel `c` reads input channel `min(c, inChannels - 1)` (mono → all outputs; extra outputs repeat the last input channel). Compute buffer/offset/stride by iterating buffers — no per-callback allocation.

- [ ] **Step 1: Write failing tests** (helper `makeBufferList(channels:interleaved:frames:fill:)` in the test file allocates with `AudioBufferList.allocate(maximumBuffers:)`):

```swift
func testUnityGainIsTransparentBelowCeiling()      // gain 1, input 0.5 const → every output sample == 0.5 (±1e-6)
func testGainApplied()                              // initialGain 2, input 0.25 → output 0.5 (±1e-4)
func testOutputNeverExceedsCeiling()                // initialGain 4, full-scale 1 kHz sine, 48000 frames → max |out| <= BoostProcessor.ceiling + 1e-6
func testGainChangeIsSmoothed()                     // initialGain 1, input 0.1, setTargetGain(4) → out[0] < 0.11; out[47999] ≈ 0.4 (±1e-3)
func testLimiterReleasesAfterBurst()                // gain 4: 4800 frames at 1.0, then 48000 at 0.05 → last sample ≈ 0.2 (±1e-3)
func testSilenceInSilenceOut()                      // zeros in → zeros out
func testInterleavedStereoToNonInterleavedStereo()  // in L=0.1,R=0.2 (one buffer, 2 ch) → out buffer0 all 0.1, buffer1 all 0.2
func testMonoInputFillsAllOutputChannels()          // in 1 ch 0.3 → 8-ch interleaved out, every sample 0.3
func testStereoInputToMonoOutputUsesLeft()          // in L=0.1,R=0.2 → 1-ch out == 0.1
func testNilInputDataWritesSilence()                // input buffer mData == nil → output zeros
```

- [ ] **Step 2: Run** `swift test --filter BoostProcessorTests` → FAIL.
- [ ] **Step 3: Implement `BoostProcessor`** per the algorithm above.
- [ ] **Step 4: Run** `swift test --filter BoostProcessorTests` → all PASS.
- [ ] **Step 5: Commit** — `feat: add real-time boost processor with limiter`.

---

### Task 3: Settings and output-device resolution

**Files:**
- Create: `Sources/BoostCore/BoostSettings.swift`, `Sources/BoostCore/OutputDevice.swift`
- Test: `Tests/BoostCoreTests/BoostSettingsTests.swift`, `Tests/BoostCoreTests/OutputDeviceTests.swift`

**Interfaces:**
- Produces:
  - `final class BoostSettings` — `init(defaults: UserDefaults = .standard)`; properties (read/write, persisted immediately): `boostPercent: Double` (key `boostPercent`, default 200, clamped via `BoostMath.clampPercent` on read and write), `isEnabled: Bool` (key `isEnabled`, default false), `outputDeviceUID: String?` (key `outputDeviceUID`, default nil = follow system default).
  - `struct OutputDevice: Equatable, Identifiable { let id: AudioObjectID; let uid: String; let name: String }`
  - `func resolveOutputDevice(preferredUID: String?, available: [OutputDevice], systemDefaultUID: String?) -> OutputDevice?` — preferred if present in `available`; else the system default if present; else `available.first`; else nil.

- [ ] **Step 1: Write failing tests** (settings tests use `UserDefaults(suiteName: "BoostSettingsTests-\(UUID())")!`):

```swift
func testDefaults()                    // boostPercent 200, isEnabled false, outputDeviceUID nil
func testRoundTripAcrossInstances()    // set 320/true/"uid-1", new BoostSettings on same defaults reads same values
func testStoredOutOfRangeIsClamped()   // defaults.set(1000, forKey: "boostPercent") → boostPercent == 400
func testPreferredDeviceWins()         // preferred "B" present → B
func testMissingPreferredFallsBackToSystemDefault()   // preferred "gone", default "A" → A  (headphones unplugged)
func testNilPreferredUsesSystemDefault()
func testNoSystemDefaultUsesFirst()
func testNoDevicesReturnsNil()
```

- [ ] **Step 2: Run** `swift test --filter "BoostSettingsTests|OutputDeviceTests"` → FAIL.
- [ ] **Step 3: Implement** `BoostSettings`, `OutputDevice`, `resolveOutputDevice`.
- [ ] **Step 4: Run** same filter → PASS; then `swift test` → all PASS.
- [ ] **Step 5: Commit** — `feat: add settings and output device resolution`.

---

### Task 4: Core Audio device layer

**Files:**
- Create: `Sources/BoostVolume/AudioDevices.swift`

**Interfaces:**
- Consumes: `OutputDevice`.
- Produces: `enum AudioDevices` with
  - `static func outputDevices() -> [OutputDevice]` — devices with ≥1 output stream (`kAudioDevicePropertyStreams`, scope output), excluding aggregates whose UID starts with `"com.boostvolume.aggregate."`.
  - `static func defaultOutputUID() -> String?` (`kAudioHardwarePropertyDefaultOutputDevice` → `kAudioDevicePropertyDeviceUID`).
  - `static func ownProcessObjectID() throws -> AudioObjectID` (`kAudioHardwarePropertyTranslatePIDToProcessObject` with `getpid()`).
  - `final class DeviceChangeObserver` — `init(onChange: @escaping @MainActor () -> Void)`; registers `AudioObjectAddPropertyListenerBlock` on the system object for `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultOutputDevice` on the main queue; removes listeners in `deinit`.
  - `struct CoreAudioError: Error { let status: OSStatus; let operation: String }` used by this file and `TapEngine`.

- [ ] **Step 1: Implement** the above.
- [ ] **Step 2: Temporary verify** — in `BoostVolumeApp`, list `AudioDevices.outputDevices()` names as disabled `Text` rows in the menu and show `defaultOutputUID()`. `./scripts/build-app.sh && open build/BoostVolume.app` → menu lists the Mac's speakers (and any connected headphones/AirPods); connecting/disconnecting headphones updates the list while the menu is open (via `DeviceChangeObserver`).
- [ ] **Step 3: Remove the temporary rows; `swift build` succeeds.**
- [ ] **Step 4: Commit** — `feat: add Core Audio device enumeration and change observer`.

---

### Task 5: TapEngine

**Files:**
- Create: `Sources/BoostVolume/TapEngine.swift`

**Interfaces:**
- Consumes: `BoostProcessor`, `AudioDevices.ownProcessObjectID()`, `CoreAudioError`, `OutputDevice`.
- Produces: `final class TapEngine` —
  - `init()`
  - `func start(output: OutputDevice, gain: Float) throws` — if already running, `stop()` first.
  - `func stop()` — idempotent; safe to call when start failed half-way (destroys whatever was created).
  - `func setGain(_ gain: Float)` — forwards to `BoostProcessor.setTargetGain`.
  - `var isRunning: Bool { get }`

**Start sequence (in order; on any non-noErr status, clean up and throw `CoreAudioError`):**
1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcessObjectID])`; `uuid = UUID()`, `muteBehavior = .mutedWhenTapped`, `isPrivate = true`, `name = "BoostVolume Tap"`.
2. `AudioHardwareCreateProcessTap(desc, &tapID)`.
3. Aggregate dict: `kAudioAggregateDeviceNameKey: "BoostVolume"`, `kAudioAggregateDeviceUIDKey: "com.boostvolume.aggregate.\(UUID())"`, `kAudioAggregateDeviceMainSubDeviceKey: output.uid`, `kAudioAggregateDeviceIsPrivateKey: true`, `kAudioAggregateDeviceIsStackedKey: false`, `kAudioAggregateDeviceTapAutoStartKey: true`, `kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]]`, `kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]` → `AudioHardwareCreateAggregateDevice`.
4. Read nominal sample rate of the aggregate (`kAudioDevicePropertyNominalSampleRate`) → create `BoostProcessor(sampleRate:initialGain:)`.
5. `AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, block)` where the block wraps `inInputData`/`outOutputData` in `UnsafeMutableAudioBufferListPointer` and calls `processor.process(...)` with frame count = `outOutputData` buffer 0 `mDataByteSize / (4 * mNumberChannels)`. `ioQueue` is a dedicated serial `DispatchQueue(label: "boostvolume.io", qos: .userInteractive)`.
6. `AudioDeviceStart(aggregateID, procID)`.

**Stop sequence:** `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`; reset IDs to `kAudioObjectUnknown`.

- [ ] **Step 1: Implement `TapEngine`.**
- [ ] **Step 2: Temporary verify** — add a menu `Toggle` that calls `start(output:gain: 2.0)` on the resolved default device / `stop()`. Build and open the app, play music (e.g. `afplay /System/Library/Sounds/Submarine.aiff` in a loop, or any YouTube video). Expected: first toggle → macOS permission prompt; after allowing, audio is clearly louder with no doubled/echoed sound (original muted) and no crackle; toggle off → back to normal volume; `swift test` still passes.
- [ ] **Step 3: Commit** — `feat: add process tap engine`.

---

### Task 6: BoostController, final UI, launch at login

**Files:**
- Create: `Sources/BoostVolume/BoostController.swift`, `Sources/BoostVolume/MenuView.swift`, `Sources/BoostVolume/LaunchAtLogin.swift`
- Modify: `Sources/BoostVolume/BoostVolumeApp.swift` (remove Task 5 temporary toggle)

**Interfaces:**
- Consumes: `BoostSettings`, `BoostMath`, `resolveOutputDevice`, `AudioDevices`, `DeviceChangeObserver`, `TapEngine`.
- Produces:
  - `@MainActor final class BoostController: ObservableObject` — `@Published var isEnabled: Bool`, `@Published var boostPercent: Double`, `@Published var selectedDeviceUID: String?` (nil = "System Default"), `@Published private(set) var devices: [OutputDevice]`, `@Published private(set) var activeDevice: OutputDevice?`, `@Published private(set) var errorMessage: String?`, `@Published var launchAtLogin: Bool`; `func shutdown()`.
  - `enum LaunchAtLogin { static var isEnabled: Bool; static func set(_ on: Bool) throws }` over `SMAppService.mainApp`.

**Behavior:**
- Init: load from `BoostSettings`; refresh devices; if `isEnabled`, start engine on `resolveOutputDevice(preferredUID: selectedDeviceUID, available: devices, systemDefaultUID: AudioDevices.defaultOutputUID())`.
- Every published setter persists to `BoostSettings`. `boostPercent` change → `engine.setGain(BoostMath.gain(forPercent:))` only (no restart). `isEnabled` change → start/stop. `selectedDeviceUID` change → restart if enabled.
- `DeviceChangeObserver` fires → refresh `devices`, re-resolve; if the resolved device's UID differs from `activeDevice?.uid` and enabled → restart on the new one (Review Focus 1).
- Start failure → `isEnabled = false`, `errorMessage = "Couldn't start boost (\(operation): \(status))"`; cleared on next successful start.
- `shutdown()` stops the engine; called from an `NSApplicationDelegate.applicationWillTerminate` (via `@NSApplicationDelegateAdaptor`) (Review Focus 2).

**MenuView** (matches the spec sketch): header row "Boost" + `Toggle`; `Slider(value: $boostPercent, in: 100...400, step: 5)` with `"\(Int(boostPercent))%"`; `Picker("Output", ...)` with "System Default" + each device name; `Toggle("Launch at login")`; error text in red when `errorMessage != nil`; small secondary text "No sound? Allow BoostVolume in Privacy & Security." + button "Open Settings" opening `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture`; `Divider`; "Quit". Menu bar icon: `speaker.wave.3.fill` when enabled, `speaker.wave.1` when off.

- [ ] **Step 1: Implement** `LaunchAtLogin`, `BoostController`, `MenuView`; wire into `BoostVolumeApp`.
- [ ] **Step 2: Run** `swift test` → all PASS; `./scripts/build-app.sh` succeeds with no warnings about Info.plist.
- [ ] **Step 3: Manual verification checklist** (open `build/BoostVolume.app`, play continuous audio):
  - Toggle on → louder; slider 100%→400% sweeps smoothly with no clicks; at 400% on loud music, no harsh crackle.
  - Icon changes with on/off. No Dock icon.
  - Plug in / unplug headphones (or switch output in Control Center) while boosting → audio follows within ~1 s, never stays muted.
  - Pick a specific device in the picker → audio moves there; pick "System Default" → follows system again.
  - Quit while boosting → normal audio resumes immediately. `kill -9 $(pgrep -x BoostVolume)` while boosting → normal audio resumes.
  - Relaunch → boost level and on/off restored.
  - Launch at login toggle → app appears in System Settings › General › Login Items.
- [ ] **Step 4: Commit** — `feat: complete menu UI, controller, launch at login`.
- [ ] **Step 5: Update `README.md`** — what it is, requirements (macOS 14.4+), build (`./scripts/build-app.sh`), the permission note, and `SIGN_IDENTITY`. Commit — `docs: add README`.
