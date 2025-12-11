// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "smith-doc-extractor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SmithDocExtractor",
            targets: ["SmithDocExtractor"]),
        .executable(
            name: "smith-doc-extractor",
            targets: ["SmithDocExtractorCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SmithDocExtractor",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/smith-doc-extractor"
        ),
        .testTarget(
            name: "SmithDocExtractorTests",
            dependencies: ["SmithDocExtractor"]),
        .executableTarget(
            name: "SmithDocExtractorCLI",
            dependencies: [
                "SmithDocExtractor",
                .product(name: "ArgumentParser", package: "swift-argument-parser"), 
                .product(name: "Logging", package: "swift-log")
            ]
        ),
    ]
)
