// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPEQ",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPEQ", targets: ["MacPEQ"])
    ],
    dependencies: [
        .package(url: "https://github.com/michaeltyson/TPCircularBuffer", from: "1.6.2"),
    ],
    targets: [
        .executableTarget(
            name: "MacPEQ",
            dependencies: ["TPCircularBuffer"],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"])
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        )
    ]
)
