import AppKit
import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Tab drag capability bridge", .serialized)
@MainActor
struct TabDragCapabilityBridgeTests {
    @Test("Workspace targets resolve a native Bonsplit capability")
    func workspaceTargetResolvesNativeBonsplitCapability() throws {
        let registry = TabDragTransferRegistry.process
        let transfer = TabDragTransfer(
            tab: Tab(title: "Terminal", kind: "terminal"),
            sourcePaneId: PaneID()
        )
        let registration = try #require(registry.register(transfer))
        defer { registry.end(registration) }
        let pasteboard = makePasteboard()
        #expect(registration.write(to: pasteboard))

        #expect(BonsplitTabDragPayload.transfer(from: pasteboard) != nil)
    }

    @Test("Workspace targets reject the former JSON payload")
    func workspaceTargetRejectsUnregisteredJSON() throws {
        let pasteboard = makePasteboard()
        let payload: [String: Any] = [
            "tab": [
                "id": UUID().uuidString,
                "title": "Serialized tab metadata",
            ],
            "sourcePaneId": UUID().uuidString,
            "sourceProcessId": ProcessInfo.processInfo.processIdentifier,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        pasteboard.setData(data, forType: TabDragTransferRegistry.pasteboardType)

        #expect(BonsplitTabDragPayload.transfer(from: pasteboard) == nil)
    }

    @Test("Session Index publishes a capability that Bonsplit resolves")
    func sessionIndexPublishesResolvableCapability() throws {
        let entry = SessionEntry(
            id: UUID().uuidString,
            agent: .claude,
            sessionId: UUID().uuidString,
            title: "Resume session",
            cwd: "/tmp",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        let provider = sessionDragItemProvider(for: entry)
        defer { pasteboard.clearContents() }

        #expect(
            provider.registeredTypeIdentifiers.contains(
                TabDragTransferRegistry.pasteboardType.rawValue
            )
        )
        let transfer = try #require(
            TabDragTransferRegistry.process.resolve(from: pasteboard)
        )
        #expect(transfer.tab.kind == "terminal")
        #expect(SessionDragRegistry.shared.consume(id: transfer.tab.id.uuid) == entry)
        withExtendedLifetime(provider) {}
    }

    @Test("File Preview publishes a capability that Bonsplit resolves")
    func filePreviewPublishesResolvableCapability() throws {
        FilePreviewDragRegistry.shared.discardAll()
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        let writer = FilePreviewDragPasteboardWriter(
            filePath: "/tmp/example.txt",
            displayTitle: "example.txt"
        )
        defer {
            FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: pasteboard)
            pasteboard.clearContents()
            FilePreviewDragRegistry.shared.discardAll()
        }

        _ = writer.writableTypes(for: pasteboard)

        let transfer = try #require(
            TabDragTransferRegistry.process.resolve(from: pasteboard)
        )
        #expect(transfer.tab.kind == "filePreview")
        #expect(FilePreviewDragRegistry.shared.contains(id: transfer.tab.id.uuid))
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("TabDragCapabilityBridgeTests.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return pasteboard
    }
}
