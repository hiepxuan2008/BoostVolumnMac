// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BoostVolume",
    platforms: [.macOS("14.4")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "BoostCore",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .executableTarget(
            name: "BoostVolume",
            dependencies: ["BoostCore"]
        ),
        .testTarget(
            name: "BoostCoreTests",
            dependencies: ["BoostCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
