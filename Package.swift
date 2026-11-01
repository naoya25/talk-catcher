// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "talk-catcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TalkCatcher", targets: ["TalkCatcher"])
    ],
    dependencies: [
        // Silero VAD の ONNX モデルを動かすため。MIT
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2")
    ],
    targets: [
        .target(
            name: "TalkCatcherCore",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ]
        ),
        .executableTarget(
            name: "TalkCatcher",
            dependencies: ["TalkCatcherCore"]
        ),
        .testTarget(
            name: "TalkCatcherCoreTests",
            dependencies: ["TalkCatcherCore"]
        ),
    ]
)
