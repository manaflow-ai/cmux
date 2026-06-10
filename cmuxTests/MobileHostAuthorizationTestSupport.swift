import CMUXMobileCore
import Foundation
@preconcurrency import Network
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Test support types
private enum MobileHostStartedTestSocketError: Error {
    case listenerPortUnavailable
    case listenerNotReady
    case connectionNotReady
}

final class MobileHostStartedTestSocket: @unchecked Sendable {
    let connection: NWConnection
    private let listener: NWListener
    private let queue: DispatchQueue

    init() throws {
        let queue = DispatchQueue(label: "dev.cmux.mobile-host-started-test-socket")
        let listener = try NWListener(using: .tcp, on: .any)
        let listenerReady = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                listenerReady.signal()
            }
        }
        listener.newConnectionHandler = { serverConnection in
            serverConnection.start(queue: queue)
        }
        listener.start(queue: queue)
        guard listenerReady.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw MobileHostStartedTestSocketError.listenerNotReady
        }
        guard let port = listener.port else {
            listener.cancel()
            throw MobileHostStartedTestSocketError.listenerPortUnavailable
        }

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port,
            using: .tcp
        )
        let connectionReady = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connectionReady.signal()
            }
        }
        connection.start(queue: queue)
        guard connectionReady.wait(timeout: .now() + 2) == .success else {
            connection.cancel()
            listener.cancel()
            throw MobileHostStartedTestSocketError.connectionNotReady
        }

        self.listener = listener
        self.connection = connection
        self.queue = queue
    }

    func close() {
        connection.cancel()
        listener.cancel()
    }
}

actor MobileHostConnectionCloseRecorder {
    private var ids: [UUID] = []

    func record(_ id: UUID) {
        ids.append(id)
    }

    func recordedIDs() -> [UUID] {
        ids
    }
}

actor MobileHostConnectionRequestRecorder {
    private var methods: [String] = []

    func record(_ request: MobileHostRPCRequest) {
        methods.append(request.method)
    }

    func recordedMethods() -> [String] {
        methods
    }
}

actor MobileHostConnectionBox {
    private var session: MobileHostConnection?

    func set(_ session: MobileHostConnection) {
        self.session = session
    }

    func close(reason: String) async {
        await session?.close(reason: reason)
    }
}

final class SendableExpectation: @unchecked Sendable {
    private let expectation: XCTestExpectation

    init(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func fulfill() {
        expectation.fulfill()
    }
}

final class SendableSemaphore: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    init(value: Int) {
        semaphore = DispatchSemaphore(value: value)
    }

    func wait() {
        semaphore.wait()
    }

    func signal() {
        semaphore.signal()
    }
}

final class LockedHosts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String] = []

    func set(_ nextHosts: [String]) {
        lock.lock()
        hosts = nextHosts
        lock.unlock()
    }

    func value() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return hosts
    }
}
