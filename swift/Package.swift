// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "run-spirit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "run-spirit",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
    ]
)
