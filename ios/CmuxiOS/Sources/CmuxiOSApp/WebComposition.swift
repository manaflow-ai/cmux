import CmuxiOSBrowser
import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import CmuxiOSSSH
import CmuxiOSWeb

/// Lane C14 plug point (c14-web.md): the tunnel browser and simulator
/// streaming need the phone's `MobileLinkClient` per Mac (D1, the same
/// provider C2 and C4 wait for). Until it exists Mac routes report "No
/// connection to this machine"; SSH routes work through C9's connections.
@MainActor
enum WebComposition {
    static func feature(clients: (any MobileLinkClientProvider)?) -> WebFeature {
        let simulators = clients.map {
            BrowserFeature(source: LinkSimulatorStreamSource(clients: $0, viewport: { BrowserComposition.initialViewport }),
                           isMock: false)
        }
        return WebFeature(clients: clients, simulators: simulators)
    }

    static func screens(_ web: WebFeature) -> SSHBrowserScreens {
        SSHBrowserScreens(mac: { host, name in web.makeMacScreen(host: host, name: name) },
                          ssh: { host, name, opener in web.makeSSHScreen(host: host, name: name, opener: opener) })
    }
}
