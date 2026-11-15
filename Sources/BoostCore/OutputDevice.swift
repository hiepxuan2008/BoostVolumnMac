import CoreAudio

/// An audio device that can play sound.
public struct OutputDevice: Equatable, Identifiable, Hashable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    /// Virtual (software) devices such as other audio enhancers or loopback drivers.
    /// Boosting into one can loop audio back into the tap or go nowhere.
    public let isVirtual: Bool

    public init(id: AudioObjectID, uid: String, name: String, isVirtual: Bool = false) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isVirtual = isVirtual
    }
}

/// Picks the device to boost: the preferred one if it's still connected (even if
/// virtual — the user chose it), otherwise the system default, otherwise the first
/// available device. Automatic choices never land on a virtual device.
public func resolveOutputDevice(preferredUID: String?,
                                available: [OutputDevice],
                                systemDefaultUID: String?) -> OutputDevice? {
    if let uid = preferredUID, let d = available.first(where: { $0.uid == uid }) { return d }
    let real = available.filter { !$0.isVirtual }
    if let uid = systemDefaultUID, let d = real.first(where: { $0.uid == uid }) { return d }
    return real.first
}
