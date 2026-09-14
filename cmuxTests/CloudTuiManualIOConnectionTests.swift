import Darwin
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
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

    @Test func keystrokeBurstSurvivesBriefPeerBackpressure() async throws {
        let writerQueue = DispatchQueue(label: "test.cloud-burst-writer")
        try await Self.withConnection(queue: writerQueue) { connection, peer in
            let inputQueue = DispatchQueue(label: "test.cloud-burst-input")
            let router = CloudTuiManualIOInputRouter(surfaceID: 7, queue: inputQueue)
            let expected = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
            // Hold both lanes until the burst is submitted. This reproduces a
            // brief scheduling/peer pause without relying on sleeps or rates.
            writerQueue.suspend()
            inputQueue.suspend()
            router.setConnection(connection)
            for byte in expected { router.send(.bytes(Data([byte]))) }
            router.setConnection(nil)
            inputQueue.resume()
            try await Self.blocking { inputQueue.sync {} }
            writerQueue.resume()
            try await Self.blocking { writerQueue.sync {} }

            let actual = try await Self.blocking {
                var bytes = Data()
                while bytes.count < expected.count {
                    let line = try Self.readLine(peer)
                    if line.isEmpty { break }
                    let command = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
                    #expect(command["surface"] as? Int == 7)
                    let encoded = try #require(command["bytes"] as? String)
                    bytes.append(try #require(Data(base64Encoded: encoded)))
                }
                return bytes
            }
            #expect(actual == expected)
            connection.send(line: Data("still-connected\n".utf8))
            #expect(try await Self.blocking { try Self.readLine(peer) } == Data("still-connected\n".utf8))
        }
    }

    @Test func inputWaitsForReceiptsBeforeExhaustingThePeerReplyQueue() async throws {
        try await Self.withConnection { connection, peer in
            let queue = DispatchQueue(label: "test.cloud-input-credit")
            let router = CloudTuiManualIOInputRouter(surfaceID: 7, queue: queue)
            let consumer = Task { for await _ in connection.events {} }
            defer { consumer.cancel() }
            queue.suspend()
            router.setConnection(connection)
            for _ in 0..<512 { router.send(.namedKey("Enter")) }
            router.setConnection(nil)
            queue.resume()
            try await Self.blocking { queue.sync {} }
            connection.send(line: Data("peer-barrier\n".utf8))
            let initialSubmitted = try await Self.blocking {
                var submitted = 0
                while true {
                    let line = try Self.readLine(peer)
                    if line == Data("peer-barrier\n".utf8) { break }
                    try #require(!line.isEmpty)
                    submitted += 1
                }
                // cmux-tui reserves 256 control replies. A paused reader must
                // leave room for control traffic instead of closing the peer.
                let initialSubmitted = submitted
                let receipt = Data("{\"id\":0,\"ok\":true,\"data\":{}}\n".utf8)
                for _ in 0..<submitted { try Self.write(peer, receipt) }
                while submitted < 512 {
                    let line = try Self.readLine(peer)
                    try #require(!line.isEmpty)
                    submitted += 1
                    try Self.write(peer, receipt)
                }
                return initialSubmitted
            }
            #expect(initialSubmitted > 0 && initialSubmitted < 256)
        }
    }

    @Test func rejectedInputClosesWithoutSpendingMoreCredits() async throws {
        try await Self.withConnection { connection, peer in
            let queue = DispatchQueue(label: "test.cloud-input-rejected")
            let router = CloudTuiManualIOInputRouter(surfaceID: 7, queue: queue)
            let consumer = Task { for await _ in connection.events {} }
            defer { consumer.cancel() }
            queue.suspend()
            router.setConnection(connection)
            for _ in 0..<100 { router.send(.namedKey("Enter")) }
            queue.resume()
            try await Self.blocking { queue.sync {} }
            connection.send(line: Data("peer-barrier\n".utf8))
            let counts = try await Self.blocking {
                var submitted = 0
                while try Self.readLine(peer) != Data("peer-barrier\n".utf8) { submitted += 1 }
                try Self.write(peer, Data("{\"id\":0,\"ok\":false,\"error\":\"rejected\"}\n".utf8))
                let afterRejection = try Self.readLine(peer)
                return (submitted, afterRejection.isEmpty)
            }
            #expect(counts.0 > 0 && counts.0 < 100)
            #expect(counts.1)
        }
    }

    @Test func byteBatchPreservesNamedKeyAndConnectionBoundaries() async throws {
        try await Self.withConnection { connection, peer in
            let consumer = Task { for await _ in connection.events {} }
            defer { consumer.cancel() }
            let queue = DispatchQueue(label: "test.cloud-input-order")
            let router = CloudTuiManualIOInputRouter(surfaceID: 7, queue: queue)
            queue.suspend()
            router.setConnection(connection)
            router.send(.bytes(Data("before".utf8)))
            router.send(.namedKey("Enter"))
            router.send(.bytes(Data("after".utf8)))
            router.setConnection(nil)
            router.send(.bytes(Data("rebound".utf8)))
            router.setConnection(connection)
            queue.resume()

            let commands = try await Self.blocking {
                try (0..<4).map { _ in
                    let command = try #require(JSONSerialization.jsonObject(with: Self.readLine(peer)) as? [String: Any])
                    try Self.write(peer, Data("{\"id\":0,\"ok\":true,\"data\":{}}\n".utf8))
                    return command
                }.map { command in
                    // Only immutable Sendable values cross out of peer I/O.
                    (command["cmd"] as? String, command["bytes"] as? String,
                     command["keys"] as? [String], command["id"] as? Int)
                }
            }
            #expect(commands.map { $0.0 } == ["send", "send-key", "send", "send"])
            #expect(commands[0].1 == Data("before".utf8).base64EncodedString())
            #expect(commands[1].2 == ["enter"])
            #expect(commands[2].1 == Data("after".utf8).base64EncodedString())
            #expect(commands[3].1 == Data("rebound".utf8).base64EncodedString())
            #expect(commands.allSatisfy { $0.3 == 0 })
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
        let clock = SidebarTestManualClock()
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
            var write = CloudTuiRequests.writeBytes(terminalID: "term_test", data: bytes)
            write.idempotencyKey = "same-logical-input"
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

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw socketError() }
        return object
    }

    private static func response(_ request: [String: Any], result: [String: Any], raw: Bool = false) throws -> Data {
        var response: [String: Any] = ["id": request["id"]!, "ok": true, raw ? "data" : "result": result]
        if !raw { response["protocol"] = "cmux.protocol/2"; response["type"] = "response" }
        return try JSONSerialization.data(withJSONObject: response) + Data([10])
    }

    private static func withResourceConnection(
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
        queue: DispatchQueue = DispatchQueue(label: "test.cloud-io"),
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
        let connection = CloudTuiManualIOConnection(socketPath: path, queue: queue)
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

    private static func write(_ descriptor: Int32, _ data: Data) throws {
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

    private static func readLine(_ descriptor: Int32) throws -> Data {
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
    private static func blocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private static func socketError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
