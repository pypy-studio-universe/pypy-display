import CoreGraphics

enum DisplayIdentity {
    // WindowServer creates this headless fallback when the last physical display
    // disappears. Its vendor/model values spell "unkn" and "virt" in ASCII.
    // It keeps the graphical session alive, but it is not a display the user can see.
    private static let windowServerFallbackVendor: UInt32 = 0x756E_6B6E
    private static let windowServerFallbackModel: UInt32 = 0x7669_7274

    static func isWindowServerHeadlessFallback(_ displayID: CGDirectDisplayID) -> Bool {
        isWindowServerHeadlessFallback(
            vendorNumber: CGDisplayVendorNumber(displayID),
            modelNumber: CGDisplayModelNumber(displayID)
        )
    }

    static func isWindowServerHeadlessFallback(
        vendorNumber: UInt32,
        modelNumber: UInt32
    ) -> Bool {
        vendorNumber == windowServerFallbackVendor &&
            modelNumber == windowServerFallbackModel
    }
}
