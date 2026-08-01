// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MediaPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // LGPL build — App Store-compatible licensing. Everything the player
        // uses (videotoolbox hwdec, gpu-next/Vulkan, libass, dav1d, libdovi)
        // is included; only GPL-licensed extras (x264 encoding etc.) are not.
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "0.39.0"),
    ],
    targets: [
        .executableTarget(
            name: "MediaPlayer",
            dependencies: [
                .product(name: "MPVKit", package: "MPVKit"),
            ],
            path: "Sources/MediaPlayer"
        ),
    ]
)
