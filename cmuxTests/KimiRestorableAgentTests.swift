import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Kimi restorable agent")
struct KimiRestorableAgentTests {
    @Test("Kimi is a first-class codable restorable kind")
    func firstClassKindRoundTrip() throws {
        let kind = try #require(RestorableAgentKind(rawValue: "kimi"))

        #expect(RestorableAgentKind.allCases.contains(kind))
        #expect(kind.rawValue == "kimi")
        #expect(kind.displayName == "Kimi Code")
        #expect(kind.restoreMode == .resumeSession)
        #expect(kind.cwdNamespacing == .byDirectory)

        let encoded = try JSONEncoder().encode(kind)
        #expect(String(decoding: encoded, as: UTF8.self) == #""kimi""#)
        #expect(try JSONDecoder().decode(RestorableAgentKind.self, from: encoded) == kind)
    }

    @Test("Kimi hook sessions are discovered and produce a resume command")
    func hookSessionLoadsIntoResumePipeline() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-kimi-restore-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let workspaceID = UUID()
        let panelID = UUID()
        let sessionID = "72124c21-7b09-40a1-a98f-718164c46431"
        let stateDirectory = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let store = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    sessionID: [
                        "sessionId": sessionID,
                        "workspaceId": workspaceID.uuidString,
                        "surfaceId": panelID.uuidString,
                        "cwd": workingDirectory.path,
                        "isRestorable": true,
                        "updatedAt": Date.now.timeIntervalSince1970,
                    ],
                ],
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try store.write(
            to: stateDirectory.appendingPathComponent("kimi-hook-sessions.json", isDirectory: false),
            options: .atomic
        )

        let snapshot = try #require(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fileManager)
                .snapshot(workspaceId: workspaceID, panelId: panelID)
        )
        #expect(snapshot.kind.rawValue == "kimi")
        #expect(snapshot.sessionId == sessionID)
        #expect(snapshot.workingDirectory == workingDirectory.path)

        let resumeCommand = try #require(snapshot.resumeCommand)
        #expect(resumeCommand.contains("'kimi' '--resume' '\(sessionID)'"))
        #expect(resumeCommand.hasPrefix("cd -- '\(workingDirectory.path)'"))
    }
}
