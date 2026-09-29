import CmuxCloud
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct DeviceDiscoverabilityGatingTests {
    @Test("Cloud/Beta gating keeps both bottom actions present but disabled")
    func unavailableDevicesKeepGatedControls() throws {
        let section = CloudTreeDevicesSection(
            discoveryEnabled: true, incomingAccessEnabled: true, available: false
        )
        #expect(section.inlineRowCount == 2)
        #expect(!section.discoveryControl.isEnabled)
        #expect(!section.incomingControl.isEnabled)
        #expect(section.discoveryControl.title == "Discover other Macs")
        #expect(section.incomingControl.title == "Make this Mac discoverable")
        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [], snapshot: .empty, localWorkspaces: [], includeLocalMachine: false,
            source: .cloudWithDevicesSection, devicesSection: section
        )
        let devices = try #require(nodes.first { $0.id == CloudTreeNodeBuilder.devicesSectionNodeID })
        guard case .devicesEmpty(let controls) = try #require(devices.children.first).kind else {
            Issue.record("Expected gated My Devices controls")
            return
        }
        #expect(controls == section)
    }
}
