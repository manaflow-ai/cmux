import CMUXMobileCore
import Foundation
@preconcurrency import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension MobileHostAuthorizationTests {
    @Test func testProductionListenerRetiresAuthorizedInteractionSessionOnDisconnect() async throws {
        let service = MobileHostService.shared
        let controller = TerminalController.shared
        let defaults = UserDefaults.standard
        let enabledKey = MobileHostService.listeningEnabledDefaultsKey
        let previousEnabled = defaults.object(forKey: enabledKey)
        let surfaceID = UUID()
        let clientID = "production-listener-client"
        let sessionID = "production-listener-session"
        var client: MobileHostLoopbackTestClient?
        defer {
            client?.close()
            service.stop()
            service.debugResetMobileLifecycleStateForTesting()
            controller.mobileInteractionEpochsBySurfaceID[surfaceID] = nil
            if let previousEnabled {
                defaults.set(previousEnabled, forKey: enabledKey)
            } else {
                defaults.removeObject(forKey: enabledKey)
            }
        }

        service.stop()
        service.debugResetMobileLifecycleStateForTesting()
        defaults.set(true, forKey: enabledKey)
        let status = await service.ensureListeningAndReady()
        let port = try #require(status.port)
        let loopbackClient = try await Task.detached {
            try MobileHostLoopbackTestClient(port: port)
        }.value
        client = loopbackClient
        controller.mobileInteractionEpochsBySurfaceID[surfaceID] = [
            clientID: [sessionID: 1]
        ]

        let request = Data(
            """
            {"id":"ownership","method":"mobile.host.status","params":{"client_id":"\(clientID)","interaction_session_id":"\(sessionID)","interaction_epoch":1}}
            """.utf8
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(request)
        try await Task.detached {
            try loopbackClient.sendAndWaitForResponse(frame)
            loopbackClient.close()
        }.value
        client = nil

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.mobileInteractionEpochsBySurfaceID[surfaceID] != nil,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(
            controller.mobileInteractionEpochsBySurfaceID[surfaceID] == nil,
            "The production listener must record session ownership so disconnect retires its interaction epoch."
        )
    }
}

private enum MobileHostLoopbackTestClientError: Error {
    case invalidPort
    case connectionNotReady
    case sendFailed
    case responseUnavailable
}

private final class MobileHostLoopbackTestClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.cmux.mobile-host-loopback-test-client")

    init(port: Int) throws {
        guard let rawPort = UInt16(exactly: port),
              let endpointPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw MobileHostLoopbackTestClientError.invalidPort
        }
        connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: endpointPort,
            using: .tcp
        )
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success,
              case .ready = connection.state else {
            connection.cancel()
            throw MobileHostLoopbackTestClientError.connectionNotReady
        }
    }

    func sendAndWaitForResponse(_ frame: Data) throws {
        let sent = DispatchSemaphore(value: 0)
        let sendSucceeded = MobileHostTestLockedBox(false)
        connection.send(content: frame, completion: .contentProcessed { error in
            sendSucceeded.set(error == nil)
            sent.signal()
        })
        guard sent.wait(timeout: .now() + 2) == .success,
              sendSucceeded.get() else {
            throw MobileHostLoopbackTestClientError.sendFailed
        }

        var responseBuffer = Data()
        let deadline = DispatchTime.now() + 2
        while DispatchTime.now() < deadline {
            let received = DispatchSemaphore(value: 0)
            let result = MobileHostTestLockedBox<(Data?, NWError?)>((nil, nil))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data,
                _,
                _,
                error in
                result.set((data, error))
                received.signal()
            }
            guard received.wait(timeout: deadline) == .success else { break }
            let (data, error) = result.get()
            if let error {
                throw error
            }
            if let data {
                responseBuffer.append(data)
            }
            if try !MobileSyncFrameCodec.decodeFrames(from: &responseBuffer).isEmpty {
                return
            }
        }
        throw MobileHostLoopbackTestClientError.responseUnavailable
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

private final class MobileHostTestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
