// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "smith-doc-inspector",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SmithDoccExtractor",
            targets: ["SmithDoccExtractor"]),
        .executable(
            name: "smith-doc-inspector",
            targets: ["SmithDoccExtractorCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SmithDoccExtractor",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/smith-doc-inspector"
        ),
        .testTarget(
            name: "SmithDoccExtractorTests",
            dependencies: ["SmithDoccExtractor"]),
        .executableTarget(
            name: "SmithDoccExtractorCLI",
            dependencies: [
                "SmithDoccExtractor",
                .product(name: "ArgumentParser", package: "swift-argument-parser"), 
                .product(name: "Logging", package: "swift-log")
            ]
        ),
    ]
)
