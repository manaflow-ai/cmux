import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Behavioral coverage for ``AppDelegate/resolveAnalyticsIdentity`` — the pure
/// decision that keeps PostHog's distinct id in lockstep with the signed-in
/// Stack user so the desktop app correlates with iOS (which keys on the same
/// Stack user id via the analytics proxy).
@Suite struct AnalyticsIdentityResolverTests {
    @Test func authenticatedUserResolvesToIdentified() {
        #expect(
            AppDelegate.resolveAnalyticsIdentity(
                isAuthenticated: true,
                isRestoringSession: false,
                stackUserID: "user-123"
            ) == .identified("user-123")
        )
    }

    @Test func settledSignedOutResolvesToAnonymousReset() {
        // A signed-out launch after a prior identified session must actively
        // reset: the SDK persists its distinct id across launches, so leaving it
        // alone would attribute anonymous events to the previous Stack user.
        #expect(
            AppDelegate.resolveAnalyticsIdentity(
                isAuthenticated: false,
                isRestoringSession: false,
                stackUserID: nil
            ) == .anonymous
        )
    }

    @Test func restoringSessionDefersUntilSettled() {
        // A cached `currentUser` can be exposed while the session is still
        // validating (isAuthenticated == false, isRestoringSession == true).
        // Identity must not change until restore settles, so a cached-but-
        // unvalidated user is never identified.
        #expect(
            AppDelegate.resolveAnalyticsIdentity(
                isAuthenticated: false,
                isRestoringSession: true,
                stackUserID: "cached-user-7"
            ) == nil
        )
    }

    @Test func authenticatedWithEmptyOrBlankIDResolvesToAnonymous() {
        // A partially-resolved identity (empty/blank id) must not identify as "".
        #expect(
            AppDelegate.resolveAnalyticsIdentity(
                isAuthenticated: true,
                isRestoringSession: false,
                stackUserID: ""
            ) == .anonymous
        )
        #expect(
            AppDelegate.resolveAnalyticsIdentity(
                isAuthenticated: true,
                isRestoringSession: false,
                stackUserID: "   "
            ) == .anonymous
        )
    }

    @Test func preserveCachedSessionWithUserStillIdentifies() {
        // The preserve-cached-session path sets isAuthenticated == true with a
        // user but isRestoringSession == false; that is a usable signed-in state.
        #expect(
            AppDelegate.resolveAnalyticsIdentity(
                isAuthenticated: true,
                isRestoringSession: false,
                stackUserID: "user-9"
            ) == .identified("user-9")
        )
    }
}

/// Coverage for ``PostHogAnalytics/shouldResetIdentity(distinctID:anonymousID:)``,
/// the pure gate that keeps signed-out PostHog `reset()` from fragmenting a
/// perpetually-anonymous user's retention while still clearing a prior user's
/// persisted identified distinct id exactly once.
@Suite struct PostHogResetGateTests {
    @Test func resetsWhenIdentifiedDistinctIDDiffersFromAnonymous() {
        // Identified→signed-out (including after a relaunch, since the SDK
        // persists the identified id): the distinct id is the Stack user id, so
        // a reset is needed to return to anonymous.
        #expect(PostHogAnalytics.shouldResetIdentity(distinctID: "stack-user-1", anonymousID: "anon-abc"))
    }

    @Test func doesNotResetWhenAlreadyAnonymous() {
        // Perpetually-signed-out: distinct id already equals the anonymous id, so
        // resetting would needlessly mint a fresh anonymous id and split the
        // user's signed-out retention across launches.
        #expect(!PostHogAnalytics.shouldResetIdentity(distinctID: "anon-abc", anonymousID: "anon-abc"))
    }

    @Test func doesNotResetWhenDistinctIDUnknown() {
        // The SDK returns "" before it is enabled/set up; never reset on that.
        #expect(!PostHogAnalytics.shouldResetIdentity(distinctID: "", anonymousID: ""))
        #expect(!PostHogAnalytics.shouldResetIdentity(distinctID: "", anonymousID: "anon-abc"))
    }
}
