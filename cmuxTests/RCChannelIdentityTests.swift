import CmuxSettings
import CmuxUpdater
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `rc` release channel (`com.cmuxterm.app.rc`, "cmux RC.app") is a fourth
/// lane next to stable, nightly, and staging. These tests pin the identity
/// surfaces that key off the channel: build flavor, socket path, icon
/// persistence, and the update feed.
final class RCChannelIdentityTests: XCTestCase {
    @MainActor
    func testBundleIconPersistenceSkipsRCBundles() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.rc",
                appBundleLastPathComponent: "cmux RC.app",
                persistenceDisabled: false
            )
        )
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.rc.candidate1",
                appBundleLastPathComponent: "cmux RC candidate1.app",
                persistenceDisabled: false
            )
        )
    }

    func testRCReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.rc",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/cmux-rc.sock")
    }

    func testDefaultSocketPathForRCBundles() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.rc",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-rc.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.rc.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-rc-tag.sock"
        )
    }

    func testDetectsRCFromBundleIdentifier() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.rc"),
            .rc
        )
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.rc.candidate1"),
            .rc
        )
    }

    func testDetectsRCFromBundleName() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux RC", bundleIdentifier: "com.cmuxterm.app"),
            .rc
        )
    }

    func testResolvedFeedDetectsRCFromInfoFeedURL() {
        let resolved = UpdateFeedResolver(hostArchitecture: .arm64).resolve(
            infoFeedURL: "https://files.cmux.com/rc/appcast.xml"
        )
        XCTAssertEqual(resolved.url, "https://files.cmux.com/rc/appcast-arm64.xml")
        XCTAssertEqual(resolved.channel, .rc)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }
}

extension GhosttyConfigPathResolverTests {
    func testCmuxAppSupportConfigURLsUseReleaseConfigForRCWithoutCurrentConfig() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let releaseConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.rc",
                    appSupportDirectory: appSupportDirectory
                ),
                [releaseConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsUseRCConfigWhenPresent() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )
            let rcConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app.rc",
                filename: "config.ghostty",
                contents: "font-size = 15\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.rc",
                    appSupportDirectory: appSupportDirectory
                ),
                [rcConfigURL]
            )
        }
    }
}
