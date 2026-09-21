import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation
import Testing
@testable import cmuxFeature

struct MobileV3LaneTests {
    @Test func outputUsesHostByteSequencesAcrossSplitAndCoalescedReads() async throws {
        let replay = try CmxIrohTerminalOutputEnvelope(kind: .replay, retainedBaseSequence: 50, sequence: 52, currentSequence: 54, payload: Data("é".utf8))
        let chunk = try CmxIrohTerminalOutputEnvelope(kind: .chunk, retainedBaseSequence: 54, sequence: 54, currentSequence: 57, payload: Data("abc".utf8))
        let bytes = CmxIrohTerminalOutputEnvelopeCodec().encode(replay) + CmxIrohTerminalOutputEnvelopeCodec().encode(chunk)
        let transport = V3LaneTestTransport(chunks: [Data(bytes.prefix(7)), Data(bytes.dropFirst(7))])
        let lane = MobileV3TerminalLane(transport: transport, cursor: 52)
        #expect(try await lane.receiveOutput() == MobileTerminalLaneOutputFrame(kind: .replay, retainedBaseSequence: 50, sequence: 52, currentSequence: 54, bytes: Data("é".utf8)))
        #expect(try await lane.receiveOutput() == MobileTerminalLaneOutputFrame(kind: .chunk, retainedBaseSequence: 54, sequence: 54, currentSequence: 57, bytes: Data("abc".utf8)))
        #expect(try await lane.receiveOutput() == nil)
    }

    @Test func truncatedOutputIsNotCleanEOF() async throws {
        let frame = try CmxIrohTerminalOutputEnvelope(kind: .replay, retainedBaseSequence: 0, sequence: 0, currentSequence: 3, payload: Data("abc".utf8))
        let bytes = CmxIrohTerminalOutputEnvelopeCodec().encode(frame)
        let transport = V3LaneTestTransport(chunks: [Data(bytes.dropLast())])
        let lane = MobileV3TerminalLane(transport: transport, cursor: nil)
        await #expect(throws: MobileV3LaneError.truncatedOutputFrame) { try await lane.receiveOutput() }
    }

    @Test func inputRetainsUTF8AndLatencySequenceInOneFrame() async throws {
        let transport = V3LaneTestTransport(chunks: [])
        let lane = MobileV3TerminalLane(transport: transport, cursor: nil, permitsInput: true)
        try await lane.sendInput("é🙂", sequence: 91)
        var bytes = try #require(await transport.sent.first)
        #expect(try MobileTerminalInputFrame.decode(from: &bytes) == [MobileTerminalInputFrame(text: "é🙂", sequence: 91)])
        #expect(bytes.isEmpty)
    }

    @Test func outputOnlyLaneRejectsInputBeforeTransportWrite() async throws {
        let transport = V3LaneTestTransport(chunks: [])
        let lane = MobileV3TerminalLane(transport: transport, cursor: nil)
        await #expect(throws: MobileV3LaneError.inputNotPermitted) { try await lane.sendInput("x") }
        #expect(await transport.sent.isEmpty)
    }

    @Test func inputRejectsEmptyAndOversizedOperations() async throws {
        let transport = V3LaneTestTransport(chunks: [])
        let lane = MobileV3TerminalLane(transport: transport, cursor: nil, permitsInput: true)
        await #expect(throws: MobileV3LaneError.emptyInput) { try await lane.sendInput("") }
        await #expect(throws: MobileV3LaneError.inputTooLarge) { try await lane.sendInput(String(repeating: "x", count: MobileTerminalInputFrame.maximumInputBytes + 1)) }
        #expect(await transport.sent.isEmpty)
    }
}

private actor V3LaneTestTransport: CmxByteTransport {
    var chunks: [Data]
    private(set) var sent: [Data] = []
    init(chunks: [Data]) { self.chunks = chunks }
    func connect() {}
    func receive() -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
    func send(_ data: Data) { sent.append(data) }
    func close() {}
}
