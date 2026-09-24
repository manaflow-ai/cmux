import CmuxCloudTui
import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#elseif canImport(CloudCommandFixture)
@testable import CloudCommandFixture
#endif

@Suite struct CloudTuiManualIOConnectionTests {
    @Test func burstSurvivesAConsumerWaitingForAnInputRoundTrip() async throws {
        try await Self.withConnection { connection, peer in
            let chunks = (0..<100).map { Data("\u{1b}[?2026hchunk-\($0)\u{1b}[?2026l".utf8) }
            try Self.write(peer, chunks.reduce(into: Data()) { $0.append(Self.outputLine($1)) })
            var iterator = connection.events.makeAsyncIterator()
            var received: [Data] = []
            if case let .output(_, bytes, _) = await iterator.next() {
                received.append(bytes)
            }

            // Keep consumption stopped until the peer receives input. This is
            // a causal gate, not a timing delay: the reader must permit writes
            // while its consumer is busy, without dropping the queued burst.
            connection.send(line: Data("input-round-trip\n".utf8))
            let input = try await Self.blocking { try Self.readLine(peer) }
            #expect(input == Data("input-round-trip\n".utf8))
            shutdown(peer, SHUT_WR)
            while let frame = await iterator.next() {
                if case let .output(_, bytes, _) = frame { received.append(bytes) }
            }
            #expect(received == chunks)
        }
    }

    @Test func preservesLargeFramesAcrossSocketReads() async throws {
        try await Self.withConnection { connection, peer in
            let chunks = (0..<8).map { Data(repeating: UInt8($0), count: 64 * 1024) }
            async let writer: Void = Self.blocking {
                for chunk in chunks { try Self.write(peer, Self.outputLine(chunk)) }
                shutdown(peer, SHUT_WR)
            }
            var received: [Data] = []
            for await frame in connection.events {
                if case let .output(_, bytes, _) = frame { received.append(bytes) }
            }
            try await writer
            #expect(received == chunks)
        }
    }

    @Test func cancellingAnIdleConsumerClosesTheSocket() async throws {
        try await Self.withConnection { connection, peer in
            let consumer = Task {
                var iterator = connection.events.makeAsyncIterator()
                return await iterator.next()
            }
            consumer.cancel()
            #expect(await consumer.value == nil)
            let remaining = try await Self.blocking { try Self.readLine(peer) }
            #expect(remaining.isEmpty)
        }
    }

    @Test func cancellingWhileWaitingForTheRestOfALineFinishes() async throws {
        try await Self.withConnection { connection, peer in
            var sendBuffer: Int32 = 4096
            setsockopt(peer, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
            let consumer = Task {
                var iterator = connection.events.makeAsyncIterator()
                return await iterator.next()
            }
            // More than the peer can buffer: completion proves the consumer
            // has started reading and is waiting for an unfinished JSON line.
            try await Self.blocking { try Self.write(peer, Data(repeating: 0x20, count: 128 * 1024)) }
            consumer.cancel()
            #expect(await consumer.value == nil)
            let remaining = try await Self.blocking { try Self.readLine(peer) }
            #expect(remaining.isEmpty)
        }
    }

    @Test func oversizedLineClosesInsteadOfDeliveringLaterOutput() async throws {
        try await Self.withConnection { connection, peer in
            async let writer: Void = Self.blocking {
                do {
                    try Self.write(peer, Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1))
                    try Self.write(peer, Data("\n".utf8) + Self.outputLine(Data("after-limit".utf8)))
                    shutdown(peer, SHUT_WR)
                } catch let error as NSError where error.code == Int(EPIPE) || error.code == Int(ECONNRESET) {
                    // A protocol limit violation is supposed to close the peer.
                }
            }
            var iterator = connection.events.makeAsyncIterator()
            #expect(await iterator.next() == nil)
            try await writer
        }
    }

    @Test func closingWithBufferedOutputReleasesTheSocket() async throws {
        try await Self.withConnection { connection, peer in
            try Self.write(peer, Self.outputLine(Data("first".utf8)) + Self.outputLine(Data("second".utf8)))
            var iterator = connection.events.makeAsyncIterator()
            #expect(await iterator.next() != nil)
            connection.close()
            while await iterator.next() != nil {}
            let remaining = try await Self.blocking { try Self.readLine(peer) }
            #expect(remaining.isEmpty)
        }
    }

    @Test func ignoresMalformedLinesWithoutLosingTheNextFrame() async throws {
        try await Self.withConnection { connection, peer in
            try Self.write(peer, Data("\nnot-json\n{}\n".utf8) + Self.outputLine(Data("valid".utf8)))
            shutdown(peer, SHUT_WR)
            var iterator = connection.events.makeAsyncIterator()
            #expect(await iterator.next() == .output(surfaceID: 1, bytes: Data("valid".utf8)))
            #expect(await iterator.next() == nil)
        }
    }

