// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AntiBurn",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AntiBurn", targets: ["AntiBurn"])
    ],
    targets: [
        .executableTarget(
            name: "AntiBurn",
            path: "Sources/AntiBurn",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMediaIO")
            ]
        )
    ]
)
