import CoreGraphics
import Darwin
import DisplayDDC
import Foundation

struct DisplayModeOption: Identifiable, Equatable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var label: String {
        var components = ["\(width) × \(height)"]
        if pixelWidth > width || pixelHeight > height {
            components.append("HiDPI")
        }
        if refreshRate > 0 {
            components.append("\(Int(refreshRate.rounded())) Hz")
        }
        return components.joined(separator: " · ")
    }
}

enum DisplayBrightnessMethod: String {
    case native
    case ddc
    case software
}

final class DisplaySettingsAPI {
    private typealias GetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightnessFunction = @convention(c) (
        CGDirectDisplayID,
        Float
    ) -> Int32

    private let displayServicesHandle: UnsafeMutableRawPointer?
    private let getBrightnessFunction: GetBrightnessFunction?
    private let setBrightnessFunction: SetBrightnessFunction?
    private var ddcMaximumValues: [CGDirectDisplayID: UInt16] = [:]
    private var brightnessMethods: [CGDirectDisplayID: DisplayBrightnessMethod] = [:]
    private var originalGammaTables: [CGDirectDisplayID: GammaTable] = [:]
    private var softwareBrightnessValues: [CGDirectDisplayID: Double] = [:]
    private var eyeProtectionEnabledDisplayIDs: Set<CGDirectDisplayID> = []
    private var colorAdjustedDisplayIDs: Set<CGDirectDisplayID> = []