    @Test func persistentRequestsShareOneSocketAndMatchOutOfOrderResponses() async throws {
        try await Self.withResourceConnection { channel, peer in
            async let one = channel.request(CloudTuiRequest("session.ping"))
            async let two = channel.request(CloudTuiRequest("machine-listening-tcp", raw: true))
            async let three = channel.request(CloudTuiRequest("session.snapshot"))
            let replies: [Data] = try await Self.blocking {
                var responses: [Data] = []
                for _ in 0..<3 {
                    let request = try Self.object(Self.readLine(peer))
                    let raw = request["cmd"] as? String
                    let label = raw ?? request["operation"] as? String ?? "missing"
                    responses.append(try Self.response(request, result: ["label": label], raw: raw != nil))
                }
                for response in responses.reversed() { try Self.write(peer, response) }
                return responses
            }
            #expect(replies.count == 3)
            let first = try await one, second = try await two, third = try await three
            #expect(try Self.object(first)["label"] as? String == "session.ping")
            #expect(try Self.object(second)["label"] as? String == "machine-listening-tcp")
            #expect(try Self.object(third)["label"] as? String == "session.snapshot")
        }
    }

    @Test func persistentCancellationRetiresOnlyOneRequestAndIgnoresItsLateReply() async throws {
        try await Self.withResourceConnection { channel, peer in
            let canceled = Task { try await channel.request(CloudTuiRequest("terminal.wait", ["terminal": "term_test", "pattern": "x"])) }
            let waiting = try await Self.blocking { try Self.readLine(peer) }
            canceled.cancel()
            await #expect(throws: CancellationError.self) { try await canceled.value }
            let cancellation = try await Self.blocking { try Self.readLine(peer) }
            #expect(try Self.object(cancellation)["operation"] as? String == "request.cancel")
            let original = try Self.object(waiting)
            let cancel = try Self.object(cancellation)
            #expect((cancel["params"] as? [String: Any])?["request_id"] as? String == original["id"] as? String)
            try Self.write(peer, Self.response(original, result: ["late": true]))
            try Self.write(peer, Self.response(cancel, result: ["canceled": true]))
            async let next = channel.request(CloudTuiRequest("session.ping"))
            try await Self.blocking {
                let request = try Self.object(Self.readLine(peer))
                try Self.write(peer, Self.response(request, result: ["alive": true]))
            }
            let nextResult = try await next
            #expect(try Self.object(nextResult)["alive"] as? Bool == true)
        }
    }

    @Test func persistentDeadlineCompletesWithoutAReplyOrClosingSiblings() async throws {
        let clock = CloudCommandDeadlineClock()
        try await Self.withResourceConnection(clock: clock) { channel, peer in
            let expired = Task { try await channel.request(CloudTuiRequest("session.ping"), timeout: .milliseconds(100)) }
            _ = try await Self.blocking { try Self.readLine(peer) }
            await clock.waitUntilSleeping()
            clock.advance(by: .milliseconds(100))
            await #expect(throws: CloudMachineLink.LinkError.self) { try await expired.value }
            let cancellationBytes = try await Self.blocking { try Self.readLine(peer) }
            let cancellation = try Self.object(cancellationBytes)
            #expect(cancellation["operation"] as? String == "request.cancel")
            #expect(!(await channel.isClosed))
        }
    }

    @Test func persistentEventsAndControlResponsesShareTheSameReader() async throws {
        try await Self.withResourceConnection { channel, peer in
            async let opening = channel.events(cursor: nil)
            let requestBytes = try await Self.blocking { try Self.readLine(peer) }
            let openingRequest = try Self.object(requestBytes)
            let fields = try #require(openingRequest["params"] as? [String: Any])
            let streamID = try #require(fields["stream_id"] as? String)
            try Self.write(peer, Self.response(openingRequest, result: ["stream_id": streamID]))
            let opened = try await opening
            var iterator = opened.stream.makeAsyncIterator()
            async let ping = channel.request(CloudTuiRequest("session.ping"))
            try await Self.blocking {
                let request = try Self.object(Self.readLine(peer))
                let event: [String: Any] = ["protocol": "cmux.protocol/2", "type": "stream_item", "stream_id": streamID, "sequence": "0", "item": ["kind": "fixture"]]
                try Self.write(peer, JSONSerialization.data(withJSONObject: event) + Data([10]))
                try Self.write(peer, Self.response(request, result: ["alive": true]))
            }
            let event = try #require(await iterator.next())
            #expect(try Self.object(event)["stream_id"] as? String == streamID)
            let pingResult = try await ping
            #expect(try Self.object(pingResult)["alive"] as? Bool == true)
            await channel.cancelStream(opened.id)
            #expect(await iterator.next() == nil)
            let cancellationBytes = try await Self.blocking { try Self.readLine(peer) }
            let cancellation = try Self.object(cancellationBytes)
            #expect(cancellation["operation"] as? String == "stream.cancel")
            #expect(!(await channel.isClosed))
        }
    }

