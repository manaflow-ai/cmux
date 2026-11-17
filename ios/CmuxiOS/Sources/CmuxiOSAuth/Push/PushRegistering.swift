public import Foundation

/// The device-token registration seam the push coordinator drives.
///
/// Owns the opt-in flag and the device-token sync with the cmux web API.
/// ``PushRegistrationService`` is the production conformer. The seam keeps the
/// UIKit-bound coordinator (authorization + `registerForRemoteNotifications`)
/// separate from the Foundation-only network work, and lets tests substitute a
/// fake registrar.
public protocol PushRegistering: Sendable {
    /// Whether the user has opted into phone notifications.
    var isEnabled: Bool { get async }

    /// The furthest locally and remotely confirmed registration stage.
    var snapshot: PushRegistrationSnapshot { get async }

    /// A stream that immediately yields the current snapshot and every change.
    func snapshots() async -> AsyncStream<PushRegistrationSnapshot>

    /// Persist the opt-in flag, re-uploading any cached token on enable and
    /// removing it server-side on disable.
    func setEnabled(_ enabled: Bool) async

    /// Commits a coordinator-owned preference in generation order. Opt-out
    /// cleanup runs in an app-owned worker and this call awaits its bounded
    /// attempt without transferring cancellation ownership. Enabling is
    /// persisted here but must wait for ``reconcileEnabledIntent(generation:)``
    /// after iOS notification authorization succeeds.
    func applyEnabledIntent(_ enabled: Bool, generation: UInt64) async

    /// Starts backend registration for the current enabled intent after the
    /// coordinator has confirmed that iOS permits notification delivery.
    func reconcileEnabledIntent(generation: UInt64) async

    /// Cache and (when opted in) upload a freshly registered APNs device token.
    func register(deviceToken: Data) async

    /// Records a terminal APNs token-registration callback failure without
    /// retaining or exposing the system error description.
    func deviceTokenRegistrationFailed() async

    /// Re-upload the cached token (e.g. after sign-in). No-op unless opted in.
    func syncTokenIfPossible() async

    /// Remove the cached token from the server (on disable, while still
    /// signed in), authenticating through the live token provider.
    func unregisterFromServer() async

    /// Remove the cached token from the server on the sign-out path,
    /// authenticating ONLY with the credentials captured before the
    /// local-first sign-out cleared the live token provider. When either
    /// captured token is missing the request is skipped: falling back to the
    /// live provider could authenticate as a NEXT account whose sign-in raced
    /// the bounded teardown.
    func unregisterFromServer(accessToken: String?, refreshToken: String?) async

    /// Sign-out variant carrying the account id captured before local clear.
    func unregisterFromServer(
        accountID: String?,
        accessToken: String?,
        refreshToken: String?
    ) async
}
