// swift-tools-version: 6.0

import Foundation
import PackageDescription

// cmux-mobile-ffi's published xcframework (Packages/Shared/CmuxMobileFFI): linked
// by CmuxiOSPush once its pin names a release. The first pin comes through the
// mobile-ffi-repin pull request (scripts/cmux-next/publish-mobile-ffi-repin.sh).
let mobileFFIPinned: Bool = {
    let file = Foundation.URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../Packages/Shared/CmuxMobileFFI/mobile-ffi-pin.json")
    struct Pin: Decodable { let url: String }
    do {
        return try !Foundation.JSONDecoder().decode(Pin.self, from: Foundation.Data(contentsOf: file)).url.isEmpty
    } catch {
        fatalError("cannot read the CmuxMobileFFIFFI pin (\(file.path)): \(error)")
    }
}()
let mobileFFIPackage: [Package.Dependency] = mobileFFIPinned
    ? [.package(path: "../../Packages/Shared/CmuxMobileFFI")] : []
let mobileFFIProduct: [Target.Dependency] = mobileFFIPinned
    ? [.product(name: "CmuxMobileFFI", package: "CmuxMobileFFI")] : []

// The rewritten iOS app's modules (plans/cmux-next/ios-rewrite.md). The app
// target in ios/cmux-ios.xcodeproj links only `CmuxiOSApp`.
let package = Package(
    name: "CmuxiOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "CmuxiOSApp", targets: ["CmuxiOSApp"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxHomeCore"),
        .package(path: "../../Packages/Shared/CmuxChiefVoiceCore"),
        .package(path: "../../Packages/Shared/CmuxHomeRender"),
        .package(path: "../../Packages/Shared/CmuxFeedPushCore"),
        .package(path: "../../Packages/Shared/CmuxInstallAuthCore"),
        .package(path: "../../Packages/Shared/CmuxTextConfirmCore"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../Packages/Shared/CMUXMobileCore"),
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CmuxTerminalStream"),
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxPushRegistration"),
        .package(path: "../../Packages/macOS/CmuxPhonePush"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
    ] + mobileFFIPackage,
    targets: [
        .target(
            name: "CmuxiOSApp",
            dependencies: [
                "CmuxiOSAuth",
                "CmuxHomeUI",
                "CmuxiOSTerminal",
                "CmuxiOSDesign",
                "CmuxiOSPush",
                "CmuxiOSIdentity",
                "CmuxiOSVoice",
                .product(name: "CmuxChiefVoiceCore", package: "CmuxChiefVoiceCore"),
                .product(name: "CmuxFeedPushCore", package: "CmuxFeedPushCore"),
                "CmuxiOSTextConfirm",
                .product(name: "CmuxTextConfirmCore", package: "CmuxTextConfirmCore"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxPhonePush", package: "CmuxPhonePush"),
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSAuth",
            dependencies: [
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport"),
                .product(name: "CmuxPhonePush", package: "CmuxPhonePush"),
                .product(name: "CmuxPushRegistration", package: "CmuxPushRegistration"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // The `42` debug sign-in shortcut and auto-login exist only in DEBUG.
                .define("CMUX_DEV_AUTH", .when(configuration: .debug)),
            ]
        ),
        .target(
            name: "CmuxHomeUI",
            dependencies: [
                "CmuxiOSDesign",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeUITests",
            dependencies: [
                "CmuxHomeUI",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSTerminal",
            dependencies: [
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit"),
                .product(name: "CmuxTerminalStream", package: "CmuxTerminalStream"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // The static library carries C++ objects (glslang).
            linkerSettings: [.linkedLibrary("c++")]
        ),
        // GhosttyNextKit comes from Packages/Shared/CmuxGhosttyKit, the one
        // pin the Mac and iOS apps share (plans/cmux-next/ghostty-next-switch.md).
        .testTarget(
            name: "CmuxiOSTerminalTests",
            dependencies: ["CmuxiOSTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSPush",
            dependencies: [
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxFeedPushCore", package: "CmuxFeedPushCore"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ] + mobileFFIProduct,
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSIdentity",
            dependencies: [
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxInstallAuthCore", package: "CmuxInstallAuthCore"),
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSTextConfirm",
            dependencies: [.product(name: "CmuxTextConfirmCore", package: "CmuxTextConfirmCore")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The Action Button Chief call (plans/cmux-next/ios-action-button-DESIGN.md):
        // AVFoundation recorder, on-device speech, mic permission, call screen.
        .target(
            name: "CmuxiOSVoice",
            dependencies: [.product(name: "CmuxChiefVoiceCore", package: "CmuxChiefVoiceCore")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "CmuxiOSDesign",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