    @Test func persistentEOFResolvesEveryPendingRequestAndRejectsFurtherWork() async throws {
        try await Self.withResourceConnection { channel, peer in
            let first = Task { try await channel.request(CloudTuiRequest("session.ping")) }
            let second = Task { try await channel.request(CloudTuiRequest("session.snapshot")) }
            try await Self.blocking { _ = try Self.readLine(peer); _ = try Self.readLine(peer) }
            shutdown(peer, SHUT_RDWR)
            await #expect(throws: CloudMachineLink.LinkError.self) { try await first.value }
            await #expect(throws: CloudMachineLink.LinkError.self) { try await second.value }
            await #expect(throws: CloudMachineLink.LinkError.self) { try await channel.request(CloudTuiRequest("session.ping")) }
        }
    }

    @Test func persistentWirePreservesPayloadAndMutationKey() async throws {
        try await Self.withResourceConnection { channel, peer in
            let bytes = Data("--name secret\n\0payload".utf8)
            // Immutable so the `async let` capture is Sendable-clean under Swift 6 diagnostics.
            let write: CloudTuiRequest = {
                var request = CloudTuiRequests.writeBytes(terminalID: "term_test", data: bytes)
                request.idempotencyKey = "same-logical-input"
                return request
            }()
            async let result = channel.request(write)
            let captured = try await Self.blocking { try Self.readLine(peer) }
            let request = try Self.object(captured)
            let fields = try #require(request["params"] as? [String: Any])
            #expect(fields["bytes_base64"] as? String == bytes.base64EncodedString())
            #expect(request["idempotency_key"] as? String == "same-logical-input")
            try Self.write(peer, Self.response(request, result: ["value": [:], "generation": "g", "revision": "1", "replayed": false]))
            _ = try await result
        }
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw socketError() }
        return object
    }

    static func response(_ request: [String: Any], result: [String: Any], raw: Bool = false) throws -> Data {
        var response: [String: Any] = ["id": request["id"]!, "ok": true, raw ? "data" : "result": result]
        if !raw { response["protocol"] = "cmux.protocol/2"; response["type"] = "response" }
        return try JSONSerialization.data(withJSONObject: response) + Data([10])
    }

    static func withResourceConnection(
        clock: any Clock<Duration> = ContinuousClock(),
        _ body: (CloudTuiPersistentResourceConnection, Int32) async throws -> Void
    ) async throws {
        // Reuse the socket fixture but create a single resource consumer on its
        // own accepted descriptor. No cmux-tui executable is involved.
        let path = "/tmp/cmux-rpc-\(UUID().uuidString.prefix(12)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw socketError() }
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listener, 2) == 0 else { throw socketError() }
        let channel = CloudTuiPersistentResourceConnection(socketPath: path, clock: clock)
        try await channel.start()
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { await channel.close(); throw socketError() }
        defer { Darwin.close(peer) }
        var noSignal: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        do { try await body(channel, peer); await channel.close() }
        catch { await channel.close(); throw error }
    }

    private static func outputLine(_ bytes: Data) -> Data {
        Data("{\"event\":\"output\",\"surface\":1,\"data\":\"\(bytes.base64EncodedString())\"}\n".utf8)
    }

    private static func withConnection(
        _ body: (CloudTuiManualIOConnection, Int32) async throws -> Void
    ) async throws {
        let path = "/tmp/cmux-io-\(UUID().uuidString.prefix(12)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw socketError() }
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            pathBytes.withUnsafeBytes { target.copyBytes(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw socketError() }
        let connection = CloudTuiManualIOConnection(socketPath: path)
        defer { connection.close() }
        try await connection.start()
        let peer = accept(listener, nil, nil)
        guard peer >= 0 else { throw socketError() }
        defer { Darwin.close(peer) }
        var noSignal: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Deadlines fail broken fixtures instead of leaving a CI worker hung.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try await body(connection, peer)
    }

    static func write(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw socketError() }
                offset += count
            }
        }
    }

    static func readLine(_ descriptor: Int32) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw socketError() }
            if count == 0 { return result }
            result.append(byte)
            if byte == 0x0A { return result }
        }
    }

    /// Blocking peer I/O stays off Swift's cooperative executor and the client's
    /// dispatch queue. Each test owns its descriptors until these jobs finish.
    static func blocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private static func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
