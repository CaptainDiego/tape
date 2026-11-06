// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tape",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Same Parakeet runtime as Murmur, so both apps share the model files
        // in ~/Library/Application Support/FluidAudio/Models. Optional traits
        // (TTS, diarization, text normalization) are left out.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.18.2", traits: [])
    ],
    targets: [
        .executableTarget(
            name: "Tape",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Tape",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // The heavy work (speech recognition) runs on the Neural
                // Engine, so optimizing Swift for size costs nothing visible.
                .unsafeFlags(["-Osize"], .when(configuration: .release)),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
            ]
        )
    ]
)
