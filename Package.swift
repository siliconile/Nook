// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Nook",
            path: "Sources/Nook",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("EventKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
