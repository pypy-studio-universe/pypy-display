import AppKit
import CoreGraphics
import Foundation

private func pypyDisplayReconfigurationCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    Task { @MainActor in
        DisplayController.current?.handleDisplayReconfiguration(
            displayID: displayID,
            flags: flags
        )
    }
}

@MainActor
final class DisplayController: ObservableObject {
    static weak var current: DisplayController?

    @Published private(set) var displays: [DisplayDevice] = []
    @Published private(set) var displaysAwake = true
    @Published private(set) var autoDisconnectBuiltInDisplay: Bool
    @Published private(set) var brightnessValues: [CGDirectDisplayID: Double] = [:]
    @Published private(set) var brightnessSupportedDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var brightnessMethods: [CGDirectDisplayID: DisplayBrightnessMethod] = [:]
    @Published private(set) var modeOptions: [CGDirectDisplayID: [DisplayModeOption]] = [:]
    @Published private(set) var currentModeIDs: [CGDirectDisplayID: Int32] = [:]
    @Published private(set) var eyeProtectionEnabledDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var trueToneAvailable = false
    @Published private(set) var trueToneEnabled = false
    @Published var lastError: Error?

    private let powerAPI = DisplayPowerAPI()
    private let connectionAPI = DisplayConnectionAPI()
    private let settingsAPI = DisplaySettingsAPI()
    private let trueToneAPI = TrueToneAPI()
    private var knownNames: [CGDirectDisplayID: String] = [:]
    private var knownDisplays: [CGDirectDisplayID: DisplayDevice] = [:]
    private var managedDisplays: [CGDirectDisplayID: ManagedDisplayRecord] = [:]
    private var refreshTimer: Timer?
    private var powerObservers: [NSObjectProtocol] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var lastConnectionAttempt: ConnectionAttempt?
    private var appliedEyeProtectionDisplayIDs: Set<CGDirectDisplayID> = []
    private var displayReconfigurationCallbackRegistered = false
    private var builtInSafetyRecoveryInProgress = false
    private var builtInSafetyRecoveryRetryTask: Task<Void, Never>?
    private var builtInSafetyRecoveryRetryCount = 0

    private static let autoDisconnectPreferenceKey = "autoDisconnectBuiltInDisplay"
    private static let managedDisplaysPreferenceKey = "managedDisconnectedDisplays"
    private static let legacyManagedBuiltInIDPreferenceKey = "managedBuiltInDisplayID"
    private static let eyeProtectionPreferenceKey = "eyeProtectionDisplayIDs"

