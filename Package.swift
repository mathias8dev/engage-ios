// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EngageSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "EngageSDK", targets: ["EngageSDK"]),
        .library(name: "EngageCore", targets: ["EngageCore"]),
        .library(name: "EngagePush", targets: ["EngagePush"]),
        .library(name: "EngagePushServiceExtension", targets: ["EngagePushServiceExtension"]),
        .library(name: "EngageInApp", targets: ["EngageInApp"]),
        .library(name: "EngageMessageCenter", targets: ["EngageMessageCenter"]),
        .library(name: "EngageMessageCenterDivKit", targets: ["EngageMessageCenterDivKit"]),
    ],
    dependencies: [
        // Kept exactly aligned with the Android SDK's DivKit 32.60.0 contract.
        .package(url: "https://github.com/divkit/divkit-ios.git", exact: "32.60.0"),
    ],
    targets: [
        .target(
            name: "EngageSDK",
            dependencies: [
                "EngageCore",
                "EngagePush",
                "EngageInApp",
                "EngageMessageCenter",
                "EngageMessageCenterDivKit",
            ]
        ),
        .target(
            name: "EngageCore",
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.iOS])),
                .linkedFramework("Network", .when(platforms: [.iOS])),
            ]
        ),
        .target(name: "EngagePush", dependencies: ["EngageCore"]),
        // Kept extension-safe: this product does not link EngageCore or any UIApplication code.
        .target(name: "EngagePushServiceExtension"),
        .target(
            name: "EngageInApp",
            dependencies: [
                "EngageCore",
                .product(name: "DivKit", package: "divkit-ios", condition: .when(platforms: [.iOS])),
            ]
        ),
        .target(name: "EngageMessageCenter", dependencies: ["EngageCore"]),
        .target(
            name: "EngageMessageCenterDivKit",
            dependencies: [
                "EngageCore",
                "EngageMessageCenter",
                .product(name: "DivKit", package: "divkit-ios", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "EngageCoreTests", dependencies: ["EngageCore"]),
        .testTarget(name: "EngageSDKTests", dependencies: ["EngageSDK"]),
        .testTarget(name: "EngageInAppTests", dependencies: ["EngageInApp"]),
        .testTarget(name: "EngageMessageCenterTests", dependencies: ["EngageMessageCenter"]),
        .testTarget(name: "EngageMessageCenterDivKitTests", dependencies: ["EngageMessageCenterDivKit"]),
        .testTarget(name: "EngagePushTests", dependencies: ["EngagePush"]),
    ]
)
