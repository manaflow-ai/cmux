import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Ports/Desktop open path decides its route from the machine alone: a
/// private address always means the user-space hub, never the Network
/// Extension, on every build.
@Suite
struct CloudPortRoutePlanTests {
    private let machine = SurfaceMachineID.cloud("vm-1")

    @Test("a port on a machine with a private address forwards through the hub")
    func portForwardsThroughHub() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000, directURL: "http://10.0.0.7:3000")
        let plan = CloudPortRoutePlan.plan(resource: resource, privateAddress: "10.0.0.7", supportsControlPlanePreviews: true)
        #expect(plan == .hubForward(target: CloudPortForwardTarget(host: "10.0.0.7", port: 3000), remoteURL: "http://10.0.0.7:3000"))
    }

    @Test("the route does not depend on the tunnel backend: an unentitled build plans the same forward")
    func independentOfNetworkExtension() {
        let backend = CloudTunnelBackendSelector(
            networkExtensionCapabilities: { [] },
            canInstallSystemExtensions: { false },
            bundledExtensionIdentifier: { nil }
        ).select()
        #expect(backend == .unavailable(.entitlementMissing))
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 8080)
        let plan = CloudPortRoutePlan.plan(resource: resource, privateAddress: "10.0.0.7", supportsControlPlanePreviews: false)
        #expect(plan == .hubForward(target: CloudPortForwardTarget(host: "10.0.0.7", port: 8080), remoteURL: "http://10.0.0.7:8080"))
    }

    @Test("the desktop keeps its noVNC path and query on the forward")
    func desktopKeepsQuery() throws {
        let resource = CmuxTuiSnapshotParser.display(machine: machine, directURL: CmuxTuiSurfaceProvider.privateDesktopURL(privateAddress: "10.0.0.7"))
        let plan = CloudPortRoutePlan.plan(resource: resource, privateAddress: "10.0.0.7", supportsControlPlanePreviews: true)
        guard case .hubForward(let target, let remoteURL) = plan else {
            Issue.record("expected a hub forward, got \(plan)")
            return
        }
        #expect(target == CloudPortForwardTarget(host: "10.0.0.7", port: CmuxTuiSnapshotParser.desktopPort))
        let local = try #require(CloudPortRoutePlan.localURL(rewriting: remoteURL, toLoopbackPort: 54_321))
        #expect(local.host() == "127.0.0.1")
        #expect(local.port == 54_321)
        #expect(local.path() == "/vnc.html")
        #expect(local.query()?.contains("autoconnect=1") == true)
    }

    @Test("a stale private URL is rewritten onto the loopback listener host and port")
    func rewriteReplacesHostAndPort() throws {
        let local = try #require(CloudPortRoutePlan.localURL(rewriting: "http://[fd60:1e5e:6720::3]:3000/app?x=1#frag", toLoopbackPort: 40_000))
        #expect(local.absoluteString == "http://127.0.0.1:40000/app?x=1#frag")
    }

    @Test("forwarded pages reject non-web schemes", arguments: [
        "javascript:alert(1)", "file:///etc/passwd", "custom://machine/action"
    ])
    func rejectsNonWebURLs(_ remoteURL: String) {
        #expect(CloudPortRoutePlan.localURL(rewriting: remoteURL, toLoopbackPort: 40_000) == nil)
    }

    @Test("an https private URL is never rewritten onto the raw TCP loopback forward")
    func httpsIsRejected() {
        #expect(CloudPortRoutePlan.localURL(rewriting: "https://10.0.0.7:8443/", toLoopbackPort: 40_001) == nil)
        #expect(CloudPortRoutePlan.localURL(rewriting: "http://10.0.0.7:8080/", toLoopbackPort: 40_001)?.absoluteString == "http://127.0.0.1:40001/")
    }

    @Test("no private address but a preview capability asks the control plane")
    func controlPlaneFallback() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000)
        #expect(CloudPortRoutePlan.plan(resource: resource, privateAddress: nil, supportsControlPlanePreviews: true) == .controlPlanePreview(port: 3000))
        #expect(CloudPortRoutePlan.plan(resource: resource, privateAddress: " ", supportsControlPlanePreviews: true) == .controlPlanePreview(port: 3000))
    }

    @Test("neither an address nor a preview capability is a named refusal, not a silent failure")
    func unsupportedNamesTheMachine() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: 3000)
        guard case .unsupported(let reason) = CloudPortRoutePlan.plan(resource: resource, privateAddress: nil, supportsControlPlanePreviews: false) else {
            Issue.record("expected unsupported")
            return
        }
        #expect(reason.contains("vm-1"))
    }
}