    init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        displayServicesHandle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL)

        if let displayServicesHandle,
           let getSymbol = dlsym(displayServicesHandle, "DisplayServicesGetBrightness"),
           let setSymbol = dlsym(displayServicesHandle, "DisplayServicesSetBrightness") {
            getBrightnessFunction = unsafeBitCast(getSymbol, to: GetBrightnessFunction.self)
            setBrightnessFunction = unsafeBitCast(setSymbol, to: SetBrightnessFunction.self)
        } else {
            getBrightnessFunction = nil
            setBrightnessFunction = nil
        }
    }

    deinit {
        if let displayServicesHandle {
            dlclose(displayServicesHandle)
        }
    }

    var brightnessAPIAvailable: Bool {
        (getBrightnessFunction != nil && setBrightnessFunction != nil) ||
            HardwareCapabilities.isAppleSilicon
    }

    func displayModes(for displayID: CGDirectDisplayID) -> [DisplayModeOption] {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return []
        }

        let currentModeID = currentModeID(for: displayID)
        var modesByKey: [DisplayModeKey: CGDisplayMode] = [:]
        for mode in modes where mode.isUsableForDesktopGUI() {
            let key = DisplayModeKey(
                width: mode.width,
                height: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                refreshRate: Int((mode.refreshRate * 100).rounded())
            )
            if modesByKey[key] == nil || mode.ioDisplayModeID == currentModeID {
                modesByKey[key] = mode
            }
        }

        return modesByKey.values
            .map { mode in
                DisplayModeOption(
                    id: mode.ioDisplayModeID,
                    width: mode.width,
                    height: mode.height,
                    pixelWidth: mode.pixelWidth,
                    pixelHeight: mode.pixelHeight,
                    refreshRate: mode.refreshRate
                )
            }
            .sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.height != $1.height { return $0.height > $1.height }
                if $0.pixelWidth != $1.pixelWidth { return $0.pixelWidth > $1.pixelWidth }
                return $0.refreshRate > $1.refreshRate
            }
    }

    func currentModeID(for displayID: CGDirectDisplayID) -> Int32? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return mode.ioDisplayModeID
    }

    func setDisplayMode(_ modeID: Int32, for displayID: CGDirectDisplayID) throws {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
              let mode = modes.first(where: { $0.ioDisplayModeID == modeID }) else {
            throw DisplaySettingsError.modeUnavailable
        }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw DisplaySettingsError.beginConfigurationFailed(beginResult)
        }

        let configureResult = CGConfigureDisplayWithDisplayMode(
            configuration,
            displayID,
            mode,
            nil
        )
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplaySettingsError.configureModeFailed(configureResult)
        }

        let completeResult = CGCompleteDisplayConfiguration(configuration, .permanently)
        guard completeResult == .success else {
            throw DisplaySettingsError.completeConfigurationFailed(completeResult)
        }
    }

    func brightness(for displayID: CGDirectDisplayID) throws -> Double {
        if let getBrightnessFunction {
            var nativeValue: Float = 0
            let nativeResult = getBrightnessFunction(displayID, &nativeValue)
            if nativeResult == 0 {
                brightnessMethods[displayID] = .native
                return Double(min(1, max(0, nativeValue)))
            }
        }

        var currentValue: UInt16 = 0
        var maximumValue: UInt16 = 0
        if PypyDDCReadBrightness(displayID, &currentValue, &maximumValue),
           maximumValue > 0 {
            ddcMaximumValues[displayID] = maximumValue
            brightnessMethods[displayID] = .ddc
            return min(1, max(0, Double(currentValue) / Double(maximumValue)))
        }

        if originalGammaTables[displayID] == nil {
            originalGammaTables[displayID] = try captureGammaTable(for: displayID)
        }
        brightnessMethods[displayID] = .software
        return softwareBrightnessValues[displayID] ?? 1
    }

    func setBrightness(_ brightness: Double, for displayID: CGDirectDisplayID) throws {
        let normalizedValue = min(1, max(0.05, brightness))

        if brightnessMethods[displayID] == .software {
            try setSoftwareBrightness(normalizedValue, for: displayID)
            return
        }

        if brightnessMethods[displayID] != .ddc, let setBrightnessFunction {
            let nativeResult = setBrightnessFunction(displayID, Float(normalizedValue))
            if nativeResult == 0 {
                brightnessMethods[displayID] = .native
                return
            }
        }

        var maximumValue = ddcMaximumValues[displayID]
        if maximumValue == nil {
            var current: UInt16 = 0
            var maximum: UInt16 = 0
            if PypyDDCReadBrightness(displayID, &current, &maximum), maximum > 0 {
                maximumValue = maximum
                ddcMaximumValues[displayID] = maximum
            }
        }

        if let maximumValue {
            let rawValue = UInt16((normalizedValue * Double(maximumValue)).rounded())
            if PypyDDCSetBrightness(displayID, rawValue) {
                brightnessMethods[displayID] = .ddc
                return
            }
        }

        try setSoftwareBrightness(normalizedValue, for: displayID)
    }

    func brightnessMethod(for displayID: CGDirectDisplayID) -> DisplayBrightnessMethod? {
        brightnessMethods[displayID]
    }

    func setEyeProtection(_ enabled: Bool, for displayID: CGDirectDisplayID) throws {
        if originalGammaTables[displayID] == nil {
            originalGammaTables[displayID] = try captureGammaTable(for: displayID)
        }

        let wasEnabled = eyeProtectionEnabledDisplayIDs.contains(displayID)
        if enabled {
            eyeProtectionEnabledDisplayIDs.insert(displayID)
        } else {
            eyeProtectionEnabledDisplayIDs.remove(displayID)
        }

        do {
            try applyColorAdjustments(for: displayID)
        } catch {
            if wasEnabled {
                eyeProtectionEnabledDisplayIDs.insert(displayID)
            } else {
                eyeProtectionEnabledDisplayIDs.remove(displayID)
            }
            throw error
        }
    }

    func restoreColorAdjustments() {
        for displayID in colorAdjustedDisplayIDs {
            guard let table = originalGammaTables[displayID] else { continue }
            try? applyGammaTable(
                table,
                redMultiplier: 1,
                greenMultiplier: 1,
                blueMultiplier: 1,
                to: displayID
            )
        }
        originalGammaTables.removeAll()
        softwareBrightnessValues.removeAll()
        eyeProtectionEnabledDisplayIDs.removeAll()
        colorAdjustedDisplayIDs.removeAll()
        brightnessMethods = brightnessMethods.filter { $0.value != .software }
    }

    private func setSoftwareBrightness(
        _ brightness: Double,
        for displayID: CGDirectDisplayID
    ) throws {
        if originalGammaTables[displayID] == nil {
            originalGammaTables[displayID] = try captureGammaTable(for: displayID)
        }
        guard originalGammaTables[displayID] != nil else {
            throw DisplaySettingsError.brightnessUnavailable
        }

        let previousBrightness = softwareBrightnessValues[displayID]
        softwareBrightnessValues[displayID] = brightness
        do {
            try applyColorAdjustments(for: displayID)
            brightnessMethods[displayID] = .software
        } catch {
            softwareBrightnessValues[displayID] = previousBrightness
            throw error
        }
    }

    private func applyColorAdjustments(for displayID: CGDirectDisplayID) throws {
        guard let table = originalGammaTables[displayID] else {
            throw DisplaySettingsError.brightnessUnavailable
        }

        let brightness = min(1, max(0.05, softwareBrightnessValues[displayID] ?? 1))
        let eyeProtectionEnabled = eyeProtectionEnabledDisplayIDs.contains(displayID)
        let greenWarmth = eyeProtectionEnabled ? 0.90 : 1.0
        let blueWarmth = eyeProtectionEnabled ? 0.72 : 1.0

        try applyGammaTable(
            table,
            redMultiplier: brightness,
            greenMultiplier: brightness * greenWarmth,
            blueMultiplier: brightness * blueWarmth,
            to: displayID
        )

        let usesSoftwareDimming = brightness < 0.999
        if usesSoftwareDimming || eyeProtectionEnabled {
            colorAdjustedDisplayIDs.insert(displayID)
        } else {
            colorAdjustedDisplayIDs.remove(displayID)
            originalGammaTables.removeValue(forKey: displayID)
            softwareBrightnessValues.removeValue(forKey: displayID)
        }
    }

    private func captureGammaTable(for displayID: CGDirectDisplayID) throws -> GammaTable {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0

        let result = red.withUnsafeMutableBufferPointer { redBuffer in
            green.withUnsafeMutableBufferPointer { greenBuffer in
                blue.withUnsafeMutableBufferPointer { blueBuffer in
                    CGGetDisplayTransferByTable(
                        displayID,
                        capacity,
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress,
                        &sampleCount
                    )
                }
            }
        }
        guard result == .success, sampleCount > 0 else {
            throw DisplaySettingsError.gammaReadFailed(result)
        }

        return GammaTable(
            red: Array(red.prefix(Int(sampleCount))),
            green: Array(green.prefix(Int(sampleCount))),
            blue: Array(blue.prefix(Int(sampleCount)))
        )
    }

    private func applyGammaTable(
        _ table: GammaTable,
        redMultiplier: Double,
        greenMultiplier: Double,
        blueMultiplier: Double,
        to displayID: CGDirectDisplayID
    ) throws {
        let redScale = CGGammaValue(min(1, max(0, redMultiplier)))
        let greenScale = CGGammaValue(min(1, max(0, greenMultiplier)))
        let blueScale = CGGammaValue(min(1, max(0, blueMultiplier)))
        let red = table.red.map { min(1, $0 * redScale) }
        let green = table.green.map { min(1, $0 * greenScale) }
        let blue = table.blue.map { min(1, $0 * blueScale) }

        let result = red.withUnsafeBufferPointer { redBuffer in
            green.withUnsafeBufferPointer { greenBuffer in
                blue.withUnsafeBufferPointer { blueBuffer in
                    CGSetDisplayTransferByTable(
                        displayID,
                        UInt32(red.count),
                        redBuffer.baseAddress,
                        greenBuffer.baseAddress,
                        blueBuffer.baseAddress
                    )
                }
            }
        }
        guard result == .success else {
            throw DisplaySettingsError.gammaSetFailed(result)
        }
    }
}

