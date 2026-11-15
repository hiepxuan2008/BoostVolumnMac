import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = BoostController()

    func applicationWillTerminate(_ notification: Notification) {
        // Tear down the tap so the original system audio is unmuted.
        controller.shutdown()
    }
}

@main
struct BoostVolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: appDelegate.controller)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}
