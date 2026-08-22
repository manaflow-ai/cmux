import Testing
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func canonicalAppHostPath(_ path: String) -> String {
    URL(fileURLWithPath: path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}

private func validateAppHostUserConfigurationHome(
    environment: [String: String],
    isolationRequired: Bool
) throws {
    guard isolationRequired else {
        return
    }

    #expect(environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1")
    let expectedHome = try #require(
        environment["CMUX_APP_HOST_EXPECTED_HOME"],
        "The isolated app-host launch must publish its resolved home"
    )
    let expectedXDGConfigHome = try #require(
        environment["CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME"],
        "The isolated app-host launch must publish its resolved XDG config home"
    )

    #expect(environment["HOME"] == expectedHome)
    #expect(environment["CFFIXED_USER_HOME"] == expectedHome)
    #expect(environment["XDG_CONFIG_HOME"] == expectedXDGConfigHome)
    #expect(environment["SSH_AUTH_SOCK"] == "")
    #expect(
        canonicalAppHostPath(
            FileManager.default.homeDirectoryForCurrentUser.path
        ) == canonicalAppHostPath(expectedHome)
    )
    #expect(
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first.map { canonicalAppHostPath($0.path) }
            == canonicalAppHostPath(
                URL(fileURLWithPath: expectedHome, isDirectory: true)
                    .appendingPathComponent(
                        "Library/Application Support",
                        isDirectory: true
                    ).path
            )
    )
    #expect(
        canonicalAppHostPath(
            NSString(string: "~/Library/Application Support")
                .expandingTildeInPath
        ) == canonicalAppHostPath(
            URL(fileURLWithPath: expectedHome, isDirectory: true)
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                ).path
        )
    )
}

private var appHostIsolationRequiredByBuild: Bool {
    #if CMUX_CI_APP_HOST_ISOLATION_REQUIRED
    true
    #else
    false
    #endif
}

@Suite struct MacSentryStartupPolicyTests {
    @Test func appHostUsesSchemeScopedUserConfigurationHome() throws {
        let environment = ProcessInfo.processInfo.environment
        try validateAppHostUserConfigurationHome(
            environment: environment,
            isolationRequired: appHostIsolationRequiredByBuild
                || environment["CMUX_APP_HOST_ISOLATION_REQUIRED"] == "1"
        )
    }

    @Test func appHostIsolationValidationIsOptIn() throws {
        try validateAppHostUserConfigurationHome(
            environment: [:],
            isolationRequired: false
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
