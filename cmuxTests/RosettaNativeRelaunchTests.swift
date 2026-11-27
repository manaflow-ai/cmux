#if canImport(cmux_DEV)
@testable import cmux_DEV
import Testing

@Suite struct RosettaNativeRelaunchTests {
    @Test func relaunchesWhenTranslatedAndNotYetAttempted() {
        #expect(RosettaNativeRelaunch.shouldRelaunchNatively(isTranslated: true, hasAttemptedRelaunch: false))
    }

    // The loop guard: once a native relaunch has been attempted, a process that
    // is still translated must NOT relaunch again, or it spins forever.
    @Test func doesNotRelaunchAfterAttemptEvenIfStillTranslated() {
        #expect(!RosettaNativeRelaunch.shouldRelaunchNatively(isTranslated: true, hasAttemptedRelaunch: true))
    }

    @Test func doesNotRelaunchWhenNativeAndNotAttempted() {
        #expect(!RosettaNativeRelaunch.shouldRelaunchNatively(isTranslated: false, hasAttemptedRelaunch: false))
    }

    @Test func doesNotRelaunchWhenNativeAndAttempted() {
        #expect(!RosettaNativeRelaunch.shouldRelaunchNatively(isTranslated: false, hasAttemptedRelaunch: true))
    }
}
#endif
