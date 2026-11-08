import AuthenticationServices
import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileTransport
import CryptoKit
import Foundation
import Testing
@testable import cmuxFeature

@MainActor
struct MobileIrohStreamAndPathTests {
    @Test
    func terminalLaneFramesUTF8InputAndOwnsBothStreamHalves() async throws {
        let outputEnvelope = try CmxIrohTerminalOutputEnvelope(
            kind: .replay,
            retainedBaseSequence: 10,
            sequence: 10,
            currentSequence: 16,
            payload: Data("output".utf8)
        )
        let encodedOutput = CmxIrohTerminalOutputEnvelopeCodec().encode(outputEnvelope)
        let receive = MobileIrohTerminalLaneReceiveStream(chunks: [
            Data(encodedOutput.prefix(5)),
            Data(encodedOutput.dropFirst(5)),
        ])
        let send = MobileIrohTerminalLaneSendStream()
        let lane = MobileIrohTerminalLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            )
        )

        try await lane.sendInput("é")
        try await lane.finishInput()
        #expect(try await lane.receiveOutput() == MobileTerminalLaneOutputFrame(
            kind: .replay,
            retainedBaseSequence: 10,
            sequence: 10,
            currentSequence: 16,
            bytes: Data("output".utf8)
        ))

        let frames = await send.frames()
        #expect(frames == [Data([0, 0, 0, 2, 0xc3, 0xa9])])
        #expect(await send.finishCount() == 1)

        await lane.close()
        #expect(await send.resetCodes() == [0])
        #expect(await receive.stopCodes() == [0])
        await #expect(throws: MobileIrohTerminalLaneError.closed) {
            try await lane.sendInput("x")
        }
    }
    @Test
    func terminalLaneRejectsUnboundedInputBeforeWriting() async throws {
        let receive = MobileIrohTerminalLaneReceiveStream(chunks: [])
        let send = MobileIrohTerminalLaneSendStream()
        let lane = MobileIrohTerminalLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            )
        )

        await #expect(throws: MobileIrohTerminalLaneError.inputTooLarge) {
            try await lane.sendInput(
                String(repeating: "x", count: MobileIrohTerminalLane.maximumInputByteCount + 1)
            )
        }
        #expect(await send.frames().isEmpty)
    }
    @Test
    func pathStateAdvancesGenerationWhileProfilesRemainFailClosed() async {
        let state = MobileIrohNetworkPathState(
            networkInterfaces: MobileIrohInterfaceProvider([])
        )
        let initial = await state.snapshot()

        await state.pathDidChange()
        let changed = await state.snapshot()

        #expect(initial.generation == 1)
        #expect(changed.generation == 2)
        #expect(changed.activeNetworkProfiles.isEmpty)
    }
    @Test
    func lanProfileAuthorizationIsBoundToPathGenerationAndRevocation() async throws {
        let state = MobileIrohNetworkPathState(
            networkInterfaces: MobileIrohInterfaceProvider([])
        )
        let profile = try CmxIrohNetworkProfileKey(
            source: .lan,
            profileID: String(repeating: "a", count: 64)
        )

        #expect(await state.authorizeLANProfile(
            profile,
            generation: 2,
            interfaceIndex: 4
        ) == false)
        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 0
        ) == false)
        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 4
        ))
        #expect(await state.snapshot().activeNetworkProfiles == [profile])

        await state.revokeLANProfile(profile, generation: 2)
        #expect(await state.snapshot().activeNetworkProfiles == [profile])

        await state.revokeLANProfile(profile, generation: 1)
        #expect(await state.snapshot().activeNetworkProfiles.isEmpty)

        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 4
        ))
        await state.pathDidChange()
        let changed = await state.snapshot()
        #expect(changed.generation == 2)
        #expect(changed.activeNetworkProfiles.isEmpty)
        #expect(await state.authorizeLANProfile(
            profile,
            generation: 1,
            interfaceIndex: 4
        ) == false)
    }
    @Test
    func pathStateAuthorizesTailscaleProfileOnlyWhileTailnetIsActive() async throws {
        let provider = MobileIrohInterfaceProvider([
            NetworkInterfaceAddress(
                interfaceName: "utun5",
                address: "100.99.1.2"
            ),
        ])
        let state = MobileIrohNetworkPathState(networkInterfaces: provider)
        let profile = CmxIrohNetworkProfileKey.activeTailscaleTunnel

        #expect(await state.snapshot().activeNetworkProfiles == [profile])

        provider.set([
            NetworkInterfaceAddress(
                interfaceName: "en0",
                address: "192.168.1.2"
            ),
        ])
        #expect(await state.snapshot().activeNetworkProfiles.isEmpty)
    }

}

private actor MobileIrohTerminalLaneSendStream: CmxIrohSendStream {
    private var sentFrames: [Data] = []
    private var finishes = 0
    private var resets: [UInt64] = []

    func send(_ data: Data) {
        sentFrames.append(data)
    }

    func finish() {
        finishes += 1
    }

    func reset(errorCode: UInt64) {
        resets.append(errorCode)
    }

    func setPriority(_: Int32) {}

    func frames() -> [Data] { sentFrames }
    func finishCount() -> Int { finishes }
    func resetCodes() -> [UInt64] { resets }
}

private actor MobileIrohTerminalLaneReceiveStream: CmxIrohReceiveStream {
    private var chunks: [Data]
    private var stops: [UInt64] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func receive(maximumByteCount: Int) -> Data? {
        guard !chunks.isEmpty else { return nil }
        let first = chunks.removeFirst()
        guard first.count > maximumByteCount else { return first }
        chunks.insert(Data(first.dropFirst(maximumByteCount)), at: 0)
        return Data(first.prefix(maximumByteCount))
    }

    func stop(errorCode: UInt64) {
        stops.append(errorCode)
    }

    func stopCodes() -> [UInt64] { stops }
}


private final class MobileIrohInterfaceProvider:
    NetworkInterfaceAddressProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var interfaces: [NetworkInterfaceAddress]?

    init(_ interfaces: [NetworkInterfaceAddress]?) {
        self.interfaces = interfaces
    }

    func set(_ interfaces: [NetworkInterfaceAddress]?) {
        lock.lock()
        self.interfaces = interfaces
        lock.unlock()
    }

    func currentInterfaceAddresses() -> [NetworkInterfaceAddress]? {
        lock.lock()
        defer { lock.unlock() }
        return interfaces
    }
}

