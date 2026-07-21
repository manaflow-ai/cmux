import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Port scanner TTY freshness")
struct PortScannerTTYFreshnessTests {
    @Test("Only a live registration exposes a reported TTY, and invalidation removes it")
    func requiresActivePanelLifecycle() {
        let scanner = PortScanner()
        let workspaceID = UUID()
        let panelID = UUID()

        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == nil)

        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "/dev/ttys8362")
        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == "/dev/ttys8362")

        scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == nil)
    }
}
