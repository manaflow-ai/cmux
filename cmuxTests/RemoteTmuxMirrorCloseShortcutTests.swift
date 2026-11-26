import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct RemoteTmuxMirrorCloseShortcutTests {
    @Test(arguments: [true, false], [true, false])
    func closeTargetsOnePaneAndRespectsCancellation(explicitPane: Bool, accept: Bool) throws {
        let harness = try RemoteTmuxMirrorCLIObservabilityTests.Harness(connectedTransport: true)
        defer { harness.tearDown() }
        let manager = try #require(harness.appDelegate.tabManagerFor(windowId: harness.windowID))
        let surface = try #require(harness.mirror.panel(forPane: 11)?.id)
        var confirmations = 0
        manager.confirmCloseHandler = { _, _, _ in
            confirmations += 1
            return accept
        }
        defer { manager.confirmCloseHandler = nil }

        if explicitPane {
            manager.closePanelWithConfirmation(tabId: harness.workspace.id, surfaceId: surface)
        } else {
            manager.closeCurrentPanelWithConfirmation()
        }

        #expect(confirmations == 1)
        #expect(harness.workspace.panels[harness.outerPanelID] != nil)
        let writer = try #require(harness.controlWriter)
        let pipe = try #require(harness.controlPipe)
        writer.close()
        let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let commands = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map(String.init).filter { $0.hasPrefix("kill-") }
        let pane = explicitPane ? 11 : 22
        #expect(commands == (accept ? ["kill-pane -t @3.%\(pane)"] : []))
    }
}
