import Foundation
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

    @Test func explicitAppHostTestMarkerPreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: ["CMUX_XCTEST_APP_HOST": "1"],
                telemetryEnabled: true
            ).shouldStart == false
        )
    }

    @Test func sharedSchemeMarksCurrentAppHostBeforeStartup() {
        #expect(ProcessInfo.processInfo.environment["CMUX_XCTEST_APP_HOST"] == "1")
    }

    @Test func activeAppHostTestRuntimePreventsSentryStartup() {
        #expect(
            MacSentryStartupPolicy(
                environment: [:],
                telemetryEnabled: true
            ).shouldStart == false
        )
    }

    @Test func noLoadedXCTestInjectionImageIsNotATestRunMarker() {
        #expect(
            !MacSentryStartupPolicy.containsLoadedXCTestInjectionImage([])
        )
    }

    @Test func loadedTestBundleExecutableIsNotTheXCTestInjectionMarker() {
        #expect(
            !MacSentryStartupPolicy.containsLoadedXCTestInjectionImage([
                "/tmp/cmux DEV.app/Contents/PlugIns/cmuxTests.xctest/Contents/MacOS/cmuxTests"
            ])
        )
    }

    @Test func loadedXCTestInjectionLibraryIsATestRunMarker() {
        #expect(
            MacSentryStartupPolicy.containsLoadedXCTestInjectionImage([
                "/tmp/cmux DEV.app/Contents/Frameworks/libXCTestBundleInject.dylib"
            ])
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
