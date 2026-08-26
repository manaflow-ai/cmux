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
    @Test("The same terminal session exposes its report until panel invalidation")
    func sameSessionRequiresActivePanelLifecycle() {
        let identity = TerminalTTYSessionIdentity(
            processIdentity: AgentPIDProcessIdentity(pid: 8362, startSeconds: 1, startMicroseconds: 0)
        )
        let scanner = PortScanner(ttySessionIdentityProvider: { _ in identity })
        let workspaceID = UUID()
        let panelID = UUID()

        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == nil)

        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "/dev/ttys8362")
        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == "/dev/ttys8362")

        scanner.unregisterPanel(workspaceId: workspaceID, panelId: panelID)
        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == nil)
    }

    @Test("A reused PTY name with a different terminal session is rejected")
    func reusedTerminalSessionIsRejected() {
        let original = TerminalTTYSessionIdentity(
            processIdentity: AgentPIDProcessIdentity(pid: 8362, startSeconds: 1, startMicroseconds: 0)
        )
        let reused = TerminalTTYSessionIdentity(
            processIdentity: AgentPIDProcessIdentity(pid: 8362, startSeconds: 2, startMicroseconds: 0)
        )
        var identities: [TerminalTTYSessionIdentity?] = [original, reused]
        let scanner = PortScanner(ttySessionIdentityProvider: { _ in identities.removeFirst() })
        let workspaceID = UUID()
        let panelID = UUID()

        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "/dev/ttys8362")

        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == nil)
    }

    @Test("An exited terminal session is rejected")
    func exitedTerminalSessionIsRejected() {
        let original = TerminalTTYSessionIdentity(
            processIdentity: AgentPIDProcessIdentity(pid: 8362, startSeconds: 1, startMicroseconds: 0)
        )
        var identities: [TerminalTTYSessionIdentity?] = [original, nil]
        let scanner = PortScanner(ttySessionIdentityProvider: { _ in identities.removeFirst() })
        let workspaceID = UUID()
        let panelID = UUID()

        scanner.registerTTY(workspaceId: workspaceID, panelId: panelID, ttyName: "/dev/ttys8362")

        #expect(scanner.freshReportedTTYName(workspaceId: workspaceID, panelId: panelID) == nil)
    }
}
