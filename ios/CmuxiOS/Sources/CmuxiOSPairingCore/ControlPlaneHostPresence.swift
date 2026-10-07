public import CmuxControlPlane
import CmuxMobileWire
import Foundation

/// `HostPresenceSource` over each Mac's HostDO control socket
/// (`/v1/wire/host/<host>?team=<team>`, stream `host:<host>`). One session per
/// followed host (the app passes leases on the Mac's shared socket), ended
/// when the host leaves the set or the stream ends.
public struct ControlPlaneHostPresence: HostPresenceSource {
    private let makeClient: @Sendable (_ host: String, _ team: String) async -> any ControlPlaneSession

    /// - Parameter makeClient: the host socket session (the app injects URL, token and transport, or a pool lease).
    public init(makeClient: @escaping @Sendable (_ host: String, _ team: String) async -> any ControlPlaneSession) {
        self.makeClient = makeClient
    }

    public func presence(of hosts: [String: String]) async -> AsyncStream<[String: HostPresence]> {
        let makeClient = self.makeClient
        return AsyncStream { sink in
            let task = Task {
                let collected = HostPresenceMap()
                await withTaskGroup(of: Void.self) { group in
                    for (host, team) in hosts {
                        group.addTask {
                            let client = await makeClient(host, team)
                            await client.start()
                            for await update in await client.subscribe("host:\(host)") {
                                if let p = Self.presence(update) { sink.yield(await collected.set(host, p)) }
                            }
                            await client.stop()
                        }
                    }
                }
                sink.finish()
            }
            sink.onTermination = { _ in task.cancel() }
        }
    }

    static func presence(_ update: StreamUpdate) -> HostPresence? {
        let (value, at): (JSONValue?, Int64?) = switch update {
        case .snapshot(let s): (s.state["presence"], s.state["at"].flatMap(Self.int))
        case .event(let e) where e.op == "host.presence.set": (e.params["presence"], e.at)
        case .event: (nil, nil)
        }
        guard let raw = value?.stringValue, let state = HostPresence.State(rawValue: raw) else { return nil }
        return HostPresence(state: state, at: Date(timeIntervalSince1970: TimeInterval(at ?? 0) / 1000))
    }

    private static func int(_ v: JSONValue) -> Int64? {
        if case .int(let i) = v { return i }
        return nil
    }
}

/// The latest presence per host for one `presence(of:)` stream.
actor HostPresenceMap {
    private var map: [String: HostPresence] = [:]

    func set(_ host: String, _ presence: HostPresence) -> [String: HostPresence] {
        map[host] = presence
        return map
    }
}
