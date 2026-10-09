import CmuxiOSFeatureKit
import CmuxiOSOnboardingCore
import Foundation
import Observation
import UIKit

/// The pair step's state: mirrors the `DeviceRegistry` while the step is on
/// screen and projects it with the local intent into a `PairingPhase`.
@MainActor
@Observable
final class PairingModel {
    private(set) var devices: [DeviceRecord] = []
    private(set) var connection: SourceConnection = .connecting
    private(set) var intent: PairingIntent = .idle
    private(set) var showsHelp = false

    @ObservationIgnored private let registry: any DeviceRegistry
    @ObservationIgnored private let hint: PairingHintTimer
    @ObservationIgnored private let onPaired: @MainActor (String) -> Void
    @ObservationIgnored private let onFailure: @MainActor () -> Void
    @ObservationIgnored private var announcedPaired = false
    /// Trusted Macs before a QR redemption, to name the one it added.
    @ObservationIgnored private var qrBaseline: Set<DeviceRecord.ID>?

    var phase: PairingPhase { PairingPhase(devices: devices, connection: connection, intent: intent) }

    init(
        registry: any DeviceRegistry, clock: any Clock<Duration>,
        onPaired: @escaping @MainActor (String) -> Void, onFailure: @escaping @MainActor () -> Void
    ) {
        self.registry = registry
        hint = PairingHintTimer(clock: clock)
        self.onPaired = onPaired
        self.onFailure = onFailure
    }

    /// Mirrors the registry until the step leaves the screen.
    func run() async {
        hint.start { [weak self] in self?.raiseHelp() }
        defer { hint.cancel() }
        for await snapshot in await registry.updates() {
            devices = snapshot.value
            connection = snapshot.connection
            resolveQRRedemption()
            settle()
        }
    }

    func connect(_ candidate: PairingCandidate) async {
        intent = .pairing(candidate)
        await redeem(PairingTicket(payload: Data(candidate.id.utf8)))
        settle()
    }

    /// DEBUG sample QR code (the mock trusts the first discovered Mac).
    func redeemSampleCode() async {
        qrBaseline = trustedMacs()
        intent = .pairing(PairingCandidate(id: "qr", name: ""))
        await redeem(PairingTicket(payload: Data("cmux-sample-pairing-code".utf8)))
        resolveQRRedemption()
        settle()
    }

    /// A pairing link from the camera scanner (B6): the registry publishes this
    /// device's key and claims the offer; the new Mac resolves from the mirror.
    func redeemScanned(_ url: URL) async {
        qrBaseline = trustedMacs()
        intent = .pairing(PairingCandidate(id: "qr", name: ""))
        // The ticket payload is the link itself (B6's PairingTicketPayload.link).
        await redeem(PairingTicket(payload: Data(url.absoluteString.utf8)))
        resolveQRRedemption()
        settle()
    }

    func retry() {
        intent = .idle
        qrBaseline = nil
    }

    // MARK: - Private

    private func redeem(_ ticket: PairingTicket) async {
        do {
            if case .refused(_, let reason) = try await registry.pair(ticket, key: IntentKey()) {
                fail(reason)
            }
        } catch FeatureSourceError.offline {
            fail(OnboardingText.offlineError)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        intent = .failed(message: message)
        qrBaseline = nil
        onFailure()
        UIAccessibility.post(notification: .announcement, argument: OnboardingText.failed(message))
    }

    private func resolveQRRedemption() {
        guard let baseline = qrBaseline else { return }
        guard let added = devices.first(where: {
            $0.platform == .mac && $0.trust == .trusted && !$0.isThisDevice && !baseline.contains($0.id)
        }) else { return }
        qrBaseline = nil
        intent = .paired(name: added.name)
    }

    private func settle() {
        switch phase {
        case .paired(let name):
            hint.cancel()
            guard !announcedPaired else { return }
            announcedPaired = true
            onPaired(name)
            UIAccessibility.post(notification: .announcement, argument: OnboardingText.paired(name))
        case .found:
            hint.cancel()
        default:
            break
        }
    }

    private func raiseHelp() {
        guard case .searching = phase else { return }
        showsHelp = true
    }

    private func trustedMacs() -> Set<DeviceRecord.ID> {
        Set(devices.filter { $0.platform == .mac && $0.trust == .trusted && !$0.isThisDevice }.map(\.id))
    }
}
