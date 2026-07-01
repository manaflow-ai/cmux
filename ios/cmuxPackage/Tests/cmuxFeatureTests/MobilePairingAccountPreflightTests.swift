import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// The QR account-binding preflight (#6028) across auth channels, for
/// https://github.com/manaflow-ai/cmux/issues/7145: a dev (development auth
/// environment) build scanning a release Mac's QR always fails the user-id
/// binding — Stack ids are per-project — and used to surface the misleading
/// "make sure both devices are signed in with the same email" copy even though
/// the emails matched. The preflight must report that case as
/// ``MobilePairingFailureCategory/authEnvironmentMismatch`` (truthful cause +
/// the --prod-auth remedy) while leaving the production↔production binding
/// exactly as strict as before.
@MainActor
@Suite struct MobilePairingAccountPreflightTests {
    private func ticket(macUserID: String? = nil, macUserEmail: String? = nil) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            routes: [
                CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
                ),
            ]
        )
    }

    @Test func devChannelUserIDMismatchNamesTheAuthEnvironment() throws {
        // A release Mac's QR carries its production Stack user id; the phone's
        // dev-channel id can never equal it, same email or not. The failure
        // must name the actual cause and remedy instead of telling the user to
        // re-check emails (which do match).
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-id"),
            actualUserID: "dev-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .authEnvironmentMismatch)
        let message = try #require(category?.message)
        #expect(message.contains("development auth environment"))
        #expect(message != MobilePairingFailureCategory.authFailed.message)
        #expect(!message.contains("Make sure both devices are signed in"))
        #expect(category?.guidance?.contains("--prod-auth") == true)
        #expect(category?.analyticsReason == "auth_environment_mismatch")
        // Re-authenticating cannot move the account to another Stack project,
        // so this must not drive the Sign Out re-auth prompt.
        #expect(category?.isAuthorizationFailure == false)
    }

    @Test func productionChannelUserIDMismatchKeepsAuthFailed() throws {
        // The #6028 binding for prod↔prod stays exactly as strict and keeps
        // its copy: same project, different ids means genuinely different
        // accounts, so "same email" advice is correct there.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-a"),
            actualUserID: "prod-user-b",
            actualEmail: "phone@example.com",
            isDevelopmentAuthEnvironment: false
        )

        #expect(category == .authFailed)
    }

    @Test func devChannelMatchingUserIDsProceed() throws {
        // A --prod-auth rebuilt dev build (or dev↔dev pairing) with the same
        // account must keep pairing: the channel flag only re-labels failures,
        // it never fails a matching binding.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "user-1"),
            actualUserID: "user-1",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == nil)
    }

    @Test func devChannelUnknownLocalIdentityStillProceeds() throws {
        // Signed out / identity still restoring: the preflight stays silent and
        // rejection remains the host's Stack-token verification, unchanged
        // from the production-channel behavior.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-id"),
            actualUserID: nil,
            actualEmail: nil,
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == nil)
    }

    @Test func legacyEmailTicketKeepsEmailMismatchOnDevChannel() throws {
        // Tickets without the opaque id binding compare emails; the channel
        // flag must not reroute that legacy path.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserEmail: "mac@example.com"),
            actualUserID: nil,
            actualEmail: "phone@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .emailMismatch(expected: "mac@example.com", actual: "phone@example.com"))
    }
}
