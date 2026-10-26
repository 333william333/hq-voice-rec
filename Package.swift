// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HQVoiceRec",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CLame", path: "Sources/CLame"),
        .executableTarget(
            name: "HQVoiceRec",
            dependencies: ["CLame"],
            path: "Sources/HQVoiceRec",
            swiftSettings: [.unsafeFlags(["-Ounchecked"])],
            // Static LAME so the app has no runtime dependency on Homebrew.
            linkerSettings: [.unsafeFlags(["/opt/homebrew/lib/libmp3lame.a", "/opt/homebrew/lib/libmpg123.a"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
