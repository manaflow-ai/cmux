//! Workspace pins and workspace drags on the daemon's sidebar document
//! (`sidebar-doc-v1`): Pin is the document's Pinned section, and a drop is
//! one `sidebar.move` next to the drawn neighbor. The tree is already in the
//! document's order, so a drop slot's neighbors are the drawn ones. Without
//! the document a drop keeps the old `move-workspace` and there is no pin.

use cmux_tui_core::WorkspaceId;

use crate::app::{App, MenuAction};
use crate::session::SidebarDropAnchors;

impl App {
    fn workspace_public_id(&self, id: WorkspaceId) -> Option<String> {
        self.tree
            .workspaces()
            .iter()
            .find(|workspace| workspace.id == id)
            .and_then(|workspace| workspace.resource_id.as_ref())
            .map(|resource| resource.as_str().to_string())
    }

    /// Pin or Unpin, when the daemon's document places the workspace.
    pub(super) fn workspace_pin_menu_action(&self, id: WorkspaceId) -> Option<MenuAction> {
        let pinned = self.session.sidebar_workspace_pinned(&self.workspace_public_id(id)?)?;
        Some(MenuAction::PinWorkspace { workspace: id, pinned: !pinned })
    }

    pub(super) fn set_workspace_pinned(&mut self, id: WorkspaceId, pinned: bool) {
        if let Some(resource) = self.workspace_public_id(id) {
            self.session.set_sidebar_workspace_pinned(resource, pinned);
        }
    }

    /// The rail's pin key: pin an unpinned workspace, unpin a pinned one.
    pub(super) fn toggle_workspace_pin(&mut self, id: WorkspaceId) {
        if let Some(MenuAction::PinWorkspace { pinned, .. }) = self.workspace_pin_menu_action(id) {
            self.set_workspace_pinned(id, pinned);
        }
    }

    /// Drop a dragged workspace at slot `insertion` of the drawn list.
    pub(super) fn move_workspace_to_drop_slot(&mut self, workspace: WorkspaceId, insertion: usize) {
        let workspaces = self.tree.workspaces();
        let insertion = insertion.min(workspaces.len());
        let public = |index: usize| {
            workspaces[index].resource_id.as_ref().map(|resource| resource.as_str().to_string())
        };
        let anchors = SidebarDropAnchors {
            before: (insertion..workspaces.len())
                .find(|index| workspaces[*index].id != workspace)
                .and_then(public),
            after: (0..insertion)
                .rev()
                .find(|index| workspaces[*index].id != workspace)
                .and_then(public),
        };
        let resource = self.workspace_public_id(workspace);
        self.session.move_workspace_to_slot(workspace, insertion, resource, anchors);
    }
}
