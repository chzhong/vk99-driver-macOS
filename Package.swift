// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VK99Mac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "vk99", targets: ["VK99Mac"])],
    targets: [
        .target(name: "VK99Core"),
        .executableTarget(name: "VK99Mac", dependencies: ["VK99Core"]),
        .executableTarget(name: "VK99CoreCheck", dependencies: ["VK99Core"], path: "Checks")
    ]
)
