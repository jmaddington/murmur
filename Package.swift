// swift-tools-version:6.0
import PackageDescription

let coreLib = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    dependencies: [
        // AIDEV-NOTE: keep in step with SPARKLE_VERSION in scripts/ci/sparkle-tools.sh (sign_update/appcast).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .systemLibrary(name: "CMurmurCore", path: "Sources/CMurmurCore"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CMurmurCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Murmur",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-L", coreLib, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
