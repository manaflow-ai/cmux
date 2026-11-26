import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MenuBarProfilingLauncherTests {
    @Test
    func testMenuBarProfilingLaunchesCurrentProcessForFifteenSecondsWithoutOpeningOutput() {
        let arguments = MenuBarProfilingLauncher.arguments(pid: 1234)
        #expect(arguments == ["--pid", "1234", "--duration", "15"])
    }

    @Test
    func testMenuBarProfilingCanDeferSubmissionToProgressWindow() {
        let arguments = MenuBarProfilingLauncher.arguments(pid: 1234, submitProfile: false)
        #expect(arguments == ["--pid", "1234", "--duration", "15", "--no-submit"])
    }

    @Test
    func testMenuBarProfilingEstimatesDefaultCaptureSeconds() {
        #expect(MenuBarProfilingLauncher.estimatedCaptureSeconds() == 60)
    }
}
