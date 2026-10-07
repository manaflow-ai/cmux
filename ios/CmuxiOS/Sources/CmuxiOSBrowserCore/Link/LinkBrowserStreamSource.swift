import CmuxBrowserStream
import CmuxMobileLink
public import CmuxiOSFeatureKit
import Foundation

/// The real `BrowserStreamSource` (lane C2): tab records from the host's
/// workspace mirror, streams over the phone's one `MobileLinkClient` per
/// Mac (shared with terminals and files). The screen sends its real viewport after layout; `viewport`
/// is only the first guess for `channel.open`.
public struct LinkBrowserStreamSource: BrowserStreamSource {
    public let clients: any MobileLinkClientProvider
    public let directory: any BrowserTabDirectory
    public let viewport: @Sendable () -> BrowserViewport

    public init(clients: any MobileLinkClientProvider, directory: any BrowserTabDirectory,
                viewport: @escaping @Sendable () -> BrowserViewport) {
        self.clients = clients
        self.directory = directory
        self.viewport = viewport
    }

    public func tabs(on hostID: HostID) async -> AsyncStream<SourceSnapshot<[BrowserTabInfo]>> {
        await directory.tabs(on: hostID)
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
                                  scale: min(max(viewport.scale, 0.5), 4), refreshHz: UInt32(max(1, viewport.refreshHz)))
        let client = BrowserStreamClient(client: link, params: BrowserChannelParams(tab: tabID, screen: screen))
        do {
            let opened = try await client.open()
            let stream = LinkBrowserStreamSession(tabID: tabID, client: client, opened: opened)
            await stream.start()
            return stream
        } catch BrowserStreamClientError.refused(let code, _) where code == "browser.tab_not_found" {
            throw FeatureSourceError.notFound(tabID)
        } catch BrowserStreamClientError.refused(let code, _) {
            throw FeatureSourceError.unsupported(code)
        } catch {
            throw FeatureSourceError.offline
        }
    }
}
