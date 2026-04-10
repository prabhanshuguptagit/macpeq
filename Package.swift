// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPEQ",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPEQ", targets: ["MacPEQ"]),
        .executable(name: "sinetest", targets: ["sinetest"])
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
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "sinetest",
            dependencies: [],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"])
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
