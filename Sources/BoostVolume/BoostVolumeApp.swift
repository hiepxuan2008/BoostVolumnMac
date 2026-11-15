import SwiftUI

@main
struct BoostVolumeApp: App {
    var body: some Scene {
        MenuBarExtra("BoostVolume", systemImage: "speaker.wave.3.fill") {
            Button("Quit") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.window)
    }
}
