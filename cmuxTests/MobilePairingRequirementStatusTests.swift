import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Mobile pairing requirement status")
struct MobilePairingRequirementStatusTests {
    private func ready(tailscale: Bool) -> MobilePairingModel.Ready {
        MobilePairingModel.Ready(
            attachURL: "cmux-ios://attach?ticket=abc",
            macName: "Test Mac",
            tailscaleLines: tailscale ? ["100.64.0.1:7777"] : []
        )
    }

    // MARK: Sign-in requirement

    @Test("Signed out flags the sign-in step as needs-action")
    func signedOutNeedsAction() {
        let status = MobilePairingModel.signInRequirementStatus(for: .signedOut, signedIn: false)
        #expect(status == .needsAction)
    }

    @Test("A confirmed account completes the sign-in step in every state")
    func signedInIsCompleteEverywhere() {
        let states: [MobilePairingModel.State] = [
            .loading, .preparing, .needsTailscale, .failed("x"),
            .ready(ready(tailscale: true)), .connected(ready(tailscale: true)),
        ]
        for state in states {
            #expect(MobilePairingModel.signInRequirementStatus(for: state, signedIn: true) == .complete)
        }
    }

    @Test("Resolving auth keeps the sign-in step neutral, not red")
    func loadingIsPending() {
        let status = MobilePairingModel.signInRequirementStatus(for: .loading, signedIn: false)
        #expect(status == .pending)
    }

    @Test("A failure before auth ever resolved keeps the sign-in step neutral")
    func failedWithoutAuthIsPending() {
        let status = MobilePairingModel.signInRequirementStatus(for: .failed("x"), signedIn: false)
        #expect(status == .pending)
    }

    // MARK: Tailscale requirement

    @Test("No reachable route flags the Tailscale step as needs-action")
    func needsTailscaleIsNeedsAction() {
        #expect(MobilePairingModel.tailscaleRequirementStatus(for: .needsTailscale) == .needsAction)
    }

    @Test("A ticket with a Tailscale route completes the Tailscale step")
    func readyWithRouteIsComplete() {
        #expect(MobilePairingModel.tailscaleRequirementStatus(for: .ready(ready(tailscale: true))) == .complete)
        #expect(MobilePairingModel.tailscaleRequirementStatus(for: .connected(ready(tailscale: true))) == .complete)
    }

    @Test("A ticket without a Tailscale route still flags the step")
    func readyWithoutRouteIsNeedsAction() {
        #expect(MobilePairingModel.tailscaleRequirementStatus(for: .ready(ready(tailscale: false))) == .needsAction)
        #expect(MobilePairingModel.tailscaleRequirementStatus(for: .connected(ready(tailscale: false))) == .needsAction)
    }

    @Test("Tailscale stays neutral while gated behind sign-in or still resolving")
    func gatedStatesArePending() {
        let states: [MobilePairingModel.State] = [.loading, .signedOut, .preparing, .failed("x")]
        for state in states {
            #expect(MobilePairingModel.tailscaleRequirementStatus(for: state) == .pending)
        }
    }
}
