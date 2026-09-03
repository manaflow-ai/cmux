internal import Foundation
import Testing
import CmuxLiteProtocol

@Suite("Frame codec")
struct FrameCodecTests {
    @Test("encoding uses the approved big-endian JSON wire shape")
    func deterministicWireShape() throws {
        let codec = try FrameCodec()
        let message = WireMessage(
            messageID: 1,
            body: .hello(
                .init(clientName: "cmux-lite-ios", nonce: "client-nonce")
            )
        )

        let frame = try codec.encode(message)
        #expect(frame.prefix(4) == Data([0, 0, 0, 108]))

        let json = try #require(
            String(data: Data(frame.dropFirst(4)), encoding: .utf8)
        )
        #expect(
            json == #"{"message_id":1,"payload":{"client_name":"cmux-lite-ios","nonce":"client-nonce"},"type":"hello","version":1}"#
        )
    }

    @Test("a frame split at every byte boundary decodes exactly once")
    func byteByByteFragmentation() throws {
        let codec = try FrameCodec()
        let expected = WireMessage(messageID: 1, body: .ping)
        let frame = try codec.encode(expected)
        var decoder = codec.makeDecoder()
        var decoded: [WireMessage] = []

        for byte in frame {
            decoded.append(contentsOf: try decoder.ingest(Data([byte])))
        }
        try decoder.finish()

        #expect(decoded == [expected])
    }

    @Test("coalesced frames decode separately in wire order")
    func coalescedFrames() throws {
        let codec = try FrameCodec()
        let messages = [
            WireMessage(messageID: 1, body: .ping),
            WireMessage(messageID: 2, replyTo: 1, body: .pong),
            WireMessage(
                messageID: 3,
                body: .close(.init(reason: .normal))
            ),
        ]
        var bytes = Data()
        for message in messages {
            bytes.append(try codec.encode(message))
        }
        var decoder = codec.makeDecoder()

        let decoded = try decoder.ingest(bytes)
        try decoder.finish()

        #expect(decoded == messages)
    }

    @Test("a split header and split body remain buffered independently")
    func partialHeaderAndBody() throws {
        let codec = try FrameCodec()
        let expected = WireMessage(
            messageID: 7,
            replyTo: 3,
            body: .protocolError(.init(code: .invalidCorrelation))
        )
        let frame = try codec.encode(expected)
        var decoder = codec.makeDecoder()

        #expect(try decoder.ingest(frame.prefix(2)).isEmpty)
        #expect(try decoder.ingest(frame.dropFirst(2).prefix(5)).isEmpty)
        let decoded = try decoder.ingest(frame.dropFirst(7))
        try decoder.finish()

        #expect(decoded == [expected])
    }

    @Test("end-of-stream rejects a partial frame and poisons the decoder")
    func truncatedFrameFailsClosed() throws {
        let codec = try FrameCodec()
        let frame = try codec.encode(WireMessage(messageID: 1, body: .ping))
        var decoder = codec.makeDecoder()

        _ = try decoder.ingest(frame.dropLast())
        #expect(throws: FrameCodec.Failure.truncatedFrame) {
            try decoder.finish()
        }
        #expect(throws: FrameCodec.Failure.decoderFailed) {
            try decoder.ingest(Data())
        }
    }

    @Test("declared oversized payload fails before body buffering")
    func oversizedDeclaredPayloadFailsClosed() throws {
        let codec = try FrameCodec(maximumPayloadSize: 8)
        var decoder = codec.makeDecoder()

        #expect(throws: FrameCodec.Failure.frameTooLarge) {
            try decoder.ingest(Data([0, 0, 0, 9]))
        }
        #expect(throws: FrameCodec.Failure.decoderFailed) {
            try decoder.ingest(Data([0]))
        }
    }

    @Test("empty and malformed JSON payloads fail closed")
    func malformedPayloadsFailClosed() throws {
        let codec = try FrameCodec()
        var emptyDecoder = codec.makeDecoder()
        var malformedDecoder = codec.makeDecoder()

        #expect(throws: FrameCodec.Failure.emptyPayload) {
            try emptyDecoder.ingest(Data([0, 0, 0, 0]))
        }

        let malformed = Data([0, 0, 0, 1, UInt8(ascii: "{")])
        #expect(throws: FrameCodec.Failure.malformedPayload) {
            try malformedDecoder.ingest(malformed)
        }
    }

    @Test("configuration and encoded payload limits are enforced")
    func configuredLimits() throws {
        #expect(throws: FrameCodec.Failure.invalidMaximumPayloadSize) {
            try FrameCodec(maximumPayloadSize: 0)
        }
        #expect(throws: FrameCodec.Failure.invalidMaximumMessagesPerIngest) {
            try FrameCodec(maximumMessagesPerIngest: 0)
        }

        let codec = try FrameCodec(maximumPayloadSize: 32)
        let message = WireMessage(
            messageID: 1,
            body: .hello(.init(clientName: "cmux-lite-ios", nonce: "nonce"))
        )
        #expect(throws: FrameCodec.Failure.frameTooLarge) {
            try codec.encode(message)
        }
    }

    @Test("one transport chunk has a bounded decode-work budget")
    func messageFloodFailsClosed() throws {
        let codec = try FrameCodec(maximumMessagesPerIngest: 2)
        var bytes = Data()
        bytes.append(try codec.encode(WireMessage(messageID: 1, body: .ping)))
        bytes.append(try codec.encode(WireMessage(messageID: 2, body: .ping)))
        bytes.append(try codec.encode(WireMessage(messageID: 3, body: .ping)))
        var decoder = codec.makeDecoder()

        #expect(throws: FrameCodec.Failure.tooManyMessages) {
            try decoder.ingest(bytes)
        }
        #expect(throws: FrameCodec.Failure.decoderFailed) {
            try decoder.ingest(Data())
        }
    }
}
