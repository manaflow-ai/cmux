import CmuxBrowserStream
import CmuxMobileLink
import CmuxMobileWire
public import CmuxiOSFeatureKit
import Foundation

/// Simulator streaming as a `BrowserStreamSource` (lane C14, c14-web.md 6):
/// the "tabs" are the Mac's booted simulators (`simulator.list`), and `open`
/// attaches a `simulator` channel on C2's rd path, so the same session and
/// screen render it.
public struct LinkSimulatorStreamSource: BrowserStreamSource {
    public let clients: any MobileLinkClientProvider
    public let viewport: @Sendable () -> BrowserViewport

    public init(clients: any MobileLinkClientProvider, viewport: @escaping @Sendable () -> BrowserViewport) {
        self.clients = clients
        self.viewport = viewport
    }

    /// One snapshot of the booted simulators (the list is read on demand;
    /// subscribe again to refresh).
    public func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>> {
        let clients = clients
        return AsyncStream { continuation in
            let task = Task {
                do {
                    let client = try await clients.client(for: hostID)
                    let value = try await client.read("simulator.list", params: .object([:]))
                    let list = try value.decode(as: SimulatorListResult.self).simulators.filter { $0.state == .booted }
                    let tabs = list.map { BrowserTabInfo(id: $0.udid, workspaceID: nil, title: "\($0.name) (\($0.runtime))", url: nil) }
                    continuation.yield(SourceSnapshot(revision: 1, value: tabs, connection: .live(path: "link")))
                } catch {
                    continuation.yield(SourceSnapshot(revision: 0, value: [], connection: .offline(reason: nil)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func open(_ tabID: BrowserTabInfo.ID, on hostID: HostID) async throws -> any BrowserStreamSession {
        let link: MobileLinkClient
        do {
            link = try await clients.client(for: hostID)
        } catch {
            throw FeatureSourceError.offline
        }
        let viewport = viewport()
        let screen = RbScreenInfo(cssWidth: UInt32(max(1, viewport.width)), cssHeight: UInt32(max(1, viewport.height)),
                                  scale: min(max(viewport.scale, 0.5), 4), refreshHz: UInt32(max(1, min(viewport.refreshHz, 60))))
        let client = BrowserStreamClient(client: link, params: BrowserChannelParams(simulator: tabID, screen: screen))
        do {
            let opened = try await client.open()
            let stream = LinkBrowserStreamSession(tabID: tabID, client: client, opened: opened)
            await stream.start()
            return stream
        } catch BrowserStreamClientError.refused(let code, _) where code == "simulator.not_found" {
            throw FeatureSourceError.notFound(tabID)
        } catch BrowserStreamClientError.refused(let code, _) {
            throw FeatureSourceError.unsupported(code)
        } catch {
            throw FeatureSourceError.offline
        }
    }
}
