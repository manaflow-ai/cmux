import Foundation
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension RightSidebarPanelView {
    init(
        tabManager: TabManager,
        fileExplorerStore: FileExplorerStore,
        fileExplorerState: FileExplorerState,
        sessionIndexStore: SessionIndexStore,
        titlebarHeight: CGFloat,
        workspaceId: UUID?,
        onResumeSession: ((SessionEntry) -> Void)?,
        onOpenFilePreview: @escaping (String) -> Void,
        onOpenAsPane: @escaping (RightSidebarMode) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.init(
            tabManager: tabManager,
            fileExplorerStore: fileExplorerStore,
            fileExplorerState: fileExplorerState,
            sessionIndexStore: sessionIndexStore,
            titlebarHeight: titlebarHeight,
            workspaceId: workspaceId,
            onResumeSession: onResumeSession,
            onOpenFilePreview: onOpenFilePreview,
            onOpenAsPane: onOpenAsPane,
            onClose: onClose
        )
    }
}
