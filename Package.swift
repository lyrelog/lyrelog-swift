// swift-tools-version: 6.0
// Lyrelog Swift SDK. No dependencies on purpose, so any app can add it by the repo URL.
import PackageDescription

let package = Package(
    name: "Lyrelog",
    platforms: [.iOS(.v16), .macOS(.v13), .tvOS(.v16), .watchOS(.v9), .visionOS(.v1)],
    products: [
        .library(name: "Lyrelog", targets: ["Lyrelog"]),
    ],
    targets: [
        // The privacy manifest ships with the library, so Xcode merges it into the app's
        // privacy report.
        .target(name: "Lyrelog", path: "Sources/Lyrelog", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "LyrelogTests", dependencies: ["Lyrelog"], path: "Tests/LyrelogTests"),
    ],
    swiftLanguageModes: [.v6]
)
