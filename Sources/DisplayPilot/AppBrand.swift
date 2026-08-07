import AppKit

enum AppBrand {
    /// Keep a small vertical inset so the icon fills the current menu bar
    /// without touching its top or bottom edge.
    static let menuBarIconSide = max(20, floor(NSStatusBar.system.thickness - 2))

    /// The app icon has generous artwork padding. Crop that padding only for
    /// the status item so the central Pypy mark remains legible at menu-bar size.
    static let menuBarIcon: NSImage = {
        guard let source = NSApp.applicationIconImage.copy() as? NSImage else {
            return NSImage(size: NSSize(width: menuBarIconSide, height: menuBarIconSide))
        }

        let sourceSide = min(source.size.width, source.size.height)
        let cropSide = sourceSide * 0.80
        let sourceRect = NSRect(
            x: (source.size.width - cropSide) / 2,
            y: (source.size.height - cropSide) / 2,
            width: cropSide,
            height: cropSide
        )
        let targetSize = NSSize(width: menuBarIconSide, height: menuBarIconSide)
        let image = NSImage(size: targetSize, flipped: false) { targetRect in
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(
                in: targetRect,
                from: sourceRect,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = false
        return image
    }()
}
