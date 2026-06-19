import Foundation
import SwiftUI
import CmuxSidebarInterpreterClient
import CmuxSwiftRender

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
        var customSidebarRenderWorkerClient: RenderWorkerClient?
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
            customSidebarDataContext: { _ in [:] },
            customSidebarDispatch: .noop,
            customSidebarRenderer: .inProcess,
            customSidebarRenderWorkerClient: Binding(
                get: { customSidebarRenderWorkerClient },
                set: { customSidebarRenderWorkerClient = $0 }
            ),
            onClose: onClose
        )
    }
}
