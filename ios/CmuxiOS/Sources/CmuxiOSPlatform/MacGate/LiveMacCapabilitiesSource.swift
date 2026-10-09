import CmuxMobileLink
import CmuxMobileWire
import CmuxiOSFeatureKit
import Foundation

/// Reads the authenticated Mac status over the same `MobileLinkClient` used
/// by terminals and file transfer. Discovery records only identify a Mac; the
/// host status response is the owner of its protocol and capability claims.
public actor LiveMacCapabilitiesSource: MacCapabilitiesSource {
    public typealias ClientLookup = @Sendable (HostID) async -> MobileLinkClient?

    private let registry: any DeviceRegistry
    private let client: ClientLookup
    private let fallbackName: @Sendable (HostID) -> String?

    public init(registry: any DeviceRegistry, client: @escaping ClientLookup,
                fallbackName: @escaping @Sendable (HostID) -> String? = { _ in nil }) {
        self.registry = registry
        self.client = client
        self.fallbackName = fallbackName
    }

    /// One coalesced capability snapshot per registry update. Host queries run
    /// concurrently so one sleeping Mac cannot delay the others.
    public func updates() async -> AsyncStream<SourceSnapshot<[HostID: MacCapabilities]>> {
        let registryUpdates = await registry.updates()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<[HostID: MacCapabilities]>.self,
            bufferingPolicy: .bufferingNewest(1))
        let task = Task { [client, fallbackName] in
            for await snapshot in registryUpdates {
                guard !Task.isCancelled else { return }
                let hosts = Self.macHosts(snapshot.value)
                let values = await withTaskGroup(of: (HostID, MacCapabilities?).self,
                                                  returning: [HostID: MacCapabilities].self) { group in
                    for (host, name) in hosts {
                        group.addTask {
                            guard let link = await client(host) else { return (host, nil) }
                            do {
                                let hello = try await link.helloOK()
                                let status = try? await link.read("mobile.host.status", params: .object([:]))
                                let value = MacCapabilitiesProjection.decode(
                                    host: host, fallbackName: name ?? fallbackName(host), hello: hello, status: status)
                                return (host, value)
                            } catch {
                                return (host, nil)
                            }
                        }
                    }
                    var result: [HostID: MacCapabilities] = [:]
                    for await (host, value) in group {
                        if let value { result[host] = value }
                    }
                    return result
                }
                continuation.yield(SourceSnapshot(revision: snapshot.revision, value: values,
                                                   connection: snapshot.connection))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func macHosts(_ records: [DeviceRecord]) -> [(HostID, String?)] {
        records.compactMap { record in
            guard record.platform == .mac, record.trust == .trusted, !record.isThisDevice,
                  let host = record.hostID else { return nil }
            return (HostID(host), record.name)
        }
    }
}

/// Pure status decoder kept separate from transport orchestration so the
/// compatibility rules remain testable without constructing a WebRTC link.
public enum MacCapabilitiesProjection {
    public static func decode(host: HostID, fallbackName: String?, hello: HelloOKFrame,
                              status: JSONValue?) -> MacCapabilities {
        let statusName = status?["mac_display_name"]?.stringValue
        let name = (statusName?.isEmpty == false ? statusName : nil) ?? fallbackName ?? host.rawValue
        let version = status?["mac_app_version"]?.stringValue ?? "0"
        let caps = Set(status?["capabilities"]?.strings ?? hello.caps)
        let protocolVersion = status?["protocol_version"]?.intValue.map(Int.init) ?? hello.version
        return MacCapabilities(host: host, name: name, appVersion: version,
                               protocolVersion: protocolVersion, capabilities: caps)
    }
}

private extension JSONValue {
    var strings: [String] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap(\.stringValue)
    }

    var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }
}
