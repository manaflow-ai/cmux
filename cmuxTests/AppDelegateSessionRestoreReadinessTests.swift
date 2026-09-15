import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression guard for https://github.com/manaflow-ai/cmux/issues/2751.
//
// `AppDelegate.didCompleteInitialSessionRestore` is the readiness signal that
// gates the v2 control pre-mint pass (`TerminalController.v2RefreshKnownRefs()`
// and its `drag_surface_to_split` twin `controlSidebarRefreshKnownRefs()`):
// those skip the pre-mint while a session restore is pending or in flight so
// they never enumerate a half-built window/tab tree (the EXC_BAD_ACCESS the
// issue reported). The signal is the conjunction of two lifecycle flags:
//
//     didAttemptStartupSessionRestore && !isApplyingSessionRestore
//
// Draft 1 of the fix gated on a flag that could be TRUE before the primary
// restore actually ran on the deferred-signing-secret path, reopening the crash
// window. This test locks the four flag combinations so the signal can only be
// TRUE when restore has truly settled. It reads two Bools, so no real window or
// tab tree is needed and the crash itself (which requires a half-built tree) is
// intentionally not reproduced here.
@Suite(.serialized)
@MainActor
struct AppDelegateSessionRestoreReadinessTests {
    @Test
    func signalIsFalseBeforeRestoreIsAttempted() {
        let appDelegate = AppDelegate()
        appDelegate.didAttemptStartupSessionRestore = false
        appDelegate.isApplyingSessionRestore = false
        // Pre-attempt / deferred-signing-secret window: nothing has decided to
        // restore yet, so enumerating the tree must be skipped.
        #expect(appDelegate.didCompleteInitialSessionRestore == false)
    }

    @Test
    func signalIsFalseWhileRestoreIsInFlight() {
        let appDelegate = AppDelegate()
        appDelegate.didAttemptStartupSessionRestore = true
        appDelegate.isApplyingSessionRestore = true
        // restoreSessionSnapshot is mutating a tab manager in place; the tree is
        // half-built, so the pre-mint pass must be skipped.
        #expect(appDelegate.didCompleteInitialSessionRestore == false)
    }

    @Test
    func signalIsTrueOnceRestoreHasSettled() {
        let appDelegate = AppDelegate()
        appDelegate.didAttemptStartupSessionRestore = true
        appDelegate.isApplyingSessionRestore = false
        // completeSessionRestoreOperation has cleared the in-flight flag: the
        // tree is stable and safe to enumerate.
        #expect(appDelegate.didCompleteInitialSessionRestore == true)
    }

    @Test
    func signalIsFalseWhenApplyingWithoutAttemptFlag() {
        let appDelegate = AppDelegate()
        appDelegate.didAttemptStartupSessionRestore = false
        appDelegate.isApplyingSessionRestore = true
        // Defensive: any restore-in-flight state must read FALSE regardless of
        // the attempt flag, so the guard can never enumerate a mutating tree.
        #expect(appDelegate.didCompleteInitialSessionRestore == false)
    }
}
