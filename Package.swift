// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NotchAgents",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "NotchAgents",
            path: "Sources/NotchAgents",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
