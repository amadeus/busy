// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Busy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BusyApp", targets: ["BusyApp"]),
        .executable(name: "busy", targets: ["BusyCLI"]),
        .executable(name: "BusyHelper", targets: ["BusyHelper"]),
    ],
    targets: [
        .target(name: "BusyCore"),
        .executableTarget(name: "BusyApp", dependencies: ["BusyCore"]),
        .executableTarget(name: "BusyCLI", dependencies: ["BusyCore"]),
        .executableTarget(name: "BusyHelper", dependencies: ["BusyCore"]),
        .testTarget(name: "BusyCoreTests", dependencies: ["BusyCore"]),
    ]
)