enum DisplaySettingsError: LocalizedError {
    case modeUnavailable
    case beginConfigurationFailed(CGError)
    case configureModeFailed(CGError)
    case completeConfigurationFailed(CGError)
    case brightnessUnavailable
    case brightnessReadFailed(Int32)
    case brightnessSetFailed(Int32)
    case ddcBrightnessSetFailed
    case gammaReadFailed(CGError)
    case gammaSetFailed(CGError)
    case trueToneUnavailable
    case trueToneSetFailed

    var errorDescription: String? {
        switch self {
        case .modeUnavailable:
            return "The selected resolution is no longer available."
        case .beginConfigurationFailed(let error):
            return "Could not begin the resolution change (CGError \(error.rawValue))."
        case .configureModeFailed(let error):
            return "Could not configure the selected resolution (CGError \(error.rawValue))."
        case .completeConfigurationFailed(let error):
            return "macOS could not complete the resolution change (CGError \(error.rawValue))."
        case .brightnessUnavailable:
            return "Brightness control is unavailable for this display."
        case .brightnessReadFailed(let result):
            return "Could not read display brightness (error \(result))."
        case .brightnessSetFailed(let result):
            return "Could not change display brightness (error \(result))."
        case .ddcBrightnessSetFailed:
            return "The external display did not accept the DDC/CI brightness command."
        case .gammaReadFailed(let error):
            return "Could not prepare the display color adjustment (CGError \(error.rawValue))."
        case .gammaSetFailed(let error):
            return "Could not apply the display color adjustment (CGError \(error.rawValue))."
        case .trueToneUnavailable:
            return "True Tone is unavailable for the built-in display."
        case .trueToneSetFailed:
            return "macOS did not accept the True Tone change."
        }
    }
}

private struct GammaTable {
    let red: [CGGammaValue]
    let green: [CGGammaValue]
    let blue: [CGGammaValue]
}

private struct DisplayModeKey: Hashable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Int
}
