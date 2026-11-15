import BoostCore
import Combine
import Foundation

/// App state: ties persisted settings, the device list, and the tap engine together.
@MainActor
final class BoostController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            settings.isEnabled = isEnabled
            isEnabled ? startEngine() : stopEngine()
        }
    }

    @Published var boostPercent: Double {
        didSet {
            settings.boostPercent = boostPercent
            engine.setGain(BoostMath.gain(forPercent: boostPercent))
        }
    }

    /// nil = follow the system default output.
    @Published var selectedDeviceUID: String? {
        didSet {
            guard selectedDeviceUID != oldValue else { return }
            settings.outputDeviceUID = selectedDeviceUID
            if isEnabled { startEngine() }
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, launchAtLogin != LaunchAtLogin.isEnabled else { return }
            do {
                try LaunchAtLogin.set(launchAtLogin)
            } catch {
                errorMessage = "Couldn't change launch at login: \(error.localizedDescription)"
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var activeDevice: OutputDevice?
    @Published private(set) var errorMessage: String?

    private let settings: BoostSettings
    private let engine = TapEngine()
    private var observer: DeviceChangeObserver?

    init(settings: BoostSettings = BoostSettings()) {
        self.settings = settings
        isEnabled = settings.isEnabled
        boostPercent = settings.boostPercent
        selectedDeviceUID = settings.outputDeviceUID
        launchAtLogin = LaunchAtLogin.isEnabled
        devices = AudioDevices.outputDevices()
        observer = DeviceChangeObserver { [weak self] in self?.devicesChanged() }
        if isEnabled { startEngine(userInitiated: false) }
    }

    /// Stops boosting so the original system audio is unmuted. Call before quitting.
    func shutdown() {
        stopEngine()
    }

    private func resolvedDevice() -> OutputDevice? {
        resolveOutputDevice(preferredUID: selectedDeviceUID,
                            available: devices,
                            systemDefaultUID: AudioDevices.defaultOutputUID())
    }

    private var retryTask: Task<Void, Never>?
    private static let maxRetries = 2

    /// - Parameter userInitiated: true when the user just turned boost on or picked a device.
    ///   Automatic restarts (launch, device changes) retry instead of switching boost off,
    ///   so a device that isn't ready yet doesn't permanently disable boosting.
    private func startEngine(userInitiated: Bool = true, attempt: Int = 0) {
        retryTask?.cancel()
        retryTask = nil
        guard let device = resolvedDevice() else {
            stopEngine()
            errorMessage = "No output device available."
            return
        }
        do {
            try engine.start(output: device, gain: BoostMath.gain(forPercent: boostPercent))
            activeDevice = device
            errorMessage = nil
        } catch {
            stopEngine()
            errorMessage = "Couldn't start boost (\(error))"
            if userInitiated {
                // Assigning inside isEnabled's own didSet won't re-run it, so persist explicitly.
                settings.isEnabled = false
                isEnabled = false
            } else if attempt < Self.maxRetries {
                retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, self.isEnabled else { return }
                    self.startEngine(userInitiated: false, attempt: attempt + 1)
                }
            }
        }
    }

    private func stopEngine() {
        retryTask?.cancel()
        retryTask = nil
        engine.stop()
        activeDevice = nil
    }

    private func devicesChanged() {
        devices = AudioDevices.outputDevices()
        guard isEnabled else { return }
        let resolved = resolvedDevice()
        if resolved?.uid != activeDevice?.uid || !engine.isRunning {
            startEngine(userInitiated: false)
        }
    }
}
