// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MediaPlayer",
    platforms: [.macOS(.v13)],
    dependencies: [
        // GPL build: includes all decoders/filters we need (dav1d, libass, etc.)
        .package(url: "https://github.com/mpvkit/MPVKit.git", from: "0.39.0"),
    ],
    targets: [
        .executableTarget(
            name: "MediaPlayer",
            dependencies: [
                .product(name: "MPVKit-GPL", package: "MPVKit"),
            ],
            path: "Sources/MediaPlayer"
        ),
    ]
)
