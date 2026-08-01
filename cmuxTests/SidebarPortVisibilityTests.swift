import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar port visibility", .serialized)
struct SidebarPortVisibilityTests {
    @Test("Default policy excludes the OS ephemeral range without discarding observations")
    func defaultPolicyExcludesEphemeralRangeWithoutDiscardingObservations() throws {
        let defaults = UserDefaults.standard
        let ignoredPortsKey = "sidebarIgnoredPorts"
        let previousValue = defaults.object(forKey: ignoredPortsKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: ignoredPortsKey)
            } else {
                defaults.removeObject(forKey: ignoredPortsKey)
            }
        }
        defaults.removeObject(forKey: ignoredPortsKey)

        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let panelPorts = [49_151, 49_152, 65_535]
        let agentPorts = [3_000, 63_315]

        workspace.surfaceListeningPorts[panelID] = panelPorts
        workspace.agentListeningPorts = agentPorts
        workspace.recomputeListeningPorts()

        #expect(workspace.surfaceListeningPorts[panelID] == panelPorts)
        #expect(workspace.agentListeningPorts == agentPorts)
        #expect(workspace.listeningPorts == [3_000, 49_151])
    }
}
