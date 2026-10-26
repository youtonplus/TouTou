// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TouTou",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TouTou", targets: ["TouTou"])],
    targets: [
        .target(name: "QuotaAlerts"),
        .executableTarget(name: "TouTou", dependencies: ["QuotaAlerts"]),
        .testTarget(name: "QuotaAlertsTests", dependencies: ["QuotaAlerts"]),
    ]
)
