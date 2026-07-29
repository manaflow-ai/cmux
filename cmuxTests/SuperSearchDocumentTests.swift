import XCTest
import CmuxAgentChat
import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SuperSearchDocumentTests: XCTestCase {
    func testMetadataDocumentContainsTitleCwdBranchPR() {
        let workspaceID = UUID()
        let document = GlobalSearchDocuments.workspaceMetadataDocument(
            windowID: UUID(),
            workspaceID: workspaceID,
            workspaceTitle: "Infra Workspace",
            location: "Window > Infra Workspace",
            snapshot: GlobalSearchWorkspaceMetadataSnapshot(
                currentDirectory: "/Users/test/repo",
                workspaceGitBranch: SidebarGitBranchState(branch: "feature/super-search", isDirty: true),
                workspacePullRequest: SidebarPullRequestState(
                    number: 5812,
                    label: "manaflow-ai/cmux",
                    url: URL(string: "https://example.test/pull/5812")!,
                    status: .open,
                    branch: "feature/super-search"
                ),
                statusEntries: [
                    SidebarStatusEntry(key: "agent", value: "Indexing transcripts")
                ],
                progress: SidebarProgressState(value: 0.5, label: "halfway"),
                metadataBlocks: [
                    SidebarMetadataBlock(key: "summary", markdown: "metadata block text", priority: 1, timestamp: .now)
                ],
                logEntries: [
                    SidebarLogEntry(message: "recent sidebar log", level: .info, source: "agent", timestamp: .now)
                ],
                panels: [
                    GlobalSearchWorkspaceMetadataPanelSnapshot(
                        id: UUID(),
                        title: "Claude Session",
                        directory: "/Users/test/repo/panel",
                        gitBranch: SidebarGitBranchState(branch: "panel-branch", isDirty: false),
                        pullRequest: SidebarPullRequestState(
                            number: 42,
                            label: "manaflow-ai/cmux",
                            url: URL(string: "https://example.test/pull/42")!,
                            status: .merged,
                            branch: "panel-branch"
                        )
                    )
                ]
            )
        )

        XCTAssertEqual(document.id, GlobalSearchDocuments.workspaceMetadataDocumentID(workspaceID: workspaceID))
        XCTAssertEqual(document.kind, .workspace)
        XCTAssertTrue(document.text.contains("workspace title: Infra Workspace"))
        XCTAssertTrue(document.text.contains("workspace cwd: /Users/test/repo"))
        XCTAssertTrue(document.text.contains("workspace git branch: feature/super-search"))
        XCTAssertTrue(document.text.contains("workspace pull request number: #5812"))
        XCTAssertTrue(document.text.contains("status agent: Indexing transcripts"))
        XCTAssertTrue(document.text.contains("progress: halfway"))
        XCTAssertTrue(document.text.contains("metadata summary: metadata block text"))
        XCTAssertTrue(document.text.contains("log: recent sidebar log"))
        XCTAssertTrue(document.text.contains("panel title: Claude Session"))
        XCTAssertTrue(document.text.contains("panel cwd: /Users/test/repo/panel"))
        XCTAssertTrue(document.text.contains("panel pull request number: #42"))
    }

    func testWorkspaceMetadataDocumentIsCapped() {
        let oversized = String(repeating: "x", count: GlobalSearchIndexingLimits.maxWorkspaceMetadataCharacters + 500)
        let document = GlobalSearchDocuments.workspaceMetadataDocument(
            windowID: UUID(),
            workspaceID: UUID(),
            workspaceTitle: "Workspace",
            location: "Window > Workspace",
            snapshot: GlobalSearchWorkspaceMetadataSnapshot(
                currentDirectory: oversized,
                workspaceGitBranch: nil,
                workspacePullRequest: nil,
                statusEntries: [],
                progress: nil,
                metadataBlocks: [],
                logEntries: [],
                panels: []
            )
        )

        XCTAssertEqual(document.text.count, GlobalSearchIndexingLimits.maxWorkspaceMetadataCharacters)
    }

    func testTranscriptDocumentHelpersExtractSupportedTextOnly() {
        let prose = SuperSearchTestSupport.message(
            seq: 1,
            kind: .prose(ChatProse(text: "agent prose token"))
        )
        let command = SuperSearchTestSupport.message(
            seq: 2,
            kind: .terminal(ChatTerminalCapture(
                command: "echo command-token",
                output: "output-token"
            ))
        )
        let fileEdit = SuperSearchTestSupport.message(
            seq: 3,
            kind: .fileEdit(ChatFileEdit(
                filePath: "/tmp/file.txt",
                operation: .edit,
                unifiedDiff: "should-not-index"
            ))
        )

        XCTAssertEqual(GlobalSearchTranscriptDocuments.transcriptText(for: prose), "agent prose token")
        XCTAssertNil(GlobalSearchTranscriptDocuments.transcriptText(for: command))
        XCTAssertEqual(GlobalSearchTranscriptDocuments.commandText(for: command), "echo command-token\noutput-token")
        XCTAssertNil(GlobalSearchTranscriptDocuments.transcriptText(for: fileEdit))
        XCTAssertNil(GlobalSearchTranscriptDocuments.commandText(for: fileEdit))
    }
}
