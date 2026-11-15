import AppKit
import BoostCore
import SwiftUI

struct MenuView: View {
    @ObservedObject var controller: BoostController

    private static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $controller.isEnabled) {
                Text("Boost").font(.headline)
            }
            .toggleStyle(.switch)

            HStack {
                Slider(value: $controller.boostPercent, in: BoostMath.range, step: 5)
                Text("\(Int(controller.boostPercent))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!controller.isEnabled)

            Picker("Output", selection: $controller.selectedDeviceUID) {
                Text("System Default").tag(String?.none)
                ForEach(controller.devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
                if let uid = controller.selectedDeviceUID,
                   !controller.devices.contains(where: { $0.uid == uid }) {
                    Text("Disconnected device").tag(String?.some(uid))
                }
            }

            Toggle("Launch at login", isOn: $controller.launchAtLogin)
                .toggleStyle(.checkbox)

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("No sound? Allow BoostVolume in Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Open Settings") { NSWorkspace.shared.open(Self.privacySettingsURL) }
                    .controlSize(.small)
            }

            Divider()

            Button("Quit BoostVolume") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct MenuBarIcon: View {
    @ObservedObject var controller: BoostController

    var body: some View {
        Image(systemName: controller.isEnabled ? "speaker.wave.3.fill" : "speaker.wave.1")
    }
}
