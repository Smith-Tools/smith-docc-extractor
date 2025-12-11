// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "smith-docs",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SmithDocs",
            targets: ["SmithDocs"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "SmithDocs",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources/smith-docs"
        ),
        .testTarget(
            name: "SmithDocsTests",
            dependencies: ["SmithDocs"]),
    ]
)
