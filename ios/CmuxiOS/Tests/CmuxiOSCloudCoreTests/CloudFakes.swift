import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import CmuxMobileWire
import Foundation

struct FakeClosed: Error {}

/// JSON helpers for owner records shaped like backend/catalog/cloud-vectors.json.
enum CloudJSON {
    static func machine(_ id: String, status: String = "running", revision: Int = 1, name: String? = nil,
                        host: String? = nil, createdAt: Int = 1_790_000_000_000) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "team": .string("team_a"), "creator": .string("user_a"),
            "name": name.map(JSONValue.string) ?? .null,
            "size": .object(["cpu": .int(2), "memory_mb": .int(4096), "disk_mb": .int(16384)]),
            "status": .string(status),
            "image": .object(["id": .string("img"), "daemon_version": .null]),
            "host": host.map(JSONValue.string) ?? .null, "classic": .bool(false),
            "created_at": .int(Int64(createdAt)), "last_active_at": .null,
            "idle_policy": .object(["idle_seconds": .int(0)]), "error": .null,
            "revision": .string(String(revision)),
        ]
        if status == "paused" { object["pause_reason"] = .string("idle") }
        return .object(object)
    }

    static func plan(active: Int = 1, maxActive: Int = 2) -> JSONValue {
        .object([
            "plan_id": .string("dev"), "upgrade_plan": .string("pro"),
            "limits": .object(["max_active": .int(Int64(maxActive)), "max_saved": .int(4),
                               "memory_options_mb": .array([.int(4096), .int(2048)]),
                               "locked_memory_options_mb": .array([.int(16384)]), "vm_hours_included": .null]),
            "usage": .object(["active": .int(Int64(active)), "saved": .int(0), "vm_hours_used": .int(3),
                              "period_end": .int(1_800_000_000_000)]),
        ])
    }

    static func linkToken(host: String = "host_h0000000000000000001", epoch: Int = 7,
                          services: [String] = ["daemon"], token: String = "secret",
                          expiresAt: Int64 = 2_000_000_000_000) -> JSONValue {
        .object([
            "token": .string(token), "expires_at": .int(expiresAt), "host": .string(host),
            "epoch": .int(Int64(epoch)), "services": .array(services.map(JSONValue.string)),
        ])
    }

    static func text(_ value: JSONValue) -> String { String(decoding: try! value.canonicalData(), as: UTF8.self) }
}

struct FakeCredentials: CloudCredentials {
    func token(for principal: CloudPrincipal) async throws -> String { principal == .session ? "session-token" : "install-token" }
    func invalidate(_ principal: CloudPrincipal) async {}
}

/// A scripted `CloudAPIClient` over a machine table.
actor FakeCloudAPI: CloudAPIClient {
    struct Call: Equatable {
        var op: String
        var key: String?
        var principal: CloudPrincipal?
        var params: [String: JSONValue]
    }

    var machines: [JSONValue] = []
    var planValue: JSONValue = CloudJSON.plan()
    var connectInfoValue: JSONValue?
    var listRevision = 1
    /// Replies for mutations, in order; empty = committed with no machine.
    var replies: [CloudOpReply] = []
    private(set) var calls: [Call] = []
    /// Set to hold the next mutation until `release()`.
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    func set(machines: [JSONValue], revision: Int) {
        self.machines = machines
        listRevision = revision
    }

    func setConnectInfo(_ value: JSONValue) { connectInfoValue = value }

    func set(replies: [CloudOpReply]) { self.replies = replies }

    func holdNextMutation() { holdNext = true }

    /// Waits until a held mutation arrived.
    func waitForHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func count(_ op: String) -> Int { calls.filter { $0.op == op }.count }

    func read(_ op: String, params: [String: JSONValue]) async throws -> JSONValue {
        calls.append(Call(op: op, key: nil, principal: nil, params: params))
        switch op {
        case "cloud.machine.list":
            return .object(["machines": .array(machines), "next_cursor": .null, "revision": .string(String(listRevision))])
        case "cloud.plan.get":
            return planValue
        case "cloud.machine.connect_info":
            guard let connectInfoValue else { throw CloudAPIError.refused(code: "cloud.machine.not_bound") }
            return connectInfoValue
        default:
            throw CloudAPIError.refused(code: "validation.invalid")
        }
    }

    func mutate(_ op: String, params: [String: JSONValue], key: String, as principal: CloudPrincipal) async throws -> CloudOpReply {
        calls.append(Call(op: op, key: key, principal: principal, params: params))
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        guard !replies.isEmpty else { return .committed(value: .object([:]), revision: 1) }
        return replies.removeFirst()
    }
}

/// Inbound frames for one fake socket.
actor FakeInbox {
    private var queue: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var closed = false

    func push(_ data: Data) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            queue.append(data)
        }
    }

    func close() {
        closed = true
        waiter?.resume(throwing: FakeClosed())
        waiter = nil
    }

    func next() async throws -> Data {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw FakeClosed() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

/// Frames the client sent, with a wait for the next one.
actor FakeOutbox {
    private(set) var frames: [String] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ text: String) {
        frames.append(text)
        let ready = waiters.filter { frames.count >= $0.count }
        waiters.removeAll { frames.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(count: Int) async {
        if frames.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

final class FakeCloudConnection: CloudWireConnection {
    let inbox = FakeInbox()
    let outbox = FakeOutbox()

    func receive() async throws -> Data { try await inbox.next() }
    func send(_ text: String) async throws { await outbox.append(text) }
    func close() { Task { await inbox.close() } }

    func push(_ value: JSONValue) async { await inbox.push(try! value.canonicalData()) }
}

actor FakeCloudTransport: CloudWireTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var connections: [FakeCloudConnection] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func connect(_ request: URLRequest) async throws -> any CloudWireConnection {
        requests.append(request)
        let connection = FakeCloudConnection()
        connections.append(connection)
        let ready = waiters.filter { connections.count >= $0.count }
        waiters.removeAll { connections.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
        return connection
    }

    func connection(_ index: Int) async -> FakeCloudConnection {
        if connections.count <= index {
            await withCheckedContinuation { waiters.append((index + 1, $0)) }
        }
        return connections[index]
    }
}

/// Reads snapshots until one matches.
func next(
    _ iterator: inout AsyncStream<SourceSnapshot<CloudState>>.Iterator,
    where predicate: (SourceSnapshot<CloudState>) -> Bool
) async -> SourceSnapshot<CloudState>? {
    while let snapshot = await iterator.next() {
        if predicate(snapshot) { return snapshot }
    }
    return nil
}
