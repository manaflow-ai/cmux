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