    init() {
        let diagnosticsMode = CommandLine.arguments.contains("--diagnose")
        autoDisconnectBuiltInDisplay = diagnosticsMode
            ? false
            : UserDefaults.standard.bool(forKey: Self.autoDisconnectPreferenceKey)

        if !diagnosticsMode {
            loadManagedDisplays()
            migrateLegacyManagedBuiltInDisplay()
            loadEyeProtectionPreferences()
        }

        Self.current = self
        observeDisplayPowerState()
        observeDisplayConfiguration()
        observeCoreGraphicsDisplayReconfiguration()
        if diagnosticsMode {
            print(
                "Display safety recovery: \(displayReconfigurationCallbackRegistered ? "available" : "unavailable")"
            )
        }
        refresh()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        builtInSafetyRecoveryRetryTask?.cancel()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in powerObservers {
            notificationCenter.removeObserver(observer)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if displayReconfigurationCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                pypyDisplayReconfigurationCallback,
                nil
            )
        }
    }

    var activeDisplayCount: Int {
        displays.lazy.filter(\.isActive).count
    }

    var hasBuiltInDisplay: Bool {
        displays.contains { $0.isBuiltIn }
    }

    var connectionManagementAvailable: Bool {
        HardwareCapabilities.isAppleSilicon && connectionAPI.isAvailable
    }

    func refresh() {
        let onlineIDs = getDisplayIDs(using: CGGetOnlineDisplayList)
        let activeIDs = Set(getDisplayIDs(using: CGGetActiveDisplayList))
        let screenNames = currentScreenNames()

        for (id, name) in screenNames {
            knownNames[id] = name
        }

        var externalIndex = 0
        var currentDisplays = onlineIDs.map { id in
            let builtIn = CGDisplayIsBuiltin(id) != 0
            if !builtIn { externalIndex += 1 }

            let fallbackName = builtIn ? "Mac Display" : "External Display \(externalIndex)"
            let name = screenNames[id] ?? knownNames[id] ?? fallbackName

            return DisplayDevice(
                id: id,
                name: name,
                isBuiltIn: builtIn,
                isActive: activeIDs.contains(id),
                isMain: activeIDs.contains(id) && CGMainDisplayID() == id,
                pixelWidth: Int(CGDisplayPixelsWide(id)),
                pixelHeight: Int(CGDisplayPixelsHigh(id))
            )
        }

        for display in currentDisplays {
            knownDisplays[display.id] = display
        }

        var recordsChanged = false
        for displayID in Array(managedDisplays.keys) where activeIDs.contains(displayID) {
            managedDisplays.removeValue(forKey: displayID)
            recordsChanged = true
        }
        if recordsChanged {
            saveManagedDisplays()
        }

        for record in managedDisplays.values
            where !currentDisplays.contains(where: { $0.id == record.id }) {
            currentDisplays.append(record.displayDevice(isActive: false))
        }

        displays = currentDisplays.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        refreshDisplaySettings(activeIDs: activeIDs)

        if activeIDs.isEmpty {
            restoreBuiltInDisplayForSafety()
            return
        }

        builtInSafetyRecoveryRetryTask?.cancel()
        builtInSafetyRecoveryRetryTask = nil
        builtInSafetyRecoveryRetryCount = 0

        if !autoDisconnectBuiltInDisplay,
           managedDisplays.values.contains(where: { $0.reason == .automaticBuiltIn }) {
            restoreAutomaticallyManagedBuiltInDisplay()
            return
        }

        reconcileAutomaticBuiltInDisplayConnection()
    }

    func setDisplaysAwake(_ awake: Bool) {
        lastError = nil

        do {
            if awake {
                try powerAPI.wakeDisplays()
            } else {
                try powerAPI.sleepDisplays()
            }
            displaysAwake = awake
        } catch {
            lastError = error
            displaysAwake = !awake
        }
    }

    func toggleAllDisplays() {
        setDisplaysAwake(!displaysAwake)
    }

    func resolutionOptions(for display: DisplayDevice) -> [DisplayModeOption] {
        modeOptions[display.id] ?? []
    }

    func currentModeID(for display: DisplayDevice) -> Int32 {
        currentModeIDs[display.id] ?? 0
    }

    func setResolution(_ modeID: Int32, for display: DisplayDevice) {
        guard display.isActive, modeID != currentModeIDs[display.id] else { return }
        lastError = nil

        do {
            try settingsAPI.setDisplayMode(modeID, for: display.id)
            modeOptions[display.id] = settingsAPI.displayModes(for: display.id)
            currentModeIDs[display.id] = settingsAPI.currentModeID(for: display.id)
            refresh()
        } catch {
            lastError = error
            currentModeIDs[display.id] = settingsAPI.currentModeID(for: display.id)
        }
    }

    func brightness(for display: DisplayDevice) -> Double {
        brightnessValues[display.id] ?? 0.5
    }

    func supportsBrightness(for display: DisplayDevice) -> Bool {
        display.isActive && brightnessSupportedDisplayIDs.contains(display.id)
    }

    func usesSoftwareBrightness(for display: DisplayDevice) -> Bool {
        brightnessMethods[display.id] == .software
    }

    func setBrightness(_ brightness: Double, for display: DisplayDevice) {
        guard supportsBrightness(for: display) else { return }
        lastError = nil
        let clampedValue = min(1, max(0.05, brightness))
        brightnessValues[display.id] = clampedValue

        do {
            try settingsAPI.setBrightness(clampedValue, for: display.id)
        } catch {
            lastError = error
            if let currentBrightness = try? settingsAPI.brightness(for: display.id) {
                brightnessValues[display.id] = currentBrightness
            }
        }
    }

    func eyeProtectionEnabled(for display: DisplayDevice) -> Bool {
        eyeProtectionEnabledDisplayIDs.contains(display.id)
    }

    func setEyeProtection(_ enabled: Bool, for display: DisplayDevice) {
        guard display.isActive else { return }
        lastError = nil

        do {
            try settingsAPI.setEyeProtection(enabled, for: display.id)
            if enabled {
                eyeProtectionEnabledDisplayIDs.insert(display.id)
                appliedEyeProtectionDisplayIDs.insert(display.id)
            } else {
                eyeProtectionEnabledDisplayIDs.remove(display.id)
                appliedEyeProtectionDisplayIDs.remove(display.id)
            }
            saveEyeProtectionPreferences()
        } catch {
            lastError = error
        }
    }

    func supportsTrueTone(for display: DisplayDevice) -> Bool {
        display.isBuiltIn && display.isActive && trueToneAvailable
    }

    func setTrueTone(_ enabled: Bool, for display: DisplayDevice) {
        guard display.isBuiltIn, display.isActive else { return }
        lastError = nil

        do {
            try trueToneAPI.setEnabled(enabled)
            trueToneEnabled = enabled
        } catch {
            lastError = error
            trueToneEnabled = trueToneAPI.isEnabled ?? false
        }
    }

    func canChangeConnection(of display: DisplayDevice) -> Bool {
        guard connectionManagementAvailable else { return false }
        guard display.isActive else { return managedDisplays[display.id] != nil }
        if activeDisplayCount > 1 { return true }
        return !display.isBuiltIn && managedBuiltInDisplayRecord != nil
    }

    func setDisplayConnection(_ display: DisplayDevice, enabled: Bool) {
        lastError = nil
        lastConnectionAttempt = nil

        guard connectionManagementAvailable else {
            lastError = HardwareCapabilities.isAppleSilicon
                ? DisplayConnectionError.apiUnavailable
                : DisplayConnectionError.requiresAppleSilicon
            return
        }

        do {
            if enabled {
                if display.isBuiltIn && autoDisconnectBuiltInDisplay {
                    autoDisconnectBuiltInDisplay = false
                    UserDefaults.standard.set(false, forKey: Self.autoDisconnectPreferenceKey)
                }
                try applyConnectionChange(
                    displayID: display.id,
                    enabled: true,
                    reason: .manual
                )
            } else {
                let liveActiveIDs = Set(getDisplayIDs(using: CGGetActiveDisplayList))
                guard liveActiveIDs.contains(display.id) else {
                    refresh()
                    return
                }

                if liveActiveIDs.subtracting([display.id]).isEmpty {
                    guard !display.isBuiltIn,
                          let builtInRecord = managedBuiltInDisplayRecord else {
                        throw DisplayConnectionError.refusingLastDisplay
                    }
                    try applyConnectionChange(
                        displayID: builtInRecord.id,
                        enabled: true,
                        reason: builtInRecord.reason
                    )
                }

                try applyConnectionChange(
                    displayID: display.id,
                    enabled: false,
                    reason: .manual
                )
            }
            scheduleRefreshAfterConnectionChange()
        } catch {
            lastError = error
            refresh()
        }
    }

    func setAutoDisconnectBuiltInDisplay(_ enabled: Bool) {
        lastError = nil
        lastConnectionAttempt = nil

        guard !enabled || HardwareCapabilities.isAppleSilicon else {
            lastError = DisplayConnectionError.requiresAppleSilicon
            return
        }
        guard !enabled || connectionAPI.isAvailable else {
            lastError = DisplayConnectionError.apiUnavailable
            return
        }

        autoDisconnectBuiltInDisplay = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoDisconnectPreferenceKey)

        if enabled {
            reconcileAutomaticBuiltInDisplayConnection()
        } else {
            restoreAutomaticallyManagedBuiltInDisplay()
        }
    }

    func restoreManagedDisplaysForTermination() {
        settingsAPI.restoreColorAdjustments()
        let records = managedDisplays.values.sorted { $0.isBuiltIn && !$1.isBuiltIn }
        for record in records {
            do {
                try connectionAPI.setDisplay(record.id, enabled: true)
                managedDisplays.removeValue(forKey: record.id)
            } catch {
                continue
            }
        }
        saveManagedDisplays()
    }

    private var managedBuiltInDisplayRecord: ManagedDisplayRecord? {
        managedDisplays.values.first(where: \.isBuiltIn)
    }

    private func observeDisplayPowerState() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        powerObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAwake = false
                }
            }
        )

        powerObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.displaysAwake = true
                    self?.appliedEyeProtectionDisplayIDs.removeAll()
                    self?.refresh()
                }
            }
        )
    }

    private func refreshDisplaySettings(activeIDs: Set<CGDirectDisplayID>) {
        modeOptions = modeOptions.filter { activeIDs.contains($0.key) }
        currentModeIDs = currentModeIDs.filter { activeIDs.contains($0.key) }
        brightnessMethods = brightnessMethods.filter { activeIDs.contains($0.key) }
        appliedEyeProtectionDisplayIDs.formIntersection(activeIDs)

        var updatedBrightnessValues = brightnessValues.filter { activeIDs.contains($0.key) }
        var supportedBrightnessIDs = Set<CGDirectDisplayID>()

        for displayID in activeIDs {
            if modeOptions[displayID] == nil {
                modeOptions[displayID] = settingsAPI.displayModes(for: displayID)
            }
            currentModeIDs[displayID] = settingsAPI.currentModeID(for: displayID)

            if let brightness = try? settingsAPI.brightness(for: displayID) {
                updatedBrightnessValues[displayID] = brightness
                supportedBrightnessIDs.insert(displayID)
                brightnessMethods[displayID] = settingsAPI.brightnessMethod(for: displayID)
            }

            if eyeProtectionEnabledDisplayIDs.contains(displayID),
               !appliedEyeProtectionDisplayIDs.contains(displayID) {
                do {
                    try settingsAPI.setEyeProtection(true, for: displayID)
                    appliedEyeProtectionDisplayIDs.insert(displayID)
                } catch {
                    eyeProtectionEnabledDisplayIDs.remove(displayID)
                    saveEyeProtectionPreferences()
                    if lastError == nil {
                        lastError = error
                    }
                }
            }
        }

        brightnessValues = updatedBrightnessValues
        brightnessSupportedDisplayIDs = supportedBrightnessIDs
        refreshTrueToneState()
    }

    private func refreshTrueToneState() {
        let hasActiveBuiltInDisplay = displays.contains { $0.isBuiltIn && $0.isActive }
        trueToneAvailable = hasActiveBuiltInDisplay && trueToneAPI.isAvailable
        trueToneEnabled = trueToneAvailable ? (trueToneAPI.isEnabled ?? false) : false
    }

    private func observeDisplayConfiguration() {
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.appliedEyeProtectionDisplayIDs.removeAll()
                self?.refresh()
            }
        }
    }

    private func observeCoreGraphicsDisplayReconfiguration() {
        let result = CGDisplayRegisterReconfigurationCallback(
            pypyDisplayReconfigurationCallback,
            nil
        )
        displayReconfigurationCallbackRegistered = result == .success
    }

    fileprivate func handleDisplayReconfiguration(
        displayID: CGDirectDisplayID,
        flags: CGDisplayChangeSummaryFlags
    ) {
        if flags.contains(.beginConfigurationFlag) {
            return
        }

        guard flags.contains(.removeFlag) ||
              flags.contains(.disabledFlag) ||
              flags.contains(.enabledFlag) else {
            return
        }

        appliedEyeProtectionDisplayIDs.remove(displayID)
        lastConnectionAttempt = nil
        refresh()
    }

    private func restoreBuiltInDisplayForSafety() {
        guard connectionManagementAvailable,
              !builtInSafetyRecoveryInProgress,
              builtInSafetyRecoveryRetryTask == nil else {
            return
        }

        let liveActiveIDs = Set(getDisplayIDs(using: CGGetActiveDisplayList))
        let managedRecord = managedBuiltInDisplayRecord
        let builtInDisplayID = managedRecord?.id
            ?? displays.first(where: { $0.isBuiltIn })?.id
            ?? knownDisplays.values.first(where: { $0.isBuiltIn })?.id

        guard let builtInDisplayID,
              !liveActiveIDs.contains(builtInDisplayID) else {
            return
        }

        builtInSafetyRecoveryInProgress = true
        defer { builtInSafetyRecoveryInProgress = false }

        do {
            try applyConnectionChange(
                displayID: builtInDisplayID,
                enabled: true,
                reason: managedRecord?.reason ?? .manual
            )
            lastConnectionAttempt = nil
            lastError = nil
            builtInSafetyRecoveryRetryTask?.cancel()
            builtInSafetyRecoveryRetryTask = nil
            builtInSafetyRecoveryRetryCount = 0
            try? powerAPI.wakeDisplays()
            displaysAwake = true
            scheduleRefreshAfterConnectionChange()
        } catch {
            lastError = error
            lastConnectionAttempt = nil
            if getDisplayIDs(using: CGGetActiveDisplayList).isEmpty {
                scheduleBuiltInSafetyRecoveryRetry()
            }
        }
    }

    private func scheduleBuiltInSafetyRecoveryRetry() {
        guard builtInSafetyRecoveryRetryTask == nil else { return }

        let retryDelays: [Int64] = [350, 700, 1_400, 2_500]
        let retryDelay = retryDelays[
            min(builtInSafetyRecoveryRetryCount, retryDelays.count - 1)
        ]
        builtInSafetyRecoveryRetryCount += 1

        builtInSafetyRecoveryRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(retryDelay))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.builtInSafetyRecoveryRetryTask = nil

            let liveActiveIDs = self.getDisplayIDs(using: CGGetActiveDisplayList)
            guard liveActiveIDs.isEmpty else {
                self.builtInSafetyRecoveryRetryCount = 0
                return
            }
            self.restoreBuiltInDisplayForSafety()
        }
    }

    private func reconcileAutomaticBuiltInDisplayConnection() {
        guard autoDisconnectBuiltInDisplay, connectionManagementAvailable,
              let builtInDisplay = displays.first(where: \.isBuiltIn) else {
            return
        }

        let activeExternalIDs = displays
            .filter { !$0.isBuiltIn && $0.isActive }
            .map(\.id)
            .sorted()

        if !activeExternalIDs.isEmpty && builtInDisplay.isActive {
            performAutomaticConnectionChange(
                displayID: builtInDisplay.id,
                enabled: false,
                externalIDs: activeExternalIDs
            )
        } else if activeExternalIDs.isEmpty,
                  !builtInDisplay.isActive,
                  let record = managedBuiltInDisplayRecord,
                  record.reason == .automaticBuiltIn || activeDisplayCount == 0 {
            performAutomaticConnectionChange(
                displayID: builtInDisplay.id,
                enabled: true,
                externalIDs: []
            )
        } else {
            lastConnectionAttempt = nil
        }
    }

    private func restoreAutomaticallyManagedBuiltInDisplay() {
        guard let record = managedDisplays.values.first(where: {
            $0.isBuiltIn && $0.reason == .automaticBuiltIn
        }) else { return }

        performAutomaticConnectionChange(
            displayID: record.id,
            enabled: true,
            externalIDs: []
        )
    }

    private func performAutomaticConnectionChange(
        displayID: CGDirectDisplayID,
        enabled: Bool,
        externalIDs: [CGDirectDisplayID]
    ) {
        let attempt = ConnectionAttempt(
            displayID: displayID,
            enabled: enabled,
            externalIDs: externalIDs
        )
        guard attempt != lastConnectionAttempt else { return }
        lastConnectionAttempt = attempt

        do {
            try applyConnectionChange(
                displayID: displayID,
                enabled: enabled,
                reason: .automaticBuiltIn
            )
            scheduleRefreshAfterConnectionChange()
        } catch {
            lastError = error
            lastConnectionAttempt = nil
            if enabled && getDisplayIDs(using: CGGetActiveDisplayList).isEmpty {
                scheduleBuiltInSafetyRecoveryRetry()
            }
        }
    }

    private func applyConnectionChange(
        displayID: CGDirectDisplayID,
        enabled: Bool,
        reason: ManagedDisplayReason
    ) throws {
        let previousRecord = managedDisplays[displayID]

        if !enabled {
            rememberManagedDisplay(displayID, reason: reason)
        }

        do {
            try connectionAPI.setDisplay(displayID, enabled: enabled)
            if enabled {
                managedDisplays.removeValue(forKey: displayID)
                saveManagedDisplays()
            }
        } catch {
            if let previousRecord {
                managedDisplays[displayID] = previousRecord
            } else {
                managedDisplays.removeValue(forKey: displayID)
            }
            saveManagedDisplays()
            throw error
        }
    }

    private func rememberManagedDisplay(
        _ displayID: CGDirectDisplayID,
        reason: ManagedDisplayReason
    ) {
        let display = displays.first(where: { $0.id == displayID })
            ?? knownDisplays[displayID]
        let record = ManagedDisplayRecord(
            id: displayID,
            name: display?.name ?? "Display",
            isBuiltIn: display?.isBuiltIn ?? (CGDisplayIsBuiltin(displayID) != 0),
            pixelWidth: display?.pixelWidth ?? Int(CGDisplayPixelsWide(displayID)),
            pixelHeight: display?.pixelHeight ?? Int(CGDisplayPixelsHigh(displayID)),
            reason: reason
        )
        managedDisplays[displayID] = record
        saveManagedDisplays()
    }

    private func scheduleRefreshAfterConnectionChange() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.lastConnectionAttempt = nil
            self?.refresh()
        }
    }

    private func loadManagedDisplays() {
        guard let data = UserDefaults.standard.data(forKey: Self.managedDisplaysPreferenceKey),
              let records = try? JSONDecoder().decode([ManagedDisplayRecord].self, from: data) else {
            return
        }
        managedDisplays = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private func saveManagedDisplays() {
        let records = managedDisplays.values.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.managedDisplaysPreferenceKey)
    }

    private func loadEyeProtectionPreferences() {
        let storedIDs = UserDefaults.standard.array(
            forKey: Self.eyeProtectionPreferenceKey
        ) as? [NSNumber] ?? []
        eyeProtectionEnabledDisplayIDs = Set(storedIDs.map(\.uint32Value))
    }

    private func saveEyeProtectionPreferences() {
        let storedIDs = eyeProtectionEnabledDisplayIDs
            .sorted()
            .map { NSNumber(value: $0) }
        UserDefaults.standard.set(storedIDs, forKey: Self.eyeProtectionPreferenceKey)
    }

    private func migrateLegacyManagedBuiltInDisplay() {
        let defaults = UserDefaults.standard
        guard let storedID = defaults.object(
            forKey: Self.legacyManagedBuiltInIDPreferenceKey
        ) as? NSNumber else { return }

        let displayID = storedID.uint32Value
        if managedDisplays[displayID] == nil {
            managedDisplays[displayID] = ManagedDisplayRecord(
                id: displayID,
                name: "Mac Display",
                isBuiltIn: true,
                pixelWidth: Int(CGDisplayPixelsWide(displayID)),
                pixelHeight: Int(CGDisplayPixelsHigh(displayID)),
                reason: .automaticBuiltIn
            )
            saveManagedDisplays()
        }
        defaults.removeObject(forKey: Self.legacyManagedBuiltInIDPreferenceKey)
    }

    private func getDisplayIDs(
        using getter: (
            UInt32,
            UnsafeMutablePointer<CGDirectDisplayID>?,
            UnsafeMutablePointer<UInt32>?
        ) -> CGError
    ) -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        let result = getter(UInt32(ids.count), &ids, &count)
        guard result == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private func currentScreenNames() -> [CGDirectDisplayID: String] {
        Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
            return (number.uint32Value, screen.localizedName)
        })
    }
}

private struct ConnectionAttempt: Equatable {
    let displayID: CGDirectDisplayID
    let enabled: Bool
    let externalIDs: [CGDirectDisplayID]
}

private enum ManagedDisplayReason: String, Codable {
    case manual
    case automaticBuiltIn
}

private struct ManagedDisplayRecord: Codable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let reason: ManagedDisplayReason

    func displayDevice(isActive: Bool) -> DisplayDevice {
        DisplayDevice(
            id: id,
            name: name,
            isBuiltIn: isBuiltIn,
            isActive: isActive,
            isMain: false,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}
