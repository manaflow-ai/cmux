import CmuxIrxTransport
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A scripted account socket: the test pushes server frames and reads what the client sent.
private actor ScriptedAccountSocket: V2ControlSocket {
    private var inbox: [Data] = []
    private var receiver: CheckedContinuation<Data, any Error>?
    private var sentFrames: [Data] = []
    private var sentWaiters: [(Int, CheckedContinuation<[Data], Never>)] = []
    private(set) var closed = false
    private var pendingFailure: (any Error)?

    func push(_ json: String) {
        let data = Data(json.utf8)
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw V2ControlFailure.unavailable }
        sentFrames.append(data)
        let ready = sentWaiters.filter { sentFrames.count >= $0.0 }
        sentWaiters.removeAll { sentFrames.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume(returning: sentFrames) }
    }

    func receive() async throws -> Data {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if let pendingFailure {
            self.pendingFailure = nil
            throw pendingFailure
        }
        guard !closed else { throw V2ControlFailure.unavailable }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func ping() async throws {}

    /// Ends the next or pending receive with `error`, as a server close does.
    func fail(_ error: any Error) {
        if let receiver {
            self.receiver = nil
            receiver.resume(throwing: error)
        } else {
            pendingFailure = error
        }
    }

    func close() async {
        closed = true
        receiver?.resume(throwing: V2ControlFailure.unavailable)
        receiver = nil
    }

    /// Waits until the client has sent at least `count` frames.
    func sent(atLeast count: Int) async -> [String] {
        if sentFrames.count >= count { return sentFrames.map { String(decoding: $0, as: UTF8.self) } }
        let frames = await withCheckedContinuation { sentWaiters.append((count, $0)) }
        return frames.map { String(decoding: $0, as: UTF8.self) }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor SocketQueue {
    private(set) var sockets: [ScriptedAccountSocket] = []
    func append(_ socket: ScriptedAccountSocket) { sockets.append(socket) }
}

/// Records effects in order, shared between the test and the client's closures.
private final class EffectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var signedBytes: [Data] = []
    private var requests: [URLRequest] = []
    private var sleeps: [TimeInterval] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    func signed(_ data: Data) { lock.withLock { signedBytes.append(data) } }
    func request(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    func slept(_ seconds: TimeInterval) { lock.withLock { sleeps.append(seconds) } }
    var all: [String] { lock.withLock { entries } }
    var signatures: [Data] { lock.withLock { signedBytes } }
    var httpRequests: [URLRequest] { lock.withLock { requests } }
    var sleepDurations: [TimeInterval] { lock.withLock { sleeps } }
}

@Suite("Devices: account directory client", .timeLimit(.minutes(1)))
struct AccountMacDirectoryClientTests {
    static let key = String(repeating: "a", count: 64)
    static let identity = V2Identity(appNamespace: "com.cmuxterm.app", buildTag: "default", deviceID: "self",
        environment: "production", projectID: "project", teamID: "A", userID: "user")
    static let device = V2DeviceDescriptor(endpointID: key, identity: identity, identityGeneration: 1,
        metadata: V2DeviceMetadata(appVersion: "1", capabilities: ["irx-v2", "cmux.mac-host.v1"],
            displayName: "self", pairingEnabled: false, platform: .mac, relayURLs: []))
    static let credentials = AccountMacDirectoryClient.Credentials(device: device,
        ticket: V2Ticket(expiresAt: 4_000_000_000, refreshAfter: 3_999_999_000, token: "ticket-token"))
    static let directoryJSON = """
    {"userId":"user","revision":4,"macs":[],"inboundMacs":[],"relayURLs":["https://relay.example"],\
    "issuedAt":1000,"permissionExpiresAt":2000,"rules":["cmux.mac-account-peer.v1"]}
    """

    private func makeClient(socket: ScriptedAccountSocket?, log: EffectLog,
                            connectFailure: (any Error)? = nil, httpStatus: Int = 200) -> AccountMacDirectoryClient {
        AccountMacDirectoryClient(baseURL: URL(string: "https://iroh.example")!, dependencies: .init(
            connect: { request in
                log.request(request)
                if let connectFailure { throw connectFailure }
                guard let socket else { throw V2ControlFailure.unavailable }
                return socket
            },
            http: { request in
                log.request(request)
                log.append("account-withdraw")
                return V2HTTPResponse(status: httpStatus, body: Data(), retryAfter: nil)
            },
            sign: { data in
                log.signed(data)
                return Data(repeating: 7, count: 64)
            },
            now: { Date(timeIntervalSince1970: 1500) },
            sleep: { seconds in
                log.slept(seconds)
                // Resync backoff and an overdue refresh return at once; ping,
                // reconnect backoff and future refreshes wait for the test to end.
                if seconds <= 1 { return }
                try await Task.sleep(for: .seconds(3600))
            }))
    }

    /// Polls a condition with a bounded number of short sleeps.
    private static func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<2000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never held")
    }

    private static func ready(_ socket: ScriptedAccountSocket) async {
        await socket.push(#"{"schemaId":"account.ready.v1","requestId":"r","sessionId":"s","revision":1}"#)
    }

    private static func page(_ requestID: String, revision: Int = 4, macs: String = "", cursor: String? = nil,
                             inbound: String = "", issuedAt: Int = 1000, expiresAt: Int = 2000) -> String {
        let next = cursor.map { "\"" + $0 + "\"" } ?? "null"
        return #"{"schemaId":"account.directory.result.v1","requestId":"\#(requestID)","directory":{"userId":"user","revision":\#(revision),"macs":[\#(macs)],"inboundMacs":[\#(inbound)],"relayURLs":["https://relay.example"],"issuedAt":\#(issuedAt),"permissionExpiresAt":\#(expiresAt),"rules":["cmux.mac-account-peer.v1"],"nextCursor":\#(next)}}"#
    }

    private static func mac(_ device: String, team: String, endpoint: Character) -> String {
        let key = String(repeating: endpoint, count: 64)
        return #"{"deviceRecordId":"\#(team)-\#(device)","revision":1,"revoked":false,"descriptor":{"endpointId":"\#(key)","identityGeneration":1,"identity":{"appNamespace":"com.cmuxterm.app","buildTag":"default","deviceId":"\#(device)","environment":"production","projectId":"project","teamId":"\#(team)","userId":"user"},"metadata":{"appVersion":"1","capabilities":["irx-v2","cmux.mac-devices.v1","cmux.mac-host.v1"],"displayName":"\#(device)","pairingEnabled":false,"platform":"mac","relayURLs":["https://relay.example"]}}}"#
    }

    private static func error(_ requestID: String, code: String) -> String {
        #"{"schemaId":"error.v1","requestId":"\#(requestID)","code":"\#(code)","retryable":true}"#
    }

    private static func json(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private static func setup(of request: URLRequest) throws -> [String: Any] {
        var header = try #require(request.value(forHTTPHeaderField: "x-cmux-v2-setup"))
        header = header.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        header += String(repeating: "=", count: (4 - header.count % 4) % 4)
        let data = try #require(Data(base64Encoded: header))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("The socket opens with the team ticket and an account-purpose proof over the bare setup")
    func socketHandshake() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        _ = await socket.sent(atLeast: 0)
        await socket.push(#"{"schemaId":"account.ready.v1","requestId":"r","sessionId":"s","revision":1}"#)
        _ = await socket.sent(atLeast: 2)
        let request = try #require(log.httpRequests.first)
        #expect(request.url?.absoluteString == "wss://iroh.example/v2/account/socket")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "IrohTicket ticket-token")
        let setup = try Self.setup(of: request)
        #expect(setup["schemaId"] as? String == "session.open.v1")
        let proof = try #require(setup["proof"] as? [String: Any])
        let nonce = try #require(proof["nonce"] as? String)
        #expect(nonce.count == 22)
        #expect(proof["requestId"] as? String == setup["requestId"] as? String)
        let signedData = try #require(log.signatures.first)
        let signed = try #require(try JSONSerialization.jsonObject(with: signedData) as? [String: Any])
        #expect(signed["purpose"] as? String == "cmux-iroh-v2-account-request")
        #expect(signed["requestId"] as? String == setup["requestId"] as? String)
        #expect(signed["nonce"] as? String == nonce)
        let body = try #require(signed["body"] as? [String: Any])
        #expect(body["proof"] == nil)
        #expect(body["schemaId"] as? String == "session.open.v1")
        #expect(body["requestId"] as? String == setup["requestId"] as? String)
        await client.stop()
    }

    @Test("Ready publishes and reads the directory; a change notice reads it again")
    func publishAndRefresh() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        var changes = await client.changes().makeAsyncIterator()
        _ = await changes.next()
        await client.update(Self.credentials)
        await socket.push(#"{"schemaId":"account.ready.v1","requestId":"r","sessionId":"s","revision":1}"#)
        let first = await socket.sent(atLeast: 2)
        #expect(try Self.json(first[0])["schemaId"] as? String == "account.publish.v1")
        let directoryRequest = try Self.json(first[1])
        #expect(directoryRequest["schemaId"] as? String == "account.directory.v1")
        let requestID = try #require(directoryRequest["requestId"] as? String)
        await socket.push(#"{"schemaId":"account.directory.result.v1","requestId":"\#(requestID)","directory":\#(Self.directoryJSON)}"#)
        _ = await changes.next()
        let snapshot = try #require(await client.snapshot())
        #expect(snapshot.directory.revision == 4)
        #expect(snapshot.belongs(to: Self.device))
        await socket.push(#"{"schemaId":"account.changed.v1","userId":"user","revision":5}"#)
        let after = await socket.sent(atLeast: 3)
        #expect(try Self.json(after[2])["schemaId"] as? String == "account.directory.v1")
        await client.stop()
        #expect(await client.snapshot() == nil)
    }

    @Test("A directory for another user is refused")
    func refusesOtherUser() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await socket.push(#"{"schemaId":"account.ready.v1","requestId":"r","sessionId":"s","revision":1}"#)
        let sent = await socket.sent(atLeast: 2)
        let requestID = try #require(try Self.json(sent[1])["requestId"] as? String)
        let other = Self.directoryJSON.replacingOccurrences(of: #""userId":"user""#, with: #""userId":"other""#)
        await socket.push(#"{"schemaId":"account.directory.result.v1","requestId":"\#(requestID)","directory":\#(other)}"#)
        try await Self.eventually { await client.phase == .refused }
        #expect(await client.snapshot() == nil)
        #expect(await socket.closed)
        #expect(log.httpRequests.count == 1)
        await client.stop()
    }

    @Test("A service without the account route is unsupported and retried only after the long delay")
    func unsupportedService() async throws {
        let log = EffectLog()
        let client = makeClient(socket: nil, log: log,
            connectFailure: V2ControlFailure.http(status: 404, retryAfter: nil))
        await client.update(Self.credentials)
        try await Self.eventually { log.sleepDurations.contains(AccountMacDirectoryClient.unsupportedRetryDelay) }
        #expect(await client.isUnsupported)
        #expect(await client.snapshot() == nil)
        #expect(log.httpRequests.count == 1)
        // Nothing was published, so nothing is withdrawn.
        await client.withdraw()
        #expect(!log.all.contains("account-withdraw"))
    }

    @Test("Withdrawal completes before the caller's team withdrawal and signs {setup, request}")
    func withdrawIsAwaitedFirst() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await socket.push(#"{"schemaId":"account.ready.v1","requestId":"r","sessionId":"s","revision":1}"#)
        _ = await socket.sent(atLeast: 2)
        // MobileHostIrxRuntime.transition awaits this before its team withdrawal.
        await client.withdraw()
        log.append("team-withdraw")
        #expect(log.all == ["account-withdraw", "team-withdraw"])
        let request = try #require(log.httpRequests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://iroh.example/v2/account/requests")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "IrohTicket ticket-token")
        let bodyData = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["schemaId"] as? String == "account.withdraw.v1")
        let setup = try Self.setup(of: request)
        #expect(body["requestId"] as? String == setup["requestId"] as? String)
        let signedData = try #require(log.signatures.last)
        let signed = try #require(try JSONSerialization.jsonObject(with: signedData) as? [String: Any])
        #expect(signed["purpose"] as? String == "cmux-iroh-v2-account-request")
        let signedBody = try #require(signed["body"] as? [String: Any])
        #expect((signedBody["request"] as? [String: Any])?["schemaId"] as? String == "account.withdraw.v1")
        #expect((signedBody["setup"] as? [String: Any])?["proof"] == nil)
        #expect(await client.phase == .stopped)
    }

    @Test("A paged directory is read to the end at one revision before it is used")
    func paging() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await Self.ready(socket)
        let first = await socket.sent(atLeast: 2)
        let firstID = try #require(try Self.json(first[1])["requestId"] as? String)
        await socket.push(Self.page(firstID, macs: Self.mac("one", team: "B", endpoint: "b"), cursor: "B-one"))
        let second = try Self.json(await socket.sent(atLeast: 3)[2])
        #expect(second["schemaId"] as? String == "account.directory.v1")
        #expect(second["cursor"] as? String == "B-one")
        #expect(second["haveRevision"] as? Int == 4)
        #expect(await client.snapshot() == nil)
        let secondID = try #require(second["requestId"] as? String)
        await socket.push(Self.page(secondID, macs: Self.mac("two", team: "C", endpoint: "c")))
        try await Self.eventually { await client.snapshot() != nil }
        let snapshot = try #require(await client.snapshot())
        #expect(snapshot.directory.macs.map(\.deviceRecordID) == ["B-one", "C-two"])
        #expect(snapshot.directory.nextCursor == nil)
        await client.stop()
    }

    @Test("resync_required restarts the read from the first page, a bounded number of times", arguments: [false, true])
    func resync(onCursorPage: Bool) async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await Self.ready(socket)
        var sent = await socket.sent(atLeast: 2)
        var pending = try #require(try Self.json(sent[1])["requestId"] as? String)
        if onCursorPage {
            await socket.push(Self.page(pending, macs: Self.mac("one", team: "B", endpoint: "b"), cursor: "B-one"))
            sent = await socket.sent(atLeast: 3)
            pending = try #require(try Self.json(sent[2])["requestId"] as? String)
        }
        for attempt in 1...AccountMacDirectoryClient.maximumResyncAttempts {
            let before = sent.count
            await socket.push(Self.error(pending, code: "resync_required"))
            sent = await socket.sent(atLeast: before + 1)
            let retry = try Self.json(sent[before])
            #expect(retry["schemaId"] as? String == "account.directory.v1")
            #expect(retry["cursor"] == nil, "attempt \(attempt) must restart from the first page")
            pending = try #require(retry["requestId"] as? String)
        }
        #expect(await client.phase == .ready)
        await socket.push(Self.error(pending, code: "resync_required"))
        try await Self.eventually { await client.phase == .backingOff }
        #expect(await client.snapshot() == nil)
        await client.stop()
    }

    @Test("resync_required on publish republishes")
    func publishResync() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await Self.ready(socket)
        let sent = await socket.sent(atLeast: 2)
        let publishID = try #require(try Self.json(sent[0])["requestId"] as? String)
        await socket.push(Self.error(publishID, code: "resync_required"))
        let after = await socket.sent(atLeast: 3)
        #expect(try Self.json(after[2])["schemaId"] as? String == "account.publish.v1")
        #expect(await client.phase == .ready)
        await client.stop()
    }

    @Test("A refusal ends the session team-only without reconnecting", arguments: [
        "close-1008", "device_revoked", "ticket_expired", "permission_denied", "payload_too_large",
    ])
    func refusalIsTerminal(_ refusal: String) async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await Self.ready(socket)
        let sent = await socket.sent(atLeast: 2)
        let directoryID = try #require(try Self.json(sent[1])["requestId"] as? String)
        await socket.push(Self.page(directoryID))
        try await Self.eventually { await client.snapshot() != nil }
        if refusal == "close-1008" {
            await socket.fail(V2ControlFailure.socketClosed(code: 1008, reason: "device_revoked"))
        } else {
            await socket.push(Self.error("unsolicited", code: refusal))
        }
        try await Self.eventually { await client.phase == .refused }
        #expect(await client.snapshot() == nil)
        #expect(log.httpRequests.count == 1)
        // New credentials (a refreshed ticket) try again.
        let refreshed = AccountMacDirectoryClient.Credentials(device: Self.device,
            ticket: V2Ticket(expiresAt: 4_000_000_001, refreshAfter: 3_999_999_001, token: "ticket-token-2"))
        await client.update(refreshed)
        try await Self.eventually { log.httpRequests.count == 2 }
        await client.stop()
    }

    @Test("The directory is re-read before the earliest inbound grant lapses")
    func refreshBeforeGrantLapse() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = makeClient(socket: socket, log: log)
        await client.update(Self.credentials)
        await Self.ready(socket)
        let sent = await socket.sent(atLeast: 2)
        let directoryID = try #require(try Self.json(sent[1])["requestId"] as? String)
        // The grant lapses 30s from now; the refresh is due at once.
        let grant = #"{"device":"# + Self.mac("peer", team: "B", endpoint: "b") + #","permissionExpiresAt":1530}"#
        await socket.push(Self.page(directoryID, inbound: grant))
        let after = await socket.sent(atLeast: 3)
        #expect(try Self.json(after[2])["schemaId"] as? String == "account.directory.v1")
        await client.stop()
    }

    @Test("The refresh lead is a third of the remaining lease, at most a minute")
    func refreshDelay() {
        func directory(issuedAt: Int, expiresAt: Int, grants: [Int]) -> AccountMacDirectory {
            let peer = V2DeviceRecord(descriptor: Self.device, deviceRecordID: "x", revision: 1, revoked: false)
            return AccountMacDirectory(userID: "user", revision: 1, macs: [],
                inboundMacs: grants.map { V2InboundPeerPermission(device: peer, permissionExpiresAt: $0) },
                relayURLs: [], issuedAt: issuedAt, permissionExpiresAt: expiresAt, rules: [])
        }
        let now = Date(timeIntervalSince1970: 1000)
        // Five-minute grant: re-read one minute before it lapses.
        #expect(AccountMacDirectoryClient.refreshDelay(for: directory(issuedAt: 1000, expiresAt: 4600, grants: [1300]), now: now) == 240)
        // No grants: follow the directory lease.
        #expect(AccountMacDirectoryClient.refreshDelay(for: directory(issuedAt: 1000, expiresAt: 4600, grants: []), now: now) == 3540)
        // A short lease keeps a proportional lead and never schedules in the past.
        #expect(AccountMacDirectoryClient.refreshDelay(for: directory(issuedAt: 1000, expiresAt: 1030, grants: []), now: now) == 20)
        #expect(AccountMacDirectoryClient.refreshDelay(for: directory(issuedAt: 1000, expiresAt: 1030, grants: []),
            now: Date(timeIntervalSince1970: 1100)) == 1)
    }

    @Test("Withdrawal after a team switch still signs with the old key although the scope moved")
    func withdrawAfterScopeMoved() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let scopeMoved = LockedFlag()
        let client = AccountMacDirectoryClient(baseURL: URL(string: "https://iroh.example")!, dependencies: .init(
            connect: { request in log.request(request); return socket },
            http: { request in
                log.request(request)
                log.append("account-withdraw")
                return V2HTTPResponse(status: 200, body: Data(), retryAfter: nil)
            },
            sign: { data in
                // Like the runtime: socket proofs need the current account scope.
                if scopeMoved.value { throw V2ControlFailure.scopeMismatch }
                log.signed(data)
                return Data(repeating: 7, count: 64)
            },
            signWithdrawal: { data in
                log.signed(data)
                return Data(repeating: 9, count: 64)
            },
            now: { Date(timeIntervalSince1970: 1500) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
        await client.update(Self.credentials)
        await Self.ready(socket)
        _ = await socket.sent(atLeast: 2)
        scopeMoved.value = true
        await client.withdraw()
        #expect(log.all == ["account-withdraw"])
        let request = try #require(log.httpRequests.last)
        #expect(request.url?.path == "/v2/account/requests")
    }

    @Test("A socket that reaches ready and then fails keeps climbing the backoff ladder")
    func backoffClimbsAfterReady() async throws {
        let log = EffectLog()
        let sockets = SocketQueue()
        let client = AccountMacDirectoryClient(baseURL: URL(string: "https://iroh.example")!, dependencies: .init(
            connect: { request in
                log.request(request)
                let socket = ScriptedAccountSocket()
                await socket.push(#"{"schemaId":"account.ready.v1","requestId":"r","sessionId":"s","revision":1}"#)
                await socket.push(#"{"schemaId":"error.v1","requestId":"unsolicited","code":"upstream_unavailable","retryable":true}"#)
                await sockets.append(socket)
                return socket
            },
            http: { _ in V2HTTPResponse(status: 200, body: Data(), retryAfter: nil) },
            sign: { _ in Data(repeating: 7, count: 64) },
            now: { Date(timeIntervalSince1970: 1500) },
            sleep: { seconds in
                log.slept(seconds)
                // Reconnect backoff returns at once; ping and the read timeout wait.
                if seconds == AccountMacDirectoryClient.pingInterval
                    || seconds == AccountMacDirectoryClient.readTimeout {
                    try await Task.sleep(for: .seconds(3600))
                }
            }))
        await client.update(Self.credentials)
        try await Self.eventually { log.httpRequests.count >= 4 }
        await client.stop()
        let backoff = log.sleepDurations.filter {
            $0 != AccountMacDirectoryClient.pingInterval && $0 != AccountMacDirectoryClient.readTimeout
        }
        #expect(Array(backoff.prefix(3)) == [5, 10, 20])
    }

    @Test("A directory request with no answer fails the socket instead of blocking later reads")
    func readTimeoutReconnects() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let client = AccountMacDirectoryClient(baseURL: URL(string: "https://iroh.example")!, dependencies: .init(
            connect: { request in log.request(request); return socket },
            http: { _ in V2HTTPResponse(status: 200, body: Data(), retryAfter: nil) },
            sign: { _ in Data(repeating: 7, count: 64) },
            now: { Date(timeIntervalSince1970: 1500) },
            sleep: { seconds in
                log.slept(seconds)
                if seconds == AccountMacDirectoryClient.readTimeout { return }
                try await Task.sleep(for: .seconds(3600))
            }))
        await client.update(Self.credentials)
        await Self.ready(socket)
        _ = await socket.sent(atLeast: 2)
        try await Self.eventually { await socket.closed }
        try await Self.eventually { await client.phase == .backingOff }
        await client.stop()
    }

    @Test("A resync retry hint longer than the read timeout is honored, not cut off")
    func resyncRetryAfterOutlastsReadTimeout() async throws {
        let socket = ScriptedAccountSocket()
        let log = EffectLog()
        let timeoutCancelled = LockedFlag()
        let retryReleased = LockedFlag()
        let client = AccountMacDirectoryClient(baseURL: URL(string: "https://iroh.example")!, dependencies: .init(
            connect: { request in log.request(request); return socket },
            http: { _ in V2HTTPResponse(status: 200, body: Data(), retryAfter: nil) },
            sign: { _ in Data(repeating: 7, count: 64) },
            now: { Date(timeIntervalSince1970: 1500) },
            sleep: { seconds in
                log.slept(seconds)
                if seconds == AccountMacDirectoryClient.readTimeout {
                    do {
                        while true { try await Task.sleep(for: .milliseconds(2)) }
                    } catch {
                        timeoutCancelled.value = true
                        throw error
                    }
                } else if seconds == 20 {
                    while !retryReleased.value { try await Task.sleep(for: .milliseconds(2)) }
                } else {
                    try await Task.sleep(for: .seconds(3600))
                }
            }))
        await client.update(Self.credentials)
        await Self.ready(socket)
        let sent = await socket.sent(atLeast: 2)
        let pending = try #require(try Self.json(sent[1])["requestId"] as? String)
        await socket.push(#"{"schemaId":"error.v1","requestId":"\#(pending)","code":"resync_required","retryable":true,"retryAfterMs":20000}"#)
        try await Self.eventually { log.sleepDurations.contains(20) }
        // The read timer elapses during the server-requested wait.
        try await Self.eventually { timeoutCancelled.value }
        #expect(await !socket.closed)
        retryReleased.value = true
        let after = await socket.sent(atLeast: 3)
        #expect(try Self.json(after[2])["schemaId"] as? String == "account.directory.v1")
        await client.stop()
    }

    @Test("Withdrawing a client that never connected sends nothing")
    func withdrawWithoutPublishing() async {
        let log = EffectLog()
        let client = makeClient(socket: nil, log: log)
        await client.withdraw()
        #expect(log.httpRequests.isEmpty)
    }
}
