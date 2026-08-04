import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MacSentryStartupPolicyTests {
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

    @Test func embeddedAppHostTestBundlePreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: [:],
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

@Suite struct MacAppLaunchModeTests {
    @Test func normalLaunchBootstrapsMainWindow() {
        let mode = MacAppLaunchMode(environment: [:], hasEmbeddedUnitTestBundle: false)

        #expect(mode == .normal)
        #expect(mode.shouldAutomaticallyCreateMainWindow)
    }

    @Test func explicitUnitHostMarkerBootstrapsOnlyHeadlessServices() {
        let mode = MacAppLaunchMode(
            environment: ["CMUX_TEST_PROCESS": "1"],
            hasEmbeddedUnitTestBundle: false
        )

        #expect(mode == .unitTestHost)
        #expect(!mode.shouldAutomaticallyCreateMainWindow)
    }

    @Test func embeddedUnitTestBundleBootstrapsOnlyHeadlessServices() {
        let mode = MacAppLaunchMode(
            environment: [:],
            hasEmbeddedUnitTestBundle: true
        )

        #expect(mode == .unitTestHost)
        #expect(!mode.shouldAutomaticallyCreateMainWindow)
    }

    @Test func uiTestMarkerKeepsWindowBootstrapWhenUnitSignalsAreAlsoPresent() {
        let mode = MacAppLaunchMode(
            environment: [
                "CMUX_TEST_PROCESS": "1",
                "CMUX_UI_TEST_PROCESS": "1",
            ],
            hasEmbeddedUnitTestBundle: true
        )

        #expect(mode == .uiTest)
        #expect(mode.shouldAutomaticallyCreateMainWindow)
    }

    @Test func genericXCTestInjectionAloneDoesNotSuppressUIWindow() {
        let mode = MacAppLaunchMode(
            environment: ["XCTestConfigurationFilePath": "/tmp/ui-test.xctestconfiguration"],
            hasEmbeddedUnitTestBundle: false
        )

        #expect(mode == .normal)
        #expect(mode.shouldAutomaticallyCreateMainWindow)
    }
}
