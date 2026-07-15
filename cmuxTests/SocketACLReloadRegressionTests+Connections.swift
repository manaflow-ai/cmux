import Darwin
import Foundation
import Testing
@testable import CmuxControlSocket
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SocketACLReloadRegressionTests {
    @Test(arguments: [false, true])
    func deniedConnectionReceivesAccessDeniedResponse(revokedBeforeHandling: Bool) throws {
        let controller = TerminalController.shared
        controller.stop()

        let directory = shortTemporaryDirectory(prefix: "sald")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .cmuxOnly
        )
        #expect(controller.socketServer.isRunning)

        let sockets = try makeSocketPair()
        defer { close(sockets.client) }
        try configureReadTimeout(sockets.client)
        try writeLine("ping", to: sockets.client)

        let authorizationGeneration = controller.socketServer.connectionAuthorizationGeneration
        if revokedBeforeHandling { controller.socketServer.reconfigure(accessMode: .automation) }
        let yieldResult = controller.socketServer.connectionsContinuation.yield(
            ControlConnection(
                socket: sockets.server,
                peerProcessID: revokedBeforeHandling ? getpid() : 1,
                authorizationGeneration: authorizationGeneration
            )
        )
        if case .enqueued = yieldResult {
            // Ownership transferred to TerminalController's connection consumer.
        } else {
            close(sockets.server)
            Issue.record("Failed to enqueue the synthetic denied connection")
        }

        let response = try readLine(from: sockets.client)
        #expect(response == TerminalController.socketClientAccessDeniedResponse)
    }

    @Test func idleEventStreamClosesWhenPolicyGenerationChanges() throws {
        let controller = TerminalController.shared
        controller.stop()
        CmuxEventBus.shared.resetForTesting()

        let directory = shortTemporaryDirectory(prefix: "sals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        defer {
            controller.stop()
            CmuxEventBus.shared.resetForTesting()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.start(tabManager: TabManager(), socketPath: socketPath, accessMode: .allowAll)
        let sockets = try makeSocketPair()
        defer { close(sockets.client) }
        try configureReadTimeout(sockets.client)
        try writeLine(
            #"{"id":"stream","method":"events.stream","params":{"include_heartbeats":false}}"#,
            to: sockets.client
        )

        let authorization = controller.socketServer.acceptedConnectionAuthorization()
        let yieldResult = controller.socketServer.connectionsContinuation.yield(
            ControlConnection(
                socket: sockets.server,
                peerProcessID: getpid(),
                authorizationGeneration: authorization.generation,
                authorizationRevocationSignal: authorization.revocationSignal
            )
        )
        if case .enqueued = yieldResult {
            // Ownership transferred to TerminalController's connection consumer.
        } else {
            close(sockets.server)
            Issue.record("Failed to enqueue the synthetic event-stream connection")
        }

        let acknowledgement = try readLine(from: sockets.client)
        let acknowledgementData = try #require(acknowledgement.data(using: .utf8))
        let acknowledgementObject = try #require(
            JSONSerialization.jsonObject(with: acknowledgementData) as? [String: Any]
        )
        #expect(acknowledgementObject["type"] as? String == "ack")

        #expect(controller.socketServer.reconfigure(accessMode: .automation))

        var byte: UInt8 = 0
        #expect(Darwin.read(sockets.client, &byte, 1) == 0)
    }

    private func makeSocketPair() throws -> (client: Int32, server: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw posixError("socketpair")
        }
        return (client: descriptors[0], server: descriptors[1])
    }

    private func configureReadTimeout(_ socket: Int32) throws {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                socket,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else { throw posixError("setsockopt(SO_RCVTIMEO)") }
    }

    private func writeLine(_ line: String, to socket: Int32) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    socket,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError("write") }
                offset += written
            }
        }
    }

    private func readLine(from socket: Int32) throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(socket, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError("read") }
            guard count > 0 else { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ECONNRESET),
                userInfo: [NSLocalizedDescriptionKey: "Socket closed without an access-denied response"]
            )
        }
        guard let response = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInapplicableStringEncodingError
            )
        }
        return response
    }

    private func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"
            ]
        )
    }
}
