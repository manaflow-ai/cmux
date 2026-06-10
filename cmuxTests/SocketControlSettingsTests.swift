@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class SocketControlSettingsTests: XCTestCase {
    func testMigrateModeSupportsExpandedSocketModes() {
        XCTAssertEqual(SocketControlSettings.migrateMode("off"), .off)
        XCTAssertEqual(SocketControlSettings.migrateMode("cmuxOnly"), .cmuxOnly)
        XCTAssertEqual(SocketControlSettings.migrateMode("automation"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("password"), .password)
        XCTAssertEqual(SocketControlSettings.migrateMode("allow-all"), .allowAll)

        // Legacy aliases
        XCTAssertEqual(SocketControlSettings.migrateMode("notifications"), .automation)
        XCTAssertEqual(SocketControlSettings.migrateMode("full"), .allowAll)
    }

    func testSocketModePermissions() {
        XCTAssertEqual(SocketControlMode.off.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.cmuxOnly.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.automation.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.password.socketFilePermissions, 0o600)
        XCTAssertEqual(SocketControlMode.allowAll.socketFilePermissions, 0o666)
    }

    func testInvalidEnvSocketModeDoesNotOverrideUserMode() {
        XCTAssertNil(
            SocketControlSettings.envOverrideMode(
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            )
        )
        XCTAssertEqual(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["CMUX_SOCKET_MODE": "definitely-not-a-mode"]
            ),
            .password
        )
    }

    func testStableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "stray-tag",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, SocketControlSettings.stableDefaultSocketPath)
    }

    func testTaggedDebugLaunchUsesTagDefaultWhenNoOverrideIsProvided() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "my-tag",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-my-tag.sock")
    }

    func testTaggedDebugLaunchStillHonorsSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_TAG": "my-tag",
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-forced.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug",
            isDebugBuild: true
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-forced.sock")
    }

    func testNightlyReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.nightly",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/cmux-nightly.sock")
    }

    func testTaggedDebugBundleKeepsMatchingSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-my-tag.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-my-tag.sock")
    }

    func testTaggedDebugBundleIgnoresSocketOverrideInheritedFromDifferentCmuxBundle() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.issue.4355.cmux.themes.set.state.dependent",
            isDebugBuild: true
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-issue-4355-cmux-themes-set-state-dependent.sock")
    }

    func testTaggedDebugBundleIgnoresMismatchedInheritedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-fix-grok-notifications.sock")
    }

    func testTaggedDebugBundleCanOptInToMismatchedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-nightly.sock",
                "CMUX_BUNDLE_ID": "com.cmuxterm.app.nightly",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-nightly.sock")
    }

    func testTaggedDebugBundleRefusesStableSocketOverrideEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testTaggedDebugBundleRefusesUserScopedStableSocketOverrideEvenWithOptInFlag() {
        let aliases = [
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501),
            "/private/tmp/cmux-501.sock",
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "CMUX_SOCKET_PATH": alias,
                    "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock", alias)
        }
    }

    func testTaggedDebugBundleRefusesCanonicalLegacyStableSocketAliasEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/private/tmp/cmux.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testSocketPathMatchingTreatsPrivateTmpLegacyStableAliasAsSamePath() {
        XCTAssertTrue(
            SocketControlSettings.pathsMatch(
                SocketControlSettings.legacyStableDefaultSocketPath,
                "/private/tmp/cmux.sock"
            )
        )
    }

    func testTaggedDebugBundleRefusesCaseVariantStableSocketAliasesEvenWithOptInFlag() {
        let aliases = [
            "/tmp/CMUX.sock",
            "/private/tmp/CMUX.sock",
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "cmux-501.sock", with: "CMUX-501.sock"),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "cmux-501.sock", with: "CMUX-501.sock"),
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "CMUX_SOCKET_PATH": alias,
                    "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock", alias)
        }
    }

    func testTaggedDebugBundleRefusesLeafSymlinkToStableSocketEvenWithOptInFlag() throws {
        let alias = "/tmp/cmux-stable-alias-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(
            atPath: alias,
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        defer { try? FileManager.default.removeItem(atPath: alias) }

        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": alias,
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testTaggedDebugBundleRefusesExcessiveSymlinkChainEvenWithOptInFlag() throws {
        let root = "/tmp/cmux-stable-chain-\(UUID().uuidString)"
        let aliases = (0...64).map { "\(root)-\($0).sock" }
        for alias in aliases {
            try? FileManager.default.removeItem(atPath: alias)
        }
        defer {
            for alias in aliases {
                try? FileManager.default.removeItem(atPath: alias)
            }
        }

        try FileManager.default.createSymbolicLink(
            atPath: aliases[64],
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        for index in stride(from: 63, through: 0, by: -1) {
            try FileManager.default.createSymbolicLink(
                atPath: aliases[index],
                withDestinationPath: aliases[index + 1]
            )
        }

        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": aliases[0],
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.sockguard",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-sockguard.sock")
    }

    func testStagingBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-staging-my-tag.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.staging.my-tag",
            isDebugBuild: false
        )

        XCTAssertEqual(path, "/tmp/cmux-staging-my-tag.sock")
    }

    func testStableReleaseCanOptInToSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-forced.sock",
                "CMUX_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/cmux-debug-forced.sock")
    }

    func testDefaultSocketPathByChannel() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            SocketControlSettings.stableDefaultSocketPath
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-nightly.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.nightly.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-nightly-tag.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.debug.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-debug-tag.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.staging.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-staging-tag.sock"
        )
    }

    func testStableReleaseFallsBackToUserScopedSocketWhenStablePathOwnedByDifferentUser() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 0) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchFallsBackToUserScopedSocketWhenSameUserStablePathExists() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchTreatsPrivateTmpLegacyStableAliasAsStablePath() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: "/private/tmp/cmux.sock",
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { socketPath in
                XCTAssertEqual(socketPath, "/private/tmp/cmux.sock")
                return .socket(ownerUserID: 501)
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchDoesNotProbeSameUserStableSocketLiveness() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in
                XCTFail("Existing startup sockets should fall back without liveness probing on the main thread")
                return true
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchDoesNotProbeSameUserStableSocketReclaimability() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                XCTFail("Existing startup sockets should fall back without reclaimability probing: \(socketPath)")
                return false
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialStableLaunchKeepsUserScopedPreferredPathWithoutProbing() {
        let userScopedPath = SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: userScopedPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { socketPath in
                XCTFail("User-scoped startup path should not be re-inspected: \(socketPath)")
                return .socket(ownerUserID: 501)
            },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                XCTFail("User-scoped startup path should not be reclaimed: \(socketPath)")
                return false
            }
        )

        XCTAssertEqual(path, userScopedPath)
    }

    func testInitialStableLaunchFallsBackToUserScopedSocketWhenMissingStablePathCannotBeReserved() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                XCTAssertEqual(socketPath, SocketControlSettings.stableDefaultSocketPath)
                return false
            }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testInitialSocketPathDoesNotProbeForTaggedDebugBuild() {
        let debugPath = "/tmp/cmux-debug-tag.sock"
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: debugPath,
            bundleIdentifier: "com.cmuxterm.app.debug.tag",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in
                XCTFail("Tagged debug builds must not inspect the stable socket")
                return .socket(ownerUserID: 501)
            }
        )

        XCTAssertEqual(path, debugPath)
    }

    func testStableReleaseFallsBackToUserScopedSocketWhenStablePathIsBlockedByNonSocketEntry() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .other(ownerUserID: 501) }
        )

        XCTAssertEqual(path, SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    func testUntaggedDebugBundleBlockedWithoutLaunchTag() {
        XCTAssertTrue(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testUntaggedDebugBundleAllowedWithLaunchTag() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["CMUX_TAG": "tests-v1"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testTaggedDebugBundleAllowedWithoutLaunchTag() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug.tests-v1",
                isDebugBuild: true
            )
        )
    }

    func testReleaseBuildIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: false
            )
        )
    }

    func testXCTestLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCTestInjectBundleLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["XCInjectBundle": "/tmp/fake.xctest"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCTestDyldLaunchIgnoresLaunchTagGate() {
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["DYLD_INSERT_LIBRARIES": "/usr/lib/libXCTestBundleInject.dylib"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }

    func testXCUITestLaunchEnvironmentIgnoresLaunchTagGate() {
        // XCUITest launches the app as a separate process without XCTest env vars.
        // The app receives CMUX_UI_TEST_* vars via XCUIApplication.launchEnvironment.
        XCTAssertFalse(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["CMUX_UI_TEST_MODE": "1"],
                bundleIdentifier: "com.cmuxterm.app.debug",
                isDebugBuild: true
            )
        )
    }
}

