import AppKit
import SwiftUI

@main
struct PypyDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var displayController = DisplayController()

    var body: some Scene {
        MenuBarExtra {
            DisplayMenuView()
                .environmentObject(displayController)
        } label: {
            Image(nsImage: AppBrand.menuBarIcon)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: AppBrand.menuBarIconSide,
                    height: AppBrand.menuBarIconSide
                )
                .accessibilityLabel("PypyDisplay")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var globalHotKeyManager: GlobalHotKeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if CommandLine.arguments.contains("--diagnose") {
            let connectionAPI = DisplayConnectionAPI()
            let settingsAPI = DisplaySettingsAPI()
            let trueToneAPI = TrueToneAPI()
            print("Display sleep command: \(FileManager.default.isExecutableFile(atPath: "/usr/bin/pmset") ? "available" : "unavailable")")
            print("Display wake API: IOPMAssertionDeclareUserActivity")
            print("Apple Silicon: \(HardwareCapabilities.isAppleSilicon ? "yes" : "no")")
            print("Display connection API: \(connectionAPI.isAvailable ? "available" : "unavailable")")
            print("Display brightness API: \(settingsAPI.brightnessAPIAvailable ? "available" : "unavailable")")
            print("Built-in True Tone: \(trueToneAPI.isAvailable ? "available" : "unavailable")")
            printDisplaySettingsDiagnostics(using: settingsAPI)
            NSApp.terminate(nil)
            return
        }

        globalHotKeyManager = GlobalHotKeyManager()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DisplayController.current?.restoreManagedDisplaysForTermination()
    }

    private func printDisplaySettingsDiagnostics(using settingsAPI: DisplaySettingsAPI) {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displayIDs, &displayCount) == .success else {
            print("Active display diagnostics: unavailable")
            return
        }

        for displayID in displayIDs.prefix(Int(displayCount)) {
            let identifier = String(format: "0x%08X", displayID)
            let modeCount = settingsAPI.displayModes(for: displayID).count
            let brightnessSupported = (try? settingsAPI.brightness(for: displayID)) != nil
            let brightnessMethod = settingsAPI.brightnessMethod(for: displayID)?.rawValue
                ?? "unavailable"
            print(
                "Display \(identifier): \(modeCount) resolution modes, brightness \(brightnessSupported ? brightnessMethod : "unsupported")"
            )
        }
    }
}
