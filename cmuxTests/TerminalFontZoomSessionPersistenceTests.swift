import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal font zoom session persistence")
struct TerminalFontZoomSessionPersistenceTests {
    @Test("restored terminal zoom survives the next session capture")
    func restoredZoomSurvivesRecapture() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let zoomedSnapshot = try snapshotBySettingTerminalFontSize(
            5.5,
            panelID: panelID,
            in: snapshot
        )
        let restoredWorkspace = Workspace()
        let restoredPanelIDs = restoredWorkspace.restoreSessionSnapshot(zoomedSnapshot)
        let restoredPanelID = restoredPanelIDs[panelID] ?? panelID

        let recapturedSnapshot = restoredWorkspace.sessionSnapshot(includeScrollback: false)
        let recapturedFontSize = try terminalFontSize(
            panelID: restoredPanelID,
            in: recapturedSnapshot
        )

        #expect(recapturedFontSize == 5.5)
    }

    private func snapshotBySettingTerminalFontSize(
        _ fontSize: Double,
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> SessionWorkspaceSnapshot {
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        var panels = try #require(object["panels"] as? [[String: Any]])
        let panelIndex = try #require(panels.firstIndex { $0["id"] as? String == panelID.uuidString })
        var terminal = try #require(panels[panelIndex]["terminal"] as? [String: Any])
        terminal["fontSize"] = fontSize
        panels[panelIndex]["terminal"] = terminal
        object["panels"] = panels

        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
    }

    private func terminalFontSize(
        panelID: UUID,
        in snapshot: SessionWorkspaceSnapshot
    ) throws -> Double {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        let panels = try #require(object["panels"] as? [[String: Any]])
        let panel = try #require(panels.first { $0["id"] as? String == panelID.uuidString })
        let terminal = try #require(panel["terminal"] as? [String: Any])
        return try #require(terminal["fontSize"] as? Double)
    }
}
