import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct SidebarTabDragPayloadPasteboardTests {
    @Test @MainActor
    func pasteboardItemMaterializesWorkspaceIdentitySynchronously() {
        let workspaceId = UUID()
        let pasteboardType = NSPasteboard.PasteboardType(SidebarTabDragPayload.typeIdentifier)
        let item = SidebarTabDragPayload(tabId: workspaceId).pasteboardItem()

        #expect(item.types.contains(pasteboardType))
        #expect(
            item.string(forType: pasteboardType)
                == "\(SidebarTabDragPayload.prefix)\(workspaceId.uuidString)"
        )
    }
}
