// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "osmohdr",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "osmohdr",
            resources: [.copy("Resources/mimo_ac6_dlogm_hlg.cube")]
        )
    ],
    swiftLanguageModes: [.v5]
)
