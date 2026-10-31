// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaBar", targets: ["QuotaBar"])],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "QuotaBar", dependencies: ["QuotaCore"], path: ".",
            exclude: ["Widgets/Extension", "Sources/QuotaCore", "Tests", "Resources", "scripts", "dist", "README.md", "Package.swift", "project.yml", "QuotaBar.xcodeproj"],
            sources: ["Sources/QuotaBar", "Widgets/Shared"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaBarTests", dependencies: ["QuotaBar", "QuotaCore"])
    ],
    swiftLanguageModes: [.v5]
)
