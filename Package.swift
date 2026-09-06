// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ComicTranslator",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ComicTranslator", targets: ["ComicTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "ComicTranslator",
            path: "Sources/ComicTranslator",
            resources: []
        ),
        .testTarget(
            name: "ComicTranslatorTests",
            dependencies: ["ComicTranslator"],
            path: "Tests/ComicTranslatorTests"
        )
    ]
)
