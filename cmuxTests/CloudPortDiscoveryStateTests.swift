import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud port discovery state")
struct CloudPortDiscoveryStateTests {
    private let now = Date(timeIntervalSince1970: 100)

    @Test("The authenticated browser route discovers loopback and wildcard services")
    func scanMatchesBrowserProxy() throws {
        let scan = try #require(CmuxTuiSurfaceProvider.portScan(from: VMExecResult(exitCode: 0, stdout: """
        LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*
        LISTEN 0 128 0.0.0.0:8000 0.0.0.0:*
        LISTEN 0 128 10.0.0.7:9000 0.0.0.0:*
        LISTEN 0 128 [::1]:9100 [::]:*
        LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
        """, stderr: ""), privateAddress: "10.0.0.7"))
        #expect(scan.ports == [3000, 8000])
        #expect(scan.loopbackOnlyPorts == [3000])
        #expect(scan.otherBindingPorts == [9000, 9100])
        #expect(scan.state == .available)
        let loopback = try #require(CloudPortScanResult(socketListing: "LISTEN 0 128 127.0.0.1:3000 0.0.0.0:*"))
        #expect(loopback.state == .loopbackOnly)
    }

    @Test("An empty successful scan, other-interface listeners, and an invalid scan differ")
    func noServiceAndUnavailableAreDifferent() throws {
        #expect(CloudPortScanResult(socketListing: "")?.state == .empty(.noListeningService))
        #expect(CloudPortScanResult(socketListing: "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n")?.ports == [])
        #expect(CloudPortScanResult(socketListing: "LISTEN 0 128 10.0.0.7:3000 0.0.0.0:*")?.state == .empty(.otherInterfaceOnly))
        #expect(CloudPortScanResult(socketListing: "inventory unavailable") == nil)
        #expect(CmuxTuiSurfaceProvider.portScan(from: VMExecResult(exitCode: 127, stdout: "", stderr: "missing")) == nil)
    }

    @Test("No scan runs without demand; first demand publishes loading before a result")
    func demandAndCompletion() {
        var discovery = readyDiscovery()
        #expect(discovery.state == .notRequested && !discovery.mayScan)
        discovery.request()
        #expect(discovery.state == .loading && discovery.mayScan)
        let request = discovery.beginScan()
        let completed = discovery.complete(CloudPortScanResult(ports: [3000]), request: request, at: now, socketPath: "first")
        #expect(completed)
        #expect(discovery.state == .available)
        let failed = discovery.beginScan()
        let failedCompletion = discovery.complete(nil, request: failed, at: now, socketPath: "first")
        #expect(failedCompletion)
        #expect(discovery.state == .stale && discovery.scan?.ports == [3000])
        let retry = discovery.beginScan()
        let emptyCompletion = discovery.complete(CloudPortScanResult(ports: []), request: retry, at: now, socketPath: "first")
        #expect(emptyCompletion)
        #expect(discovery.state == .empty(.noListeningService) && discovery.scan?.ports == [])
    }

    @Test("A rescan keeps the settled inventory visible and survives a routine summary poll")
    func rescanKeepsSettledState() {
        var discovery = readyDiscovery()
        discovery.request()
        let first = discovery.beginScan()
        _ = discovery.complete(CloudPortScanResult(ports: [3000]), request: first, at: now, socketPath: "first")
        let rescan = discovery.beginScan()
        #expect(discovery.state == .available)
        discovery.reconcile(supportsPreviews: true, isAwake: true, privateAddress: "10.0.0.7")
        let completed = discovery.complete(CloudPortScanResult(ports: [3000, 8000]), request: rescan, at: now, socketPath: "first")
        #expect(completed)
        #expect(discovery.state == .available && discovery.scan?.ports == [3000, 8000])
    }

    @Test("A fresh cached scan settles a repeated request instead of leaving it loading")
    func cachedScanSettlesRequest() {
        var discovery = readyDiscovery()
        discovery.request()
        let request = discovery.beginScan()
        _ = discovery.complete(CloudPortScanResult(ports: [3000]), request: request, at: now, socketPath: "first")
        discovery.request()
        #expect(discovery.state == .loading)
        #expect(discovery.cachedScan(at: now.addingTimeInterval(5), socketPath: "first", force: false)?.ports == [3000])
        #expect(discovery.state == .available)
    }

    @Test("Capabilities and private-route prerequisites outrank link errors")
    func blockerMatrix() {
        var discovery = CloudPortDiscovery()
        discovery.reconcile(supportsPreviews: false, isAwake: false, privateAddress: nil)
        discovery.request()
        discovery.linkFailed()
        #expect(discovery.state == .unsupported && !discovery.mayScan)
        discovery.reconcile(supportsPreviews: true, isAwake: true, privateAddress: nil)
        discovery.linkFailed()
        #expect(discovery.state == .unavailable(.privateAddress))
        discovery.reconcile(supportsPreviews: true, isAwake: true, privateAddress: "10.0.0.7")
        #expect(discovery.mayScan)
        discovery.reconcile(supportsPreviews: true, isAwake: false, privateAddress: "10.0.0.7")
        #expect(discovery.state == .unavailable(.machineAsleep) && !discovery.mayScan)
    }

    @Test("Address withdrawal and retirement reject stale results")
    func staleScanCannotPublish() {
        var discovery = readyDiscovery()
        discovery.request()
        let stale = discovery.beginScan()
        discovery.reconcile(supportsPreviews: true, isAwake: true, privateAddress: nil)
        let staleCompletion = discovery.complete(CloudPortScanResult(ports: [3000]), request: stale, at: now, socketPath: "old")
        #expect(!staleCompletion)
        #expect(discovery.state == .unavailable(.privateAddress) && discovery.scan == nil)
        discovery.reconcile(supportsPreviews: true, isAwake: true, privateAddress: "10.0.0.8")
        let retired = discovery.beginScan()
        discovery.invalidate()
        let retiredCompletion = discovery.complete(CloudPortScanResult(ports: [8000]), request: retired, at: now, socketPath: "new")
        #expect(!retiredCompletion)
    }

    @Test("A cache is scoped to its link and does not renew itself on reads")
    func cacheScope() {
        var discovery = readyDiscovery()
        discovery.request()
        let request = discovery.beginScan()
        _ = discovery.complete(CloudPortScanResult(ports: [3000]), request: request, at: now, socketPath: "first")
        let cached = discovery.cachedScan(at: now.addingTimeInterval(20), socketPath: "first", force: false)
        #expect(cached?.ports == [3000])
        let expired = discovery.cachedScan(at: now.addingTimeInterval(31), socketPath: "first", force: false)
        #expect(expired == nil)
        let otherSocket = discovery.cachedScan(at: now, socketPath: "second", force: false)
        #expect(otherSocket == nil)
        let forced = discovery.cachedScan(at: now, socketPath: "first", force: true)
        #expect(forced == nil)
    }

    @Test("Unavailable scans never retain resources belonging to another machine")
    func foreignPortsAreRejected() {
        let owner = SurfaceMachineID.cloud("owner")
        let foreign = CmuxTuiSnapshotParser.portBrowser(machine: .cloud("other"), port: 3000)
        #expect(CmuxTuiSurfaceProvider.portResources(machine: owner, scannedPorts: nil,
            previousResources: [foreign], privateAddress: "10.0.0.7").isEmpty)
    }

    @Test("The socket exporter carries the same authoritative Ports reason")
    @MainActor
    func socketExportsReason() {
        let states: [CloudPortDiscoveryState] = [.notRequested, .loading, .available, .loopbackOnly,
            .empty(.noListeningService), .unavailable(.privateAddress), .unavailable(.transport), .stale, .unsupported]
        for state in states {
            let info = CmuxTuiSurfaceProvider.info(
                from: VMSummary(id: "port-owner", provider: "freestyle", status: "running", image: "base", createdAt: 0, base: nil),
                linkState: .connected, linkError: nil, stats: nil, portDiscoveryState: state)
            let payload = TerminalController.surfaceMachinePayload(info)
            #expect(payload["id"] as? String == "port-owner")
            #expect(payload["port_discovery_state"] as? String == state.wireValue)
        }
    }

    private func readyDiscovery() -> CloudPortDiscovery {
        var discovery = CloudPortDiscovery()
        discovery.reconcile(supportsPreviews: true, isAwake: true, privateAddress: "10.0.0.7")
        return discovery
    }
}
