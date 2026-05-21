// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Shade",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "Shade",
            swiftSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Shade/Info.plist"
                ])
            ]
        )
    ]
)
