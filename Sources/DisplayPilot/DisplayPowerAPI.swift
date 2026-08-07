import Foundation
import IOKit.pwr_mgt

/// Controls display sleep without changing the WindowServer display topology.
/// macOS exposes display sleep as a system-wide action, so built-in and
/// external displays sleep and wake together while remaining connected.
final class DisplayPowerAPI {
    private var userActivityAssertionID: IOPMAssertionID = 0

    func sleepDisplays() throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw DisplayPowerError.sleepCommandLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DisplayPowerError.sleepCommandFailed(
                process.terminationStatus,
                message?.isEmpty == false ? message : nil
            )
        }
    }

    func wakeDisplays() throws {
        let result = IOPMAssertionDeclareUserActivity(
            "PypyDisplay Wake Displays" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )
        guard result == kIOReturnSuccess else {
            throw DisplayPowerError.wakeRequestFailed(result)
        }
    }
}

enum DisplayPowerError: LocalizedError {
    case sleepCommandLaunchFailed(String)
    case sleepCommandFailed(Int32, String?)
    case wakeRequestFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .sleepCommandLaunchFailed(let message):
            return "Could not start display sleep: \(message)"
        case .sleepCommandFailed(let status, let message):
            if let message {
                return "Display sleep failed (exit \(status)): \(message)"
            }
            return "Display sleep failed (exit \(status))."
        case .wakeRequestFailed(let result):
            return "Could not wake the displays (IOReturn \(result))."
        }
    }
}
