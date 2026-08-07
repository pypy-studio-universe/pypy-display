import CoreGraphics
import Foundation

struct DisplayDevice: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let isActive: Bool
    let isMain: Bool
    let pixelWidth: Int
    let pixelHeight: Int

    var kindLabel: String {
        isBuiltIn ? "Built-in" : "External"
    }

    var resolutionLabel: String {
        guard pixelWidth > 0, pixelHeight > 0 else { return "Unknown resolution" }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var identifierLabel: String {
        String(format: "0x%08X", id)
    }
}
