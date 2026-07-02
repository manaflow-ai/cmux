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
/// the --prod-auth remedy), keyed on the Mac's DECLARED channel (the pairing
/// URL scheme, #6038) plus the phone's resolved auth environment — never
/// inferred from the phone alone — while leaving the production↔production
/// and dev↔dev bindings exactly as strict as before.
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

    @Test func devPhoneScanningReleaseMacQRNamesTheAuthEnvironment() throws {
        // A release Mac's QR (scheme cmux-ios) carries its production Stack
        // user id; the phone's dev-channel id can never equal it, same email
        // or not. The failure must name the actual cause and remedy instead of
        // telling the user to re-check emails (which do match).
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-id"),
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: "dev-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .authEnvironmentMismatch(macChannelIsRelease: true))
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

    @Test func prodPhoneScanningDevMacQRNamesTheAuthEnvironmentToo() throws {
        // The reverse direction: a production-auth phone (TestFlight, or a
        // --prod-auth dev build) scanning a dev Mac's QR (scheme cmux-ios-dev)
        // hits the same per-project impossibility and must get the truthful
        // channel copy — not the "same email" advice.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "dev-user-id"),
            scannedScheme: CmxPairingURLScheme.development,
            actualUserID: "prod-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: false
        )

        #expect(category == .authEnvironmentMismatch(macChannelIsRelease: false))
        let message = try #require(category?.message)
        #expect(message.contains("development auth environment"))
        #expect(!message.contains("Make sure both devices are signed in"))
        #expect(category?.guidance?.contains("release cmux app") == true)
        #expect(category?.isAuthorizationFailure == false)
    }

    @Test func schemeComparisonIsCaseInsensitive() throws {
        // URL schemes are case-insensitive; a re-encoded/uppercased link must
        // not lose the truthful classification.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-id"),
            scannedScheme: "CMUX-IOS",
            actualUserID: "dev-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .authEnvironmentMismatch(macChannelIsRelease: true))
    }

    @Test func devPhoneScanningDevMacQRMismatchIsAGenuineAccountFailure() throws {
        // dev↔dev (scheme cmux-ios-dev): both ids come from the development
        // Stack project, so a mismatch means genuinely different accounts —
        // the #6028 copy ("same email") is correct there, and the
        // cross-channel explanation would be factually wrong.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "dev-user-a"),
            scannedScheme: CmxPairingURLScheme.development,
            actualUserID: "dev-user-b",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .authFailed)
    }

    @Test func unknownSchemeFailsSafeToAuthFailed() throws {
        // No declared Mac channel (nil scheme): never infer cross-environment
        // from the phone's flag alone — keep the pre-#7145 classification.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-id"),
            scannedScheme: nil,
            actualUserID: "dev-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .authFailed)
    }

    @Test func productionChannelUserIDMismatchKeepsAuthFailed() throws {
        // The #6028 binding for prod↔prod stays exactly as strict and keeps
        // its copy: same project, different ids means genuinely different
        // accounts, so "same email" advice is correct there.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "prod-user-a"),
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: "prod-user-b",
            actualEmail: "phone@example.com",
            isDevelopmentAuthEnvironment: false
        )

        #expect(category == .authFailed)
    }

    @Test func devChannelMatchingUserIDsProceed() throws {
        // A --prod-auth rebuilt dev build (or dev↔dev pairing) with the same
        // account must keep pairing: the channel comparison only re-labels
        // failures, it never fails a matching binding.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserID: "user-1"),
            scannedScheme: CmxPairingURLScheme.release,
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
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: nil,
            actualEmail: nil,
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == nil)
    }

    @Test func legacyEmailTicketKeepsEmailMismatchOnDevChannel() throws {
        // Tickets without the opaque id binding compare emails; the channel
        // comparison must not reroute that legacy path.
        let category = MobileShellComposite.emailFailure(
            for: try ticket(macUserEmail: "mac@example.com"),
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: nil,
            actualEmail: "phone@example.com",
            isDevelopmentAuthEnvironment: true
        )

        #expect(category == .emailMismatch(expected: "mac@example.com", actual: "phone@example.com"))
    }
}
