// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackHarbor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TrackHarbor", targets: ["TrackHarbor"])
    ],
    targets: [
        .executableTarget(
            name: "TrackHarbor",
            path: "Sources/TrackHarbor"
        )
    ]
)
