import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SessionSnapshotImportTrustTests {
    /// A crafted file could otherwise pin its own workspaces' ordering and effort inputs.
    @Test("a file import drops session priority state")
    func fileImportDropsSessionPriorityState() throws {
        var original = Self.snapshot(terminal: Self.untrustedTerminal())
        original.windows[0].tabManager.workspaces[0].claudeDifficultyOverride = "hard"
        original.windows[0].tabManager.workspaces[0].claudeDifficultyAuto = "easy"
        original.windows[0].tabManager.workspaces[0].sessionPriorityManual = true
        original.windows[0].tabManager.workspaces[0].sessionPriorityIndex = 2

        let (fileRestored, report) = SessionSnapshotImportTrust.snapshotForRestore(original, source: Self.fileImport)
        let (channelRestored, channelReport) = SessionSnapshotImportTrust.snapshotForRestore(
            original, source: Self.channelImport
        )

        let file = try #require(fileRestored.windows.first?.tabManager.workspaces.first)
        #expect(file.claudeDifficultyOverride == nil)
        #expect(file.claudeDifficultyAuto == nil)
        #expect(file.sessionPriorityManual == nil)
        #expect(file.sessionPriorityIndex == nil)
        #expect(report.droppedSessionPriorityStateCount == 1)
        let channel = try #require(channelRestored.windows.first?.tabManager.workspaces.first)
        #expect(channel.claudeDifficultyOverride == "hard")
        #expect(channel.claudeDifficultyAuto == "easy")
        #expect(channel.sessionPriorityManual == true)
        #expect(channel.sessionPriorityIndex == 2)
        #expect(channelReport.droppedSessionPriorityStateCount == 0)
    }
}
