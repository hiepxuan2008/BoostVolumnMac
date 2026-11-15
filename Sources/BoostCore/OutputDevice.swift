import CoreAudio

/// An audio device that can play sound.
public struct OutputDevice: Equatable, Identifiable, Hashable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String

    public init(id: AudioObjectID, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

/// Picks the device to boost: the preferred one if it's still connected,
/// otherwise the system default, otherwise the first available device.
public func resolveOutputDevice(preferredUID: String?,
                                available: [OutputDevice],
                                systemDefaultUID: String?) -> OutputDevice? {
    if let uid = preferredUID, let d = available.first(where: { $0.uid == uid }) { return d }
    if let uid = systemDefaultUID, let d = available.first(where: { $0.uid == uid }) { return d }
    return available.first
}
