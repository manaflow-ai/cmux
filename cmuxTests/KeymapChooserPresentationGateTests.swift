import Foundation
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private enum KeymapChooserWriteError: Error {
    case failed
}

@Suite("First-run keymap chooser presentation gate")
struct KeymapChooserPresentationGateTests {
    private let optIn = ContentView.keymapChooserTestOptInEnvironmentKey

    @Test("An ordinary launch may open the chooser")
    func plainLaunchIsAllowed() {
        #expect(ContentView.keymapChooserIsAllowedInThisProcess(environment: [:]))
        #expect(ContentView.keymapChooserIsAllowedInThisProcess(
            environment: ["HOME": "/Users/someone", "CMUX_TAG": "dev"]
        ))
    }

    @Test(
        "A test harness launch does not, since whether it would ask is machine state",
        arguments: [
            "CMUX_UI_TEST_MODE",
            "CMUX_TEST_PROCESS",
            "XCTestSessionIdentifier",
            "XCTestConfigurationFilePath",
        ]
    )
    func harnessLaunchIsSuppressed(marker: String) {
        #expect(!ContentView.keymapChooserIsAllowedInThisProcess(environment: [marker: "1"]))
    }

    @Test("A test that asks for the chooser by name gets it")
    func optInReenablesTheChooser() {
        // Without this there is no way to drive the sheet from a UI test, and
        // `scripts/ui-test` cannot capture a frame of it.
        #expect(ContentView.keymapChooserIsAllowedInThisProcess(environment: [optIn: "1"]))
        #expect(ContentView.keymapChooserIsAllowedInThisProcess(
            environment: ["CMUX_UI_TEST_MODE": "1", optIn: "1"]
        ))
    }

    @Test("Only an exact 1 opts in, so a stray value cannot surprise a test run")
    func optInRequiresExactValue() {
        for value in ["0", "", "true", "yes", "2"] {
            #expect(!ContentView.keymapChooserIsAllowedInThisProcess(
                environment: ["CMUX_UI_TEST_MODE": "1", optIn: value]
            ))
        }
    }

    @Test("The opt-in key itself reads as a UI test marker")
    func optInKeyIsANamedUITestVariable() {
        // The `CMUX_UI_TEST_` prefix is what `isRunningUnderXCTest` matches on,
        // so the opt-in has to be checked before it, not after.
        #expect(optIn.hasPrefix("CMUX_UI_TEST_"))
        #expect(MacSentryStartupPolicy.isRunningUnderXCTest(environment: [optIn: "1"]))
    }

    @Test("A failed chooser write leaves the sheet presented")
    @MainActor
    func failedWriteKeepsChooserOpen() async {
        let plan = ShortcutKeymapPreset.iTerm2.plan(
            from: ShortcutBindingsSnapshot(bindings: [:], managedActionIDs: [])
        )
        var isChooserPresented = true
        var failureReported = false

        let didApply = await ContentView.applyKeymapChooserPlan(
            plan,
            write: { throw KeymapChooserWriteError.failed },
            onFailure: { _ in failureReported = true }
        )
        if didApply {
            isChooserPresented = false
        }

        #expect(!didApply)
        #expect(failureReported)
        #expect(isChooserPresented)
    }

    @Test("An empty chooser plan is a successful no-op")
    @MainActor
    func emptyPlanDismissesChooser() async {
        let plan = ShortcutKeymapPreset.cmux.plan(
            from: ShortcutBindingsSnapshot(bindings: [:], managedActionIDs: [])
        )
        var writeAttempted = false
        var isChooserPresented = true

        let didApply = await ContentView.applyKeymapChooserPlan(
            plan,
            write: {
                writeAttempted = true
                throw KeymapChooserWriteError.failed
            }
        )
        if didApply {
            isChooserPresented = false
        }

        #expect(didApply)
        #expect(!writeAttempted)
        #expect(!isChooserPresented)
    }
}
