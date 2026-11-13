// swift-tools-version:6.0
import PackageDescription

let coreLib = Context.packageDirectory + "/core/target/release"

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    targets: [
        .systemLibrary(name: "CMurmurCore", path: "Sources/CMurmurCore"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["CMurmurCore"],
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
