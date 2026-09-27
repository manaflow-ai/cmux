import Darwin
import Foundation
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalSurface {
    /// SIGKILLs every process on this surface's terminal.
    ///
    /// Tests free their surfaces milliseconds after Ghostty spawns them, while
    /// login(1) still ignores SIGHUP during its startup. Closing then waits out
    /// Ghostty's whole 12 s SIGHUP grace, which is sized for agent exit hooks,
    /// before it escalates to SIGKILL. A test shell needs no graceful exit, so
    /// killing it first leaves the close nothing to wait for.
    @MainActor
    func killShellProcessesForTesting() {
        // Ghostty opens the PTY on its IO thread, so right after spawn the
        // device may not be known yet. Only a live runtime has a process.
        // Poll without running the main run loop: dispatching AppKit events
        // here leaves NSApp.currentEvent pointing at this test's window, and
        // the next test's Dock drag scopes its resize to that window.
        guard surface != nil else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while controllingTTYDeviceIdentifier == nil,
              ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        guard let device = controllingTTYDeviceIdentifier else { return }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(truncatingIfNeeded: device)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return }
        let ownGroup = getpgrp()
        for process in processes.prefix(size / stride) {
            let pid = process.kp_proc.p_pid
            guard pid > 1, pid != getpid(), process.kp_eproc.e_pgid != ownGroup else { continue }
            kill(pid, SIGKILL)
        }
    }

    /// Frees a test-hosted terminal before the test returns.
    ///
    /// A test that hosts a live terminal and just drops it hands the native
    /// free to the shared teardown coordinator, which has two close slots. A
    /// free that starts while login(1) is still ignoring SIGHUP holds its
    /// slot for Ghostty's 12 s grace, so a few such drops keep frees, and the
    /// surfaces' io threads, in flight through the tests that run next.
    /// Killing the shell and freeing synchronously ends the runtime here.
    @MainActor
    func releaseHostedSurfaceForTesting() {
        killShellProcessesForTesting()
        releaseSurfaceForTesting()
    }
}

extension TabManager {
    /// Closes a test-owned manager's workspaces the way a window close does,
    /// after killing their shells.
    ///
    /// Releasing a workspace terminal's runtime directly is not enough: the
    /// workspace still owns the panel and starts a new runtime for it on a
    /// later main-queue turn, and that runtime is then dropped with the
    /// manager, so its free waits out Ghostty's 12 s SIGHUP grace in whatever
    /// test runs next. Closing the workspaces retires the panels, and with
    /// the shells already dead their coordinator frees finish at once.
    @MainActor
    func closeWorkspacesForTesting() {
        for workspace in tabs {
            for case let terminalPanel as TerminalPanel in workspace.panels.values {
                terminalPanel.surface.killShellProcessesForTesting()
            }
        }
        finalizeAllWorkspacesForWindowClose()
    }
}
