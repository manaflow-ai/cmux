import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct MenuBarProfilingLauncherTests {
    @Test
    func testMenuBarProfilingLaunchesCurrentProcessForFifteenSecondsAndOpensOutput() {
        let arguments = MenuBarProfilingLauncher.arguments(pid: 1234)
        #expect(arguments == ["--pid", "1234", "--duration", "15", "--open-output"])
    }
}
