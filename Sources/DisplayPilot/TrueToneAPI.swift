import Darwin
import Foundation

/// CoreBrightness does not provide a public True Tone API on macOS. This wrapper
/// resolves the private client dynamically so unsupported OS versions fail safely.
final class TrueToneAPI {
    private typealias BooleanGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias BooleanSetter = @convention(c) (AnyObject, Selector, Bool) -> Bool
    private typealias VoidMethod = @convention(c) (AnyObject, Selector) -> Void

    private let frameworkHandle: UnsafeMutableRawPointer?
    private let client: NSObject?
    private let activated: Bool

    init() {
        let frameworkPath = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        frameworkHandle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL)

        guard frameworkHandle != nil,
              let clientType = NSClassFromString("CBTrueToneClient") as? NSObject.Type else {
            client = nil
            activated = false
            return
        }

        let instance = clientType.init()
        client = instance
        activated = Self.booleanValue(named: "activate", from: instance) ?? false
    }

    deinit {
        if activated, let client {
            Self.callVoidMethod(named: "deactivate", on: client)
        }
        if let frameworkHandle {
            dlclose(frameworkHandle)
        }
    }

    var isAvailable: Bool {
        guard activated, let client else { return false }
        return Self.booleanValue(named: "supported", from: client) == true &&
            Self.booleanValue(named: "available", from: client) == true &&
            Self.booleanValue(named: "supportIntegrated", from: client) == true
    }

    var isEnabled: Bool? {
        guard isAvailable, let client else { return nil }
        return Self.booleanValue(named: "enabled", from: client)
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isAvailable, let client else {
            throw DisplaySettingsError.trueToneUnavailable
        }

        let selector = NSSelectorFromString("setEnabled:")
        guard client.responds(to: selector) else {
            throw DisplaySettingsError.trueToneUnavailable
        }

        let implementation = client.method(for: selector)
        let function = unsafeBitCast(implementation, to: BooleanSetter.self)
        guard function(client, selector, enabled) else {
            throw DisplaySettingsError.trueToneSetFailed
        }
    }

    private static func booleanValue(named name: String, from object: NSObject) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: BooleanGetter.self)
        return function(object, selector)
    }

    private static func callVoidMethod(named name: String, on object: NSObject) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return }
        let implementation = object.method(for: selector)
        let function = unsafeBitCast(implementation, to: VoidMethod.self)
        function(object, selector)
    }
}
