import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A transport that records whether admission closed it. The managed-policy
/// refusal must close the transport before any session or registry entry is
/// created.
private actor RecordingManagedPolicyTransport: CmxByteTransport {
    private(set) var closeCount = 0
    private(set) var sent: [Data] = []
    private var receiveWaiter: CheckedContinuation<Data?, Never>?

    func connect() async throws {}

    func receive() async throws -> Data? {
        await withCheckedContinuation { receiveWaiter = $0 }
    }

    func send(_ data: Data) async throws {
        sent.append(data)
    }

    func close() async {
        closeCount += 1
        receiveWaiter?.resume(returning: nil)
        receiveWaiter = nil
    }

    func observedCloseCount() -> Int { closeCount }
    func observedSentCount() -> Int { sent.count }
}

/// Behavior tests for the MDM `DisableRemoteControl` policy at the universal
/// transport-admission funnel: a policy-disabled host must close any
/// arriving IROH transport without admitting a session.
struct ManagedPolicyRemoteControlTests {
    @Test func admissionRefusesAndClosesTheTransportUnderThePolicy() async throws {
        let registry = MobileHostConnectionRegistry.shared
        let countBefore = registry.count
        let transport = RecordingManagedPolicyTransport()

        let exit = await MobileHostService.acceptTransport(
            transport,
            authorization: .irohAdmission(CmxIrohAdmittedPeer(peer: CmxIrohGrantPeer(
                bindingID: "policy-binding", deviceID: "policy-phone", tag: "policy-test", platform: .ios,
                endpointID: try CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)),
                identityGeneration: 1))),
            remoteControlDisabledByPolicy: { true },
            isCurrent: { true }
        )

        #expect(exit.lifecycle == .explicitlyInvalidated)
        #expect(await transport.observedCloseCount() == 1)
        #expect(await transport.observedSentCount() == 0)
        #expect(registry.count == countBefore)
    }
}
