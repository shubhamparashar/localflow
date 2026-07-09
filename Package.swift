// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
    ],
    targets: [
        .target(
            name: "ExceptionCatcher",
            path: "Sources/ExceptionCatcher"
        ),
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                "ExceptionCatcher",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LocalFlow"
        ),
        .testTarget(
            name: "LocalFlowTests",
            dependencies: ["LocalFlow"],
            path: "Tests/LocalFlowTests"
        ),
    ]
)
