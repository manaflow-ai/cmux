import Testing
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MacSentryStartupPolicyTests {
    @Test func appHostUsesSchemeScopedUserConfigurationHome() throws {
        let environment = ProcessInfo.processInfo.environment
        let expectedHome = try #require(
            environment["CMUX_APP_HOST_EXPECTED_HOME"],
            "The cmux-unit scheme must publish its resolved app-host home"
        )
        let expectedXDGConfigHome = try #require(
            environment["CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME"],
            "The cmux-unit scheme must publish its resolved XDG config home"
        )

        #expect(environment["HOME"] == expectedHome)
        #expect(environment["CFFIXED_USER_HOME"] == expectedHome)
        #expect(environment["XDG_CONFIG_HOME"] == expectedXDGConfigHome)
        #expect(FileManager.default.homeDirectoryForCurrentUser.path == expectedHome)
        #expect(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.path
                == URL(fileURLWithPath: expectedHome, isDirectory: true)
                    .appendingPathComponent(
                        "Library/Application Support",
                        isDirectory: true
                    ).path
        )
        #expect(
            NSString(string: "~/Library/Application Support")
                .expandingTildeInPath
                == URL(fileURLWithPath: expectedHome, isDirectory: true)
                    .appendingPathComponent(
                        "Library/Application Support",
                        isDirectory: true
                    ).path
        )
    }

    @Test func xctestLaunchDoesNotStartSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: true,
                allowUnderXCTest: false
            ).shouldStart == false
        )
    }

    @Test func explicitTestTelemetryOptInStartsSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: true,
                allowUnderXCTest: true
            ).shouldStart == true
        )
    }

    @Test func normalTelemetryEnabledLaunchStartsSentry() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: true,
                isRunningUnderXCTest: false,
                allowUnderXCTest: false
            ).shouldStart == true
        )
    }

    @Test func telemetryOptOutStillPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                telemetryEnabled: false,
                isRunningUnderXCTest: false,
                allowUnderXCTest: false
            ).shouldStart == false
        )
    }

    @Test func explicitUITestMarkerPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: ["CMUX_UI_TEST_PROCESS": "1"],
                telemetryEnabled: true
            ).shouldStart == false
        )
    }

    @Test func testRunnerMarkerPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: ["CMUX_TEST_PROCESS": "1"],
                telemetryEnabled: true
            ).shouldStart == false
        )
    }

    @Test func explicitTestTelemetryOptInOverridesUITestMarker() {
        #expect(
            MacSentryStartupPolicy(
                environment: [
                    "CMUX_UI_TEST_PROCESS": "1",
                    "CMUX_TEST_SENTRY_ENABLED": "1"
                ],
                telemetryEnabled: true
            ).shouldStart == true
        )
    }
}
