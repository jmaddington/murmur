// swift-tools-version:6.2
import PackageDescription

let coreLib = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Parakeet (and friends) on Core ML / the Neural Engine. ASR only: no TTS or diarization.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: []),
    ],
    targets: [
        .systemLibrary(name: "CMurmurCore", path: "Sources/CMurmurCore"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CMurmurCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", coreLib]),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("Speech"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
