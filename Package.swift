// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPEQ",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPEQ", targets: ["MacPEQ"]),
        .library(name: "MacPEQLib", targets: ["MacPEQLib"])
    ],
    dependencies: [
        .package(url: "https://github.com/michaeltyson/TPCircularBuffer", from: "1.6.2"),
    ],
    targets: [
        .target(name: "CAtomics"),
        .target(
            name: "MacPEQLib",
            path: "Sources/MacPEQLib"
        ),
        .executableTarget(
            name: "MacPEQ",
            dependencies: ["TPCircularBuffer", "CAtomics", "MacPEQLib"],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"]),
                .define("RELEASE", .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .testTarget(
            name: "MacPEQTests",
            dependencies: ["MacPEQLib"]
        )
    ]
)
