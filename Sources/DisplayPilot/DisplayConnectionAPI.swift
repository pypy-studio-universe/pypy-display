import CoreGraphics
import Darwin
import Foundation

/// Runtime-loaded access to the session-scoped display connection operation.
/// This is used only by Apple Silicon connection-management features; normal
/// display sleep, wake, brightness, and resolution never change connections.
final class DisplayConnectionAPI {
    private typealias ConfigureDisplayEnabledFunction = @convention(c) (
        CGDisplayConfigRef,
        CGDirectDisplayID,
        Bool
    ) -> CGError

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let configureDisplayEnabled: ConfigureDisplayEnabledFunction?

    init() {
        let frameworkPath = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        frameworkHandle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL)

        if let frameworkHandle,
           let symbol = dlsym(frameworkHandle, "CGSConfigureDisplayEnabled") {
            configureDisplayEnabled = unsafeBitCast(
                symbol,
                to: ConfigureDisplayEnabledFunction.self
            )
        } else {
            configureDisplayEnabled = nil
        }
    }

    deinit {
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    var isAvailable: Bool {
        configureDisplayEnabled != nil
    }

    func setDisplay(_ displayID: CGDirectDisplayID, enabled: Bool) throws {
        guard let configureDisplayEnabled else {
            throw DisplayConnectionError.apiUnavailable
        }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw DisplayConnectionError.beginConfigurationFailed(beginResult)
        }

        let configureResult = configureDisplayEnabled(configuration, displayID, enabled)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayConnectionError.configureFailed(configureResult)
        }

        let completeResult = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard completeResult == .success else {
            throw DisplayConnectionError.completeConfigurationFailed(completeResult)
        }
    }
}

enum DisplayConnectionError: LocalizedError {
    case apiUnavailable
    case requiresAppleSilicon
    case refusingLastDisplay
    case beginConfigurationFailed(CGError)
    case configureFailed(CGError)
    case completeConfigurationFailed(CGError)

    var errorDescription: String? {
        switch self {
        case .apiUnavailable:
            return "Display connection management is unavailable on this macOS version."
        case .requiresAppleSilicon:
            return "Display connection management requires Apple Silicon."
        case .refusingLastDisplay:
            return "At least one display must remain connected."
        case .beginConfigurationFailed(let error):
            return "Could not begin the display connection change (CGError \(error.rawValue))."
        case .configureFailed(let error):
            return "Could not change the display connection (CGError \(error.rawValue))."
        case .completeConfigurationFailed(let error):
            return "macOS could not complete the display connection change (CGError \(error.rawValue))."
        }
    }
}

enum HardwareCapabilities {
    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
}
