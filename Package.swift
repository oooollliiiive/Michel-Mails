// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MichelMails",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MichelMails", targets: ["MichelMails"])
    ],
    targets: [
        .executableTarget(
            name: "MichelMails",
            path: "Sources/MichelMails"
        ),
        .testTarget(
            name: "MichelMailsTests",
            dependencies: ["MichelMails"],
            path: "Tests/MichelMailsTests"
        )
    ]
)
