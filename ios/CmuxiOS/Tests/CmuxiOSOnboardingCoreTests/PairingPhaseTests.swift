import CmuxiOSFeatureKit
import CmuxiOSOnboardingCore
import Testing

@Suite("Pairing phase")
@MainActor
struct PairingPhaseTests {
    private let phone = DeviceRecord(id: "phone", name: "iPhone", platform: .iPhone, trust: .trusted, isThisDevice: true)
    private let laptop = DeviceRecord(id: "laptop", name: "MacBook Pro", platform: .mac, trust: .discovered)
    private let live = SourceConnection.live(path: "mock")

    @Test("Searching until a same-account Mac is discovered, then found")
    func discovery() {
        #expect(PairingPhase(devices: [phone], connection: live, intent: .idle) == .searching)
        #expect(PairingPhase(devices: [phone], connection: .connecting, intent: .idle) == .searching)
        #expect(PairingPhase(devices: [phone, laptop], connection: live, intent: .idle)
            == .found([PairingCandidate(id: "laptop", name: "MacBook Pro")]))
        #expect(PairingPhase(devices: [phone], connection: .offline(reason: nil), intent: .idle) == .offline)
    }

    @Test("Pairing settles when the registry reports the Mac trusted")
    func pairingSettles() {
        let candidate = PairingCandidate(id: "laptop", name: "MacBook Pro")
        #expect(PairingPhase(devices: [phone, laptop], connection: live, intent: .pairing(candidate)) == .pairing(candidate))
        var trusted = laptop
        trusted.trust = .trusted
        let phase = PairingPhase(devices: [phone, trusted], connection: live, intent: .pairing(candidate))
        #expect(phase == .paired(name: "MacBook Pro"))
        #expect(phase.isSettled)
        #expect(PairingPhase.hasTrustedMac(in: [phone, trusted]))
        #expect(!PairingPhase.hasTrustedMac(in: [phone, laptop]))
    }

    @Test("Failures and QR redemption come from the local intent")
    func intentWins() {
        #expect(PairingPhase(devices: [], connection: .offline(reason: nil), intent: .failed(message: "x")) == .failed(message: "x"))
        #expect(PairingPhase(devices: [], connection: live, intent: .paired(name: "Studio")) == .paired(name: "Studio"))
    }

    @Test("An in-flight pair exposes an offline owner instead of spinning")
    func pairingDropsToOffline() {
        let candidate = PairingCandidate(id: "laptop", name: "MacBook Pro")
        #expect(
            PairingPhase(
                devices: [phone, laptop],
                connection: .offline(reason: "Control plane unavailable"),
                intent: .pairing(candidate)
            ) == .offline
        )
        // A connecting owner still shows the in-flight state while the first
        // snapshot is being established.
        #expect(
            PairingPhase(devices: [phone, laptop], connection: .connecting, intent: .pairing(candidate))
                == .pairing(candidate)
        )
    }

    @Test("The help hint fires after the delay on the injected clock, and cancel stops it")
    func hintTimer() async {
        let clock = ImmediateClock()
        let timer = PairingHintTimer(clock: clock, delay: .seconds(8))
        var fired = 0
        timer.start { fired += 1 }
        await timer.pending?.value
        #expect(fired == 1)
        #expect(clock.sleeps == [.seconds(8)])

        let blocked = PairingHintTimer(clock: SuspendingClock(), delay: .seconds(3600))
        var never = false
        blocked.start { never = true }
        let pending = blocked.pending
        blocked.cancel()
        await pending?.value
        #expect(!never)
    }
}
