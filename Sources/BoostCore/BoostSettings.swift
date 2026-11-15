import Foundation

/// User settings persisted in `UserDefaults`.
public final class BoostSettings {
    private enum Key {
        static let boostPercent = "boostPercent"
        static let isEnabled = "isEnabled"
        static let outputDeviceUID = "outputDeviceUID"
    }

    public static let defaultBoostPercent: Double = 200

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Boost level in percent, always within `BoostMath.range`.
    public var boostPercent: Double {
        get {
            guard defaults.object(forKey: Key.boostPercent) != nil else { return Self.defaultBoostPercent }
            return BoostMath.clampPercent(defaults.double(forKey: Key.boostPercent))
        }
        set { defaults.set(BoostMath.clampPercent(newValue), forKey: Key.boostPercent) }
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Key.isEnabled) }
        set { defaults.set(newValue, forKey: Key.isEnabled) }
    }

    /// Preferred output device UID; nil means follow the system default output.
    public var outputDeviceUID: String? {
        get { defaults.string(forKey: Key.outputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.outputDeviceUID) }
    }
}
