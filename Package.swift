// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CoLearner",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CoLearner",
            path: "Sources/CoLearner",
            exclude: ["Web", "library.json"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CoLearnerTests",
            dependencies: ["CoLearner"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
