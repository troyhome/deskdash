// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskDash",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DeskDash", targets: ["DeskDash"]),
    ],
    targets: [
        // Everything that isn't UI: drives, scanning, categories, suggestions. Tested on its own.
        .target(name: "DeskDashCore"),
        // The menu bar app, desktop widget and details window.
        .executableTarget(name: "DeskDash", dependencies: ["DeskDashCore"]),
        .testTarget(name: "DeskDashCoreTests", dependencies: ["DeskDashCore"]),
    ]
)
