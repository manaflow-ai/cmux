import CmuxCloud
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real outline/catalog/provider/WebKit path with a task-owned authenticated peer.
/// Only endpoint acquisition and the guest page are substituted.
@MainActor
final class CloudDesktopNavigationFixture {
    enum EntryPoint: CaseIterable {
        case click, menu, drop
    }

    let app: CloudDesktopOpenFixture
    let server: CloudBrowserProxyTestServer
    let store = CloudPortAccessStore()
    let readiness = CloudLinkFirstValue<CloudBrowserProxyEndpoint>()
    let provider: CmuxTuiSurfaceProvider
    let model: CloudPortAccessModel

    init(machineID: String = "desktop-navigation-\(UUID().uuidString)") throws {
        let address = "10.16.0.70"
        app = try CloudDesktopOpenFixture(ownerID: machineID)
        server = try CloudBrowserProxyTestServer(
            address: address, marker: "desktop-navigation", servicePort: 6901,
            pageHTML: """
                <!doctype html><html><head><title>Desktop navigation fixture</title></head>
                <body><div id="noVNC_status"></div><div id="noVNC_container"></div>
                <script>
                window.fixtureSocket = new WebSocket('ws://' + location.host + '/websockify');
                window.fixtureSocket.onopen = () => document.documentElement.classList.add('noVNC_connected');
                </script></body></html>
                """
        )
        let gate = readiness
        model = store.model(machineID: machineID, target: .init(host: address, port: 6901)) {
            CloudPortAccessModel(
                target: .init(host: address, port: 6901), coordinator: nil,
                wake: {},
                startForward: { _ in
                    Issue.record("Desktop navigation must use its authenticated browser proxy")
                    throw CancellationError()
                },
                stopForward: {},
                startBrowserProxy: {
                    guard let endpoint = await gate.result else { throw CancellationError() }
                    return endpoint
                }
            )
        }
        var summary = VMSummary(id: machineID, provider: "freestyle", status: "running",
            image: "cmux-devbox", createdAt: 0, base: nil)
        summary.kind = .desktop
        summary.addressIPv4 = address
        provider = CmuxTuiSurfaceProvider(
            summary: summary,
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            catalog: app.catalog, portAccessStore: store,
            browserPolicy: { .init(managedPatterns: nil) }
        )
        app.catalog.unregister(machine: app.provider.machine)
        app.catalog.register(provider)
        var info = provider.info
        info.remoteWorkspaces = [app.remote]
        app.catalog.replaceResources([app.display], on: provider.machine, info: info)
    }

    var documentRequests: Int {
        server.requests.filter { $0.method == "GET" && $0.target.hasPrefix("/vnc.html") }.count
    }

    func start() async throws {
        try await server.start()
    }

    func releaseRoute() { readiness.resolve(server.endpoint) }

    func open(_ entryPoint: EntryPoint = .click) async throws -> BrowserPanel {
        if entryPoint == .drop {
            try await app.drop(try app.poolNode(), into: app.owner)
        } else {
            try app.activate(try app.poolNode(), menu: entryPoint == .menu)
            await app.waitForOpen()
        }
        try #require(app.failures.isEmpty)
        let projection = try #require(app.catalog.projections(of: app.display.id).first)
        return try #require(SurfacePaneFactory.browserPanel(
            panelID: projection.panelID, in: projection.workspaceID
        ))
    }

    func waitForDocument(_ panel: BrowserPanel) async -> Bool {
        await AppKitTestEventPump().waitUntil(timeout: .seconds(8)) {
            self.documentRequests > 0 && panel.cloudAccess.desktopConnected
        }
    }

    func close() async {
        app.close()
        readiness.resolve(nil)
        await provider.stop()
        server.stop()
    }
}
