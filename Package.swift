// swift-tools-version:6.1
import PackageDescription

let ff = "/opt/homebrew/opt/ffmpeg"

// Small C diagnostic tools (tools/<name>/<name>.c): FFmpeg only, no engine.
func ffmpegTool(_ name: String) -> Target {
    .executableTarget(
        name: name,
        path: "tools/\(name)",
        cSettings: [.unsafeFlags(["-I\(ff)/include", "-Wall", "-Wextra"])],
        linkerSettings: [.unsafeFlags(["-L\(ff)/lib", "-lavformat", "-lavcodec", "-lavutil"])]
    )
}

let package = Package(
    name: "player",
    platforms: [.macOS("26.0")],   // Liquid Glass UI + TrueHD/DTS:X heights need 26 (user, 2026-11-15)
    dependencies: [
        // Playback engine we are moving to (docs/tasks/aether-migration.md). Exact pin: bump on purpose.
        // All optional components on: personal build (user, 2026-11-15). They may carry Dolby / DTS
        // patent obligations for anyone distributing the app.
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.67.0",
                 traits: ["TrueHDObjectAudio", "DTSXObjectAudio", "DualLayerDolbyVision",
                          "DolbyVisionStillReshaping", "DolbyVisionFelCurves"]),
        // libass for styled ASS / SSA subtitles (the same renderer AetherPlayer uses).
        .package(url: "https://github.com/mihai8804858/swift-ass-renderer", exact: "1.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "player",
            // Our own engine (engine/) was removed 2026-11-15; playback is AetherEngine.
            dependencies: [.product(name: "AetherEngine", package: "AetherEngine"),
                           .product(name: "SwiftAssRenderer", package: "swift-ass-renderer")],
            path: "app",
            resources: [.copy("Logos")],        // rating logos (IMDb, Rotten Tomatoes, TMDB) -> player_player.bundle
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("MediaAccessibility"),
            ]
        ),
        .executableTarget(
            name: "sckcap",
            path: "tools/sckcap",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "edrplay",                // live Reference vs Bright HDR test (docs/tasks/bright-mode.md)
            path: "tools/edrplay",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation"),
                             .linkedFramework("Metal"), .linkedFramework("QuartzCore"), .linkedFramework("CoreVideo")]
        ),
        ffmpegTool("probe"),          // streams / codecs / HDR / DV config
        ffmpegTool("frameprobe"),     // bitstream HDR10 SEI + Dolby Vision RPU
        ffmpegTool("mkcc"),           // test clip with EIA-608 closed captions
    ],
    swiftLanguageModes: [.v5]      // our code predates Swift 6 strict concurrency
)
