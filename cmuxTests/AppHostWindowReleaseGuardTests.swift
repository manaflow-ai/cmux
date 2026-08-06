import AppKit
import Testing

/// Guards the process-wide window-release guard installed by
/// `CmuxTestWindowReleaseGuard.m`.
///
/// AppKit defaults code-created windows to `isReleasedWhenClosed == true`,
/// which under ARC means `close()` over-releases the window and XCTest's
/// post-test autorelease-pool drain crashes the shared app host
/// (EXC_BAD_ACCESS in objc_release, reported by xcodebuild as "Restarting
/// after unexpected exit"). The guard swizzles NSWindow's designated
/// initializers so every window created in the test process defaults to
/// `isReleasedWhenClosed == false`, making test-teardown `close()` calls safe
/// regardless of whether the individual test remembered to set the flag.
@MainActor
@Suite(.serialized)
struct AppHostWindowReleaseGuardTests {
    @Test
    func testCodeCreatedWindowDefaultsToNotReleasedWhenClosed() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        #expect(
            !window.isReleasedWhenClosed,
            Comment(
                rawValue: "Test-process windows must not be released on close: ARC already owns them, " +
                    "and the extra release crashes the app host in the post-test pool drain"
            )
        )
        #expect(
            window.animationBehavior == .none,
            "Test-process windows must disable appearance animations that can outlive the window"
        )
        window.close()
    }

    @Test
    func testPanelInheritsGuardedDefault() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        #expect(!panel.isReleasedWhenClosed)
        #expect(panel.animationBehavior == .none)
        panel.close()
    }

    @Test
    func testClosedWindowSurvivesAutoreleasePoolDrain() {
        weak var weakWindow: NSWindow?
        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            weakWindow = window
            window.close()
            // Without the guard this is the exact over-release shape that
            // killed the host: close() consumed ARC's +1, and the pool drain
            // below released a deallocated window.
        }
        #expect(weakWindow == nil, "window should deallocate exactly once, with no lingering references")
    }
}

private actor AppHostInProcessParallelizationProbe {
    private var activeCaseCount = 0

    func enter() {
        activeCaseCount += 1
    }

    func hasOverlap() -> Bool {
        activeCaseCount > 1
    }

    func leave() {
        activeCaseCount -= 1
    }
}

/// Behavior-level guard for the CI runner policy. Parameterized Swift Testing
/// cases run concurrently by default, so this suite fails unless the test host
/// globally disables in-process parallelization.
struct AppHostInProcessParallelizationPolicyTests {
    private static let probe = AppHostInProcessParallelizationProbe()

    @Test(arguments: [0, 1])
    func parameterizedCasesRunSerially(_: Int) async {
        await Self.probe.enter()
        try? await Task.sleep(for: .milliseconds(250))
        let overlapped = await Self.probe.hasOverlap()
        await Self.probe.leave()

        #expect(!overlapped, "cmux app-host tests must not share process-global state concurrently")
    }
}
