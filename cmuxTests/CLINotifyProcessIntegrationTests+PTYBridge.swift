import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - PTY bridge RPC mocks and bridge lifecycle tests
extension CLINotifyProcessIntegrationTests {
    private struct PTYAttachCall {
        let sessionID: String
        let attachmentID: String
        let command: String?
        let requireExisting: Bool
    }

    private final class ImmediateExitPTYBridgeRPC: WorkspaceRemotePTYBridgeRPCClient {
        private let lock = NSLock()
        private var recordedAttachCalls: [PTYAttachCall] = []

        var attachCalls: [PTYAttachCall] {
            lock.lock()
            defer { lock.unlock() }
            return recordedAttachCalls
        }

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
        ) throws -> WorkspaceRemotePTYBridgeAttachment {
            lock.lock()
            recordedAttachCalls.append(PTYAttachCall(
                sessionID: sessionID,
                attachmentID: attachmentID,
                command: command,
                requireExisting: requireExisting
            ))
            lock.unlock()
            queue.async {
                onEvent(.exit)
            }
            return WorkspaceRemotePTYBridgeAttachment(attachmentID: attachmentID, token: "immediate-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            completion(nil)
        }
        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
    }

    private final class ImmediateOutputThenExitPTYBridgeRPC: WorkspaceRemotePTYBridgeRPCClient {
        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
        ) throws -> WorkspaceRemotePTYBridgeAttachment {
            queue.async {
                onEvent(.data(Data("early-output".utf8)))
                onEvent(.exit)
            }
            return WorkspaceRemotePTYBridgeAttachment(attachmentID: attachmentID, token: "immediate-output-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            completion(nil)
        }
        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}
    }

    private final class FloodPTYBridgeRPC: WorkspaceRemotePTYBridgeRPCClient {
        let detachSemaphore = DispatchSemaphore(value: 0)

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
        ) throws -> WorkspaceRemotePTYBridgeAttachment {
            queue.async {
                let chunk = Data(repeating: 0x78, count: 64 * 1024)
                for _ in 0..<512 {
                    onEvent(.data(chunk))
                }
            }
            return WorkspaceRemotePTYBridgeAttachment(attachmentID: attachmentID, token: "flood-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            completion(nil)
        }

        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {
            detachSemaphore.signal()
        }
    }

    private final class DelayedOutputPTYBridgeRPC: WorkspaceRemotePTYBridgeRPCClient {
        let detachSemaphore = DispatchSemaphore(value: 0)

        private let attachStarted: DispatchSemaphore?
        private let attachGate: DispatchSemaphore?
        private let lock = NSLock()
        private var queue: DispatchQueue?
        private var onEvent: ((WorkspaceRemotePTYBridgeEvent) -> Void)?
        private var didEmit = false

        init(attachStarted: DispatchSemaphore? = nil, attachGate: DispatchSemaphore? = nil) {
            self.attachStarted = attachStarted
            self.attachGate = attachGate
        }

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
        ) throws -> WorkspaceRemotePTYBridgeAttachment {
            attachStarted?.signal()
            if let attachGate {
                _ = attachGate.wait(timeout: .now() + 2)
            }
            lock.lock()
            self.queue = queue
            self.onEvent = onEvent
            lock.unlock()
            return WorkspaceRemotePTYBridgeAttachment(attachmentID: attachmentID, token: "delayed-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            guard String(data: data, encoding: .utf8)?.contains("after-half-close-input") == true else {
                completion(nil)
                return
            }

            let emitQueue: DispatchQueue?
            let emitEvent: ((WorkspaceRemotePTYBridgeEvent) -> Void)?
            lock.lock()
            if didEmit {
                emitQueue = nil
                emitEvent = nil
            } else {
                didEmit = true
                emitQueue = queue
                emitEvent = onEvent
            }
            lock.unlock()

            emitQueue?.async {
                emitEvent?(.data(Data("after-half-close-output\n".utf8)))
                emitEvent?(.exit)
            }
            completion(nil)
        }

        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {
            detachSemaphore.signal()
        }
    }

    private final class DeferredWriteCompletionPTYBridgeRPC: WorkspaceRemotePTYBridgeRPCClient {
        private let lock = NSLock()
        private var completions: [(Error?) -> Void] = []

        let firstWrite = DispatchSemaphore(value: 0)
        let secondWrite = DispatchSemaphore(value: 0)

        func attachBridgePTY(
            sessionID: String,
            attachmentID: String,
            cols: Int,
            rows: Int,
            command: String?,
            requireExisting: Bool,
            queue: DispatchQueue,
            onEvent: @escaping (WorkspaceRemotePTYBridgeEvent) -> Void
        ) throws -> WorkspaceRemotePTYBridgeAttachment {
            return WorkspaceRemotePTYBridgeAttachment(attachmentID: attachmentID, token: "deferred-token")
        }

        func writePTY(
            sessionID: String,
            attachmentID: String,
            attachmentToken: String,
            data: Data,
            completion: @escaping (Error?) -> Void
        ) {
            let writeCount: Int
            lock.lock()
            completions.append(completion)
            writeCount = completions.count
            lock.unlock()

            if writeCount == 1 {
                firstWrite.signal()
            } else if writeCount == 2 {
                secondWrite.signal()
            }
        }

        func detachPTY(sessionID: String, attachmentID: String, attachmentToken: String) {}

        func completeWrites() {
            let pending: [(Error?) -> Void]
            lock.lock()
            pending = completions
            completions.removeAll()
            lock.unlock()

            for completion in pending {
                completion(nil)
            }
        }
    }

    func testPTYBridgeFlushesReadyBeforeImmediateExit() throws {
        let rpcClient = ImmediateExitPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-short-lived",
            attachmentID: "attachment-short-lived",
            command: "printf done",
            requireExisting: true
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
            "client_pid": Int(getpid()),
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        let responseLines = responseText.split(separator: "\n").map(String.init)
        let firstPayload = try XCTUnwrap(responseLines.first?.data(using: .utf8))
        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstPayload, options: []) as? [String: Any]
        )
        XCTAssertEqual(firstJSON["type"] as? String, "ready", "Expected ready frame first, saw \(responseText)")
        XCTAssertEqual(rpcClient.attachCalls.count, 1)
        XCTAssertEqual(rpcClient.attachCalls.first?.sessionID, "session-short-lived")
        XCTAssertEqual(rpcClient.attachCalls.first?.attachmentID, "attachment-short-lived")
        XCTAssertEqual(rpcClient.attachCalls.first?.command, "printf done")
        XCTAssertEqual(rpcClient.attachCalls.first?.requireExisting, true)
    }

    func testPTYBridgeBuffersOutputUntilReadyFrame() throws {
        let rpcClient = ImmediateOutputThenExitPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-early-output",
            attachmentID: "attachment-early-output",
            command: nil,
            requireExisting: true
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        let responseLines = responseText.split(separator: "\n", maxSplits: 1).map(String.init)
        let firstPayload = try XCTUnwrap(responseLines.first?.data(using: .utf8))
        let firstJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: firstPayload, options: []) as? [String: Any]
        )
        XCTAssertEqual(firstJSON["type"] as? String, "ready", responseText)
        XCTAssertTrue(responseText.contains("early-output"), responseText)
    }

    func testPTYBridgeForwardsInputWithoutWaitingForWriteCompletion() throws {
        let rpcClient = DeferredWriteCompletionPTYBridgeRPC()
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-input-completion",
            attachmentID: "attachment-input-completion",
            command: nil,
            requireExisting: false
        ) {}
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            rpcClient.completeWrites()
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        let readyLine = try readLine(from: fd, timeout: 2)
        XCTAssertTrue(readyLine.contains("\"ready\""), readyLine)

        XCTAssertTrue(writeAll("a", to: fd))
        XCTAssertEqual(rpcClient.firstWrite.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(writeAll("b", to: fd))
        XCTAssertEqual(
            rpcClient.secondWrite.wait(timeout: .now() + 1.0),
            .success,
            "Bridge input forwarding should not wait for the prior pty.write response"
        )
        rpcClient.completeWrites()
    }

    func testPTYBridgeStopRetainsServerUntilCleanupRuns() throws {
        let rpcClient = ImmediateExitPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        var server: WorkspaceRemotePTYBridgeServer? = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-stop-retain",
            attachmentID: "attachment-stop-retain",
            command: nil,
            requireExisting: false
        ) {
            stopped.signal()
        }
        guard let endpoint = try server?.start() else {
            return XCTFail("Failed to start PTY bridge server")
        }
        XCTAssertGreaterThan(endpoint.port, 0)

        server?.stop()
        server = nil

        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    }

    func testPTYBridgeKeepsOutputOpenAfterClientHalfClose() throws {
        let rpcClient = DelayedOutputPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-half-close",
            attachmentID: "attachment-half-close",
            command: nil,
            requireExisting: false
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\nafter-half-close-input", to: fd))
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("\"ready\""), responseText)
        XCTAssertTrue(responseText.contains("after-half-close-output"), responseText)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPTYBridgeKeepsOutputOpenAfterClientHalfCloseWithoutPID() throws {
        let rpcClient = DelayedOutputPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-half-close-no-pid",
            attachmentID: "attachment-half-close-no-pid",
            command: nil,
            requireExisting: false
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\nafter-half-close-input", to: fd))
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("\"ready\""), responseText)
        XCTAssertTrue(responseText.contains("after-half-close-output"), responseText)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPTYBridgeDefersHalfCloseUntilAttachCompletes() throws {
        let attachStarted = DispatchSemaphore(value: 0)
        let attachGate = DispatchSemaphore(value: 0)
        let rpcClient = DelayedOutputPTYBridgeRPC(attachStarted: attachStarted, attachGate: attachGate)
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-half-close-before-attach",
            attachmentID: "attachment-half-close-before-attach",
            command: nil,
            requireExisting: false
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
            "client_pid": Int(getpid()),
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\nafter-half-close-input", to: fd))
        XCTAssertEqual(attachStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(Darwin.shutdown(fd, SHUT_WR), 0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        attachGate.signal()

        let responseData = try readUntilEOF(from: fd, timeout: 2)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let responseText = String(data: responseData, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("\"ready\""), responseText)
        XCTAssertTrue(responseText.contains("after-half-close-output"), responseText)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 0.1), .timedOut)
    }

    func testPTYBridgeDetachesWhenClientSocketClosesAfterAttach() throws {
        let rpcClient = DelayedOutputPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-client-close",
            attachmentID: "attachment-client-close",
            command: nil,
            requireExisting: false
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
            "client_pid": Int(Int32.max),
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            Darwin.close(fd)
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))
        let readyLine = try readLine(from: fd, timeout: 2)
        XCTAssertTrue(readyLine.contains("\"ready\""), readyLine)

        Darwin.close(fd)
        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    }

    func testPTYBridgeClosesBackpressuredOutput() throws {
        let rpcClient = FloodPTYBridgeRPC()
        let stopped = DispatchSemaphore(value: 0)
        let server = WorkspaceRemotePTYBridgeServer(
            rpcClient: rpcClient,
            sessionID: "session-output-flood",
            attachmentID: "attachment-output-flood",
            command: nil,
            requireExisting: false
        ) {
            stopped.signal()
        }
        let endpoint = try server.start()
        let fd = try connectLoopbackTCP(port: endpoint.port)
        defer {
            Darwin.close(fd)
            server.stop()
        }

        let handshakeData = try JSONSerialization.data(withJSONObject: [
            "token": endpoint.token,
            "cols": 80,
            "rows": 24,
        ], options: [])
        guard let handshake = String(data: handshakeData, encoding: .utf8) else {
            return XCTFail("Failed to encode bridge handshake")
        }
        XCTAssertTrue(writeAll(handshake + "\n", to: fd))

        XCTAssertEqual(rpcClient.detachSemaphore.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
    }

    private func connectLoopbackTCP(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_INET)")
        }
        do {
            try configureSocketTimeout(fd, option: SO_RCVTIMEO, timeout: 2)
            try configureSocketTimeout(fd, option: SO_SNDTIMEO, timeout: 2)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let connectResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                throw posixError("connect(127.0.0.1:\(port))")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func readUntilEOF(from fd: Int32, timeout: TimeInterval) throws -> Data {
        try configureSocketTimeout(fd, option: SO_RCVTIMEO, timeout: timeout)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0 {
                return data
            }
            if errno == EINTR {
                continue
            }
            throw posixError("read bridge response")
        }
    }

    private func readLine(from fd: Int32, timeout: TimeInterval) throws -> String {
        try configureSocketTimeout(fd, option: SO_RCVTIMEO, timeout: timeout)
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count > 0 {
                if byte[0] == 0x0A {
                    return String(data: data, encoding: .utf8) ?? ""
                }
                data.append(byte[0])
                continue
            }
            if count == 0 {
                return String(data: data, encoding: .utf8) ?? ""
            }
            if errno == EINTR {
                continue
            }
            throw posixError("read bridge line")
        }
    }

    private func configureSocketTimeout(_ fd: Int32, option: Int32, timeout: TimeInterval) throws {
        let normalizedTimeout = max(timeout, 0)
        let seconds = floor(normalizedTimeout)
        let microseconds = (normalizedTimeout - seconds) * 1_000_000
        var socketTimeout = timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds.rounded()))
        let result = withUnsafePointer(to: &socketTimeout) { ptr in
            Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                option,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw posixError("setsockopt")
        }
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

}
