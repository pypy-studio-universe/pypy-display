import Carbon.HIToolbox
import Foundation

/// A Carbon hot key works globally without Accessibility or Input Monitoring
/// permission and toggles system-wide display sleep without disconnecting.
final class GlobalHotKeyManager {
    static let keyDescription = "⌃⌥⌘D"

    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            displayPilotHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerReference
        )

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x44504C54), // "DPLT"
            id: 1
        )
        let modifiers = UInt32(controlKey | optionKey | cmdKey)

        RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
    }
}

private let displayPilotHotKeyHandler: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async {
        DisplayController.current?.toggleAllDisplays()
    }
    return noErr
}
