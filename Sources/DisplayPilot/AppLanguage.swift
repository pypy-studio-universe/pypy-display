import CoreGraphics
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case vietnamese = "vi"
    case english = "en"

    var id: String { rawValue }
}

struct AppStrings {
    let language: AppLanguage

    private var localizationBundle: Bundle {
        guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.module
        }
        return bundle
    }

    var noDisplays: String { text("display.none", fallback: "No displays found") }
    var scanAgain: String { text("display.scan_again", fallback: "PypyDisplay will scan again in a few seconds.") }
    var rescanDisplays: String { text("display.rescan", fallback: "Rescan displays") }
    var displaysAwake: String { text("display.awake", fallback: "Displays awake") }
    var lastDisplayHelp: String {
        text("display.last_active_help", fallback: "At least one display must remain connected.")
    }
    var connectionManagement: String {
        text("connection.title", fallback: "Connection management")
    }
    var autoDisconnectBuiltIn: String {
        text("connection.auto_disconnect_built_in", fallback: "Auto-disconnect built-in display")
    }
    var autoDisconnectDescription: String {
        text(
            "connection.auto_disconnect_description",
            fallback: "Apple Silicon only. Disconnects the built-in display when an external display becomes active, then reconnects it when the last external display is removed, this option is turned off, or PypyDisplay quits."
        )
    }
    var resolution: String { text("settings.resolution", fallback: "Resolution") }
    var brightness: String { text("settings.brightness", fallback: "Brightness") }
    var softwareBrightness: String {
        text("settings.software_brightness", fallback: "Brightness (software)")
    }
    var brightnessUnavailable: String {
        text("settings.brightness_unavailable", fallback: "Not supported")
    }
    var eyeProtection: String {
        text("settings.eye_protection", fallback: "Eye protection")
    }
    var eyeProtectionHelp: String {
        text(
            "settings.eye_protection_help",
            fallback: "Reduces blue light on this display with a warmer color profile."
        )
    }
    var trueTone: String { text("settings.true_tone", fallback: "True Tone") }
    var trueToneHelp: String {
        text(
            "settings.true_tone_help",
            fallback: "Uses the Mac ambient-light sensors to adapt the built-in display."
        )
    }
    var trueToneUnavailable: String {
        text("settings.true_tone_unavailable", fallback: "Not supported")
    }
    var quit: String { text("action.quit", fallback: "Quit") }
    var languageLabel: String { text("language.label", fallback: "Language") }
    var authorLabel: String { text("author.label", fallback: "Author") }
    var unknownResolution: String { text("display.unknown_resolution", fallback: "Unknown resolution") }

    func languageName(_ option: AppLanguage) -> String {
        switch option {
        case .vietnamese:
            return text("language.vietnamese", fallback: "Vietnamese")
        case .english:
            return text("language.english", fallback: "English")
        }
    }

    func displayCount(active: Int, total: Int) -> String {
        format("display.connected_count", fallback: "%d/%d displays connected", active, total)
    }

    func displayKind(isBuiltIn: Bool) -> String {
        isBuiltIn
            ? text("display.kind.built_in", fallback: "Built-in")
            : text("display.kind.external", fallback: "External")
    }

    func connectionToggleLabel(displayName: String) -> String {
        format("display.connection_toggle", fallback: "Connection for %@", displayName)
    }

    func disconnectHelp(displayName: String) -> String {
        format("display.disconnect", fallback: "Disconnect %@", displayName)
    }

    func connectHelp(displayName: String) -> String {
        format("display.connect", fallback: "Connect %@", displayName)
    }

    func masterDescription(hotKey: String) -> String {
        return format(
            "display.master_description",
            fallback: "Turn off to sleep all displays without disconnecting them. Press any key, move the pointer, or use %@ to wake.",
            hotKey
        )
    }

    func errorMessage(for error: Error) -> String {
        if let error = error as? DisplayConnectionError {
            return connectionErrorMessage(error)
        }
        if let error = error as? DisplaySettingsError {
            return settingsErrorMessage(error)
        }
        guard let error = error as? DisplayPowerError else {
            return error.localizedDescription
        }

        switch error {
        case .sleepCommandLaunchFailed(let message):
            return format(
                "error.sleep_launch",
                fallback: "Could not start display sleep: %@",
                message
            )
        case .sleepCommandFailed(let status, let message):
            let details = message ?? "No additional details"
            return format(
                "error.sleep_failed",
                fallback: "Display sleep failed (exit %d): %@",
                status,
                details
            )
        case .wakeRequestFailed(let result):
            return format(
                "error.wake_failed",
                fallback: "Could not wake the displays (IOReturn %d).",
                result
            )
        }
    }

    private func settingsErrorMessage(_ error: DisplaySettingsError) -> String {
        switch error {
        case .modeUnavailable:
            return text(
                "error.mode_unavailable",
                fallback: "The selected resolution is no longer available."
            )
        case .beginConfigurationFailed(let cgError):
            return format(
                "error.resolution_begin",
                fallback: "Could not begin the resolution change (CGError %d).",
                cgError.rawValue
            )
        case .configureModeFailed(let cgError):
            return format(
                "error.resolution_configure",
                fallback: "Could not configure the selected resolution (CGError %d).",
                cgError.rawValue
            )
        case .completeConfigurationFailed(let cgError):
            return format(
                "error.resolution_complete",
                fallback: "macOS could not complete the resolution change (CGError %d).",
                cgError.rawValue
            )
        case .brightnessUnavailable:
            return text(
                "error.brightness_unavailable",
                fallback: "Brightness control is unavailable for this display."
            )
        case .brightnessReadFailed(let result):
            return format(
                "error.brightness_read",
                fallback: "Could not read display brightness (error %d).",
                result
            )
        case .brightnessSetFailed(let result):
            return format(
                "error.brightness_set",
                fallback: "Could not change display brightness (error %d).",
                result
            )
        case .ddcBrightnessSetFailed:
            return text(
                "error.brightness_ddc_set",
                fallback: "The external display did not accept the DDC/CI brightness command."
            )
        case .gammaReadFailed(let cgError):
            return format(
                "error.gamma_read",
                fallback: "Could not prepare the display color adjustment (CGError %d).",
                cgError.rawValue
            )
        case .gammaSetFailed(let cgError):
            return format(
                "error.gamma_set",
                fallback: "Could not apply the display color adjustment (CGError %d).",
                cgError.rawValue
            )
        case .trueToneUnavailable:
            return text(
                "error.true_tone_unavailable",
                fallback: "True Tone is unavailable for the built-in display."
            )
        case .trueToneSetFailed:
            return text(
                "error.true_tone_set",
                fallback: "macOS did not accept the True Tone change."
            )
        }
    }

    private func connectionErrorMessage(_ error: DisplayConnectionError) -> String {
        switch error {
        case .apiUnavailable:
            return text(
                "error.connection_api_unavailable",
                fallback: "Display connection management is unavailable on this macOS version."
            )
        case .requiresAppleSilicon:
            return text(
                "error.requires_apple_silicon",
                fallback: "Display connection management requires Apple Silicon."
            )
        case .refusingLastDisplay:
            return text(
                "error.last_display",
                fallback: "At least one display must remain connected."
            )
        case .beginConfigurationFailed(let cgError):
            return format(
                "error.connection_begin",
                fallback: "Could not begin the display connection change (CGError %d).",
                cgError.rawValue
            )
        case .configureFailed(let cgError):
            return format(
                "error.connection_configure",
                fallback: "Could not change the display connection (CGError %d).",
                cgError.rawValue
            )
        case .completeConfigurationFailed(let cgError):
            return format(
                "error.connection_complete",
                fallback: "macOS could not complete the display connection change (CGError %d).",
                cgError.rawValue
            )
        }
    }

    private func text(_ key: String, fallback: String) -> String {
        localizationBundle.localizedString(forKey: key, value: fallback, table: nil)
    }

    private func format(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        String(
            format: text(key, fallback: fallback),
            locale: Locale(identifier: language.rawValue),
            arguments: arguments
        )
    }
}
