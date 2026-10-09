import CNTransport
import Foundation
import Testing

@Suite struct LaneCodecTests {
    let codec = LaneCodec()

    func roundTrip(_ message: Data) throws -> (Data, [Data]) {
        let chunks = codec.fragment(message)
        var r = codec.makeReassembler()
        var out: Data?
        for (i, c) in chunks.enumerated() {
            #expect(c.count <= LaneCodec.defaultMaxPayload + 1)
            let result = try r.push(c)
            if i < chunks.count - 1 { #expect(result == nil) } else { out = result }
        }
        return (try #require(out), chunks)
    }

    @Test func empty() throws {
        let (out, chunks) = try roundTrip(Data())
        #expect(out.isEmpty && chunks == [Data([0x01])])
    }

    @Test func exactBoundaries() throws {
        for size in [1, 16_383, 16_384, 16_385, 32_768, 32_769] {
            let msg = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            let (out, chunks) = try roundTrip(msg)
            #expect(out == msg)
            #expect(chunks.count == max(1, (size + 16_383) / 16_384))
            #expect(chunks.last?.first == 0x01)
            #expect(chunks.dropLast().allSatisfy { $0.first == 0x00 })
        }
    }

    @Test func oneMegabyte() throws {
        var g = SystemRandomNumberGenerator()
        let msg = Data((0..<(1024 * 1024)).map { _ in UInt8.random(in: 0...255, using: &g) })
        let (out, chunks) = try roundTrip(msg)
        #expect(out == msg)
        #expect(chunks.count == 64)
    }

    @Test func slicedInputAndBackToBackMessages() throws {
        let big = Data(repeating: 7, count: 40_000)
        let sliced = Data([9, 9, 9]) + big
        let a = sliced.dropFirst(3)  // non-zero startIndex
        var r = codec.makeReassembler()
        var got: [Data] = []
        for c in codec.fragment(Data(a)) + codec.fragment(Data("hi".utf8)) + codec.fragment(a) {
            if let m = try r.push(c) { got.append(m) }
        }
        #expect(got == [big, Data("hi".utf8), big])
    }

    @Test func rejectsEmptyChunkAndOversize() {
        var r = LaneReassembler(maxMessageSize: 10)
        #expect(throws: LaneCodecError.emptyChunk) { try r.push(Data()) }
        #expect(throws: LaneCodecError.self) { try r.push(Data([0]) + Data(repeating: 1, count: 11)) }
    }

    @Test func streamFrameAndBrowserFrameRoundTrip() throws {
        let bf = BrowserFrame(seq: 42, cssWidth: 390, cssHeight: 760, pixelWidth: 1170, pixelHeight: 2280, format: .jpeg, image: Data([0xFF, 0xD8, 1, 2]))
        let frame = StreamFrame(kind: .browserFrame, streamId: 0xDEADBEEF, payload: bf.encodedPayload())
        let decoded = try StreamFrame(decoding: frame.encoded())
        #expect(decoded == frame)
        #expect(try BrowserFrame(payload: decoded.payload) == bf)
        #expect(StreamFrameKind.termInput.lane == .interactive && StreamFrameKind.browserFrame.lane == .bulk)
    }
}
