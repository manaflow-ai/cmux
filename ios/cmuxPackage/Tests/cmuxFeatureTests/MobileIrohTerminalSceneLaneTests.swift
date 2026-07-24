import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing
@testable import cmuxFeature

@Suite
struct MobileIrohTerminalSceneLaneTests {
    @Test
    func splitFullFirstStreamMapsEveryEnvelopeAndFramesExactInputBytes() async throws {
        let codec = CmxIrohTerminalSceneEnvelopeCodec()
        let encoded = [
            codec.encode(.configuration(try Self.configuration())),
            codec.encode(.scene(try Self.scene(kind: .full, sequence: 1))),
            codec.encode(.accessibility(try Self.accessibility(sequence: 1))),
            codec.encode(.scene(try Self.scene(kind: .delta, sequence: 2))),
            codec.encode(.accessibility(try Self.accessibility(sequence: 2))),
        ].reduce(into: Data(), +=)
        let receive = TerminalSceneLaneReceiveStream(chunks: Self.split(encoded))
        let send = TerminalSceneLaneSendStream()
        let lane = MobileIrohTerminalSceneLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: receive,
                sendStream: send
            ),
            presentationID: Self.presentationID,
            presentationGeneration: 3
        )

        #expect(try await lane.receiveEnvelope() == .configuration(
            MobileTerminalSceneConfiguration(
                terminalID: Self.terminalID,
                terminalEpoch: 7,
                presentationID: Self.presentationID,
                presentationGeneration: 3,
                rendererConfigRevision: 9,
                width: 1_170,
                height: 2_532,
                contentScale: 3,
                rendererConfig: Data("font-size = 13\n".utf8)
            )
        ))
        #expect(try await lane.receiveEnvelope() == .scene(Self.mobileScene(
            kind: .full,
            sequence: 1
        )))
        #expect(try await lane.receiveEnvelope() == .accessibility(
            Self.mobileAccessibility(sequence: 1)
        ))
        #expect(try await lane.receiveEnvelope() == .scene(Self.mobileScene(
            kind: .delta,
            sequence: 2
        )))
        #expect(try await lane.receiveEnvelope() == .accessibility(
            Self.mobileAccessibility(sequence: 2)
        ))
        #expect(try await lane.receiveEnvelope() == nil)

        try await lane.sendInput(Data([0xc3, 0xa9, 0x0d, 0xff]))
        #expect(await send.frames() == [Data([0, 0, 0, 4, 0xc3, 0xa9, 0x0d, 0xff])])

        await lane.close()
        #expect(await send.resetCodes() == [0])
        #expect(await receive.stopCodes() == [0])
        await #expect(throws: MobileIrohTerminalSceneLaneError.closed) {
            try await lane.sendInput(Data("x".utf8))
        }
    }

    @Test
    func missingBytesAtEOFRejectTheLaneInsteadOfPresentingAPartialScene() async throws {
        let bytes = CmxIrohTerminalSceneEnvelopeCodec()
            .encode(.configuration(try Self.configuration()))
            .dropLast()
        let lane = MobileIrohTerminalSceneLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: TerminalSceneLaneReceiveStream(chunks: [Data(bytes)]),
                sendStream: TerminalSceneLaneSendStream()
            ),
            presentationID: Self.presentationID,
            presentationGeneration: 3
        )

        await #expect(throws: MobileIrohTerminalSceneLaneError.truncatedEnvelope) {
            try await lane.receiveEnvelope()
        }
    }

    @Test
    func contentSequenceRegressionIsRejectedBeforeMobileEnvelopeMapping() async throws {
        let codec = CmxIrohTerminalSceneEnvelopeCodec()
        let encoded = [
            codec.encode(.configuration(try Self.configuration())),
            codec.encode(.scene(try Self.scene(
                kind: .full,
                sequence: 1,
                contentSequence: 30
            ))),
            codec.encode(.accessibility(try Self.accessibility(
                sequence: 1,
                contentSequence: 30
            ))),
            codec.encode(.scene(try Self.scene(
                kind: .delta,
                sequence: 2,
                contentSequence: 31
            ))),
            codec.encode(.accessibility(try Self.accessibility(
                sequence: 2,
                contentSequence: 31
            ))),
            codec.encode(.scene(try Self.scene(
                kind: .delta,
                sequence: 3,
                contentSequence: 30
            ))),
        ].reduce(into: Data(), +=)
        let lane = MobileIrohTerminalSceneLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: TerminalSceneLaneReceiveStream(chunks: Self.split(encoded)),
                sendStream: TerminalSceneLaneSendStream()
            ),
            presentationID: Self.presentationID,
            presentationGeneration: 3
        )

        #expect(try await lane.receiveEnvelope() == .configuration(Self.mobileConfiguration()))
        #expect(try await lane.receiveEnvelope() == .scene(Self.mobileScene(
            kind: .full,
            sequence: 1,
            contentSequence: 30
        )))
        #expect(try await lane.receiveEnvelope() == .accessibility(
            Self.mobileAccessibility(sequence: 1, contentSequence: 30)
        ))
        #expect(try await lane.receiveEnvelope() == .scene(Self.mobileScene(
            kind: .delta,
            sequence: 2,
            contentSequence: 31
        )))
        #expect(try await lane.receiveEnvelope() == .accessibility(
            Self.mobileAccessibility(sequence: 2, contentSequence: 31)
        ))
        await #expect(
            throws: CmxIrohTerminalSceneStreamValidator.ValidationError
                .contentSequenceRegression(previous: 31, actual: 30)
        ) {
            try await lane.receiveEnvelope()
        }
    }

    @Test
    func largeInputIsSplitIntoBoundedExactByteFrames() async throws {
        let send = TerminalSceneLaneSendStream()
        let lane = MobileIrohTerminalSceneLane(
            stream: CmxIrohBidirectionalStream(
                receiveStream: TerminalSceneLaneReceiveStream(chunks: []),
                sendStream: send
            ),
            presentationID: Self.presentationID,
            presentationGeneration: 3
        )

        let input = Data(
            (0 ..< MobileIrohTerminalSceneLane.maximumInputByteCount + 3)
                .map { UInt8(truncatingIfNeeded: $0) }
        )
        try await lane.sendInput(input)

        let frames = await send.frames()
        try #require(frames.count == 2)
        #expect(frames[0].prefix(4) == Data([0, 0, 0x40, 0]))
        #expect(frames[0].dropFirst(4) == input.prefix(
            MobileIrohTerminalSceneLane.maximumInputByteCount
        ))
        #expect(frames[1].prefix(4) == Data([0, 0, 0, 3]))
        #expect(frames[1].dropFirst(4) == input.suffix(3))
    }

    private static let terminalID =
        UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private static let presentationID =
        UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    private static func configuration() throws -> CmxIrohTerminalSceneConfiguration {
        try CmxIrohTerminalSceneConfiguration(
            terminalID: terminalID,
            terminalEpoch: 7,
            presentationID: presentationID,
            presentationGeneration: 3,
            rendererConfigRevision: 9,
            width: 1_170,
            height: 2_532,
            contentScale: 3,
            rendererConfig: Data("font-size = 13\n".utf8)
        )
    }

    private static func mobileConfiguration() -> MobileTerminalSceneConfiguration {
        MobileTerminalSceneConfiguration(
            terminalID: terminalID,
            terminalEpoch: 7,
            presentationID: presentationID,
            presentationGeneration: 3,
            rendererConfigRevision: 9,
            width: 1_170,
            height: 2_532,
            contentScale: 3,
            rendererConfig: Data("font-size = 13\n".utf8)
        )
    }

    private static func scene(
        kind: CmxIrohTerminalSceneFrame.Kind,
        sequence: UInt64,
        contentSequence: UInt64? = nil
    ) throws -> CmxIrohTerminalSceneFrame {
        try CmxIrohTerminalSceneFrame(
            terminalID: terminalID,
            terminalEpoch: 7,
            contentSequence: contentSequence ?? 10 + sequence,
            presentationID: presentationID,
            presentationGeneration: 3,
            presentationSequence: sequence,
            kind: kind,
            payload: Data([0xca, 0xfe, UInt8(sequence)])
        )
    }

    private static func mobileScene(
        kind: MobileTerminalSceneFrame.Kind,
        sequence: UInt64,
        contentSequence: UInt64? = nil
    ) -> MobileTerminalSceneFrame {
        MobileTerminalSceneFrame(
            terminalID: terminalID,
            terminalEpoch: 7,
            contentSequence: contentSequence ?? 10 + sequence,
            presentationID: presentationID,
            presentationGeneration: 3,
            presentationSequence: sequence,
            kind: kind,
            payload: Data([0xca, 0xfe, UInt8(sequence)])
        )
    }

    private static func accessibility(
        sequence: UInt64,
        contentSequence: UInt64? = nil
    ) throws -> CmxIrohTerminalSceneAccessibility {
        try CmxIrohTerminalSceneAccessibility(
            terminalID: terminalID,
            terminalEpoch: 7,
            contentSequence: contentSequence ?? 10 + sequence,
            presentationID: presentationID,
            presentationGeneration: 3,
            presentationSequence: sequence,
            columns: 100,
            rows: 32,
            text: "scene \(sequence)"
        )
    }

    private static func mobileAccessibility(
        sequence: UInt64,
        contentSequence: UInt64? = nil
    ) -> MobileTerminalSceneAccessibility {
        MobileTerminalSceneAccessibility(
            terminalID: terminalID,
            terminalEpoch: 7,
            contentSequence: contentSequence ?? 10 + sequence,
            presentationID: presentationID,
            presentationGeneration: 3,
            presentationSequence: sequence,
            columns: 100,
            rows: 32,
            text: "scene \(sequence)"
        )
    }

    private static func split(_ bytes: Data) -> [Data] {
        let boundaries = [1, 7, 19, 67, 131, bytes.count]
        var chunks: [Data] = []
        var start = 0
        for end in boundaries {
            let end = min(end, bytes.count)
            guard end > start else { continue }
            chunks.append(Data(bytes[start ..< end]))
            start = end
        }
        return chunks
    }
}

private actor TerminalSceneLaneSendStream: CmxIrohSendStream {
    private var sentFrames: [Data] = []
    private var resets: [UInt64] = []

    func send(_ data: Data) {
        sentFrames.append(data)
    }

    func finish() {}

    func reset(errorCode: UInt64) {
        resets.append(errorCode)
    }

    func setPriority(_: Int32) {}

    func frames() -> [Data] { sentFrames }
    func resetCodes() -> [UInt64] { resets }
}

private actor TerminalSceneLaneReceiveStream: CmxIrohReceiveStream {
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
