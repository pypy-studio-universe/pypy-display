// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PypyDisplay",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PypyDisplay", targets: ["PypyDisplay"])
    ],
    targets: [
        .target(
            name: "DisplayDDC",
            path: "Sources/DisplayDDC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "PypyDisplay",
            dependencies: ["DisplayDDC"],
            path: "Sources/DisplayPilot",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
