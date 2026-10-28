//! Workspace pins and workspace drags on the daemon's sidebar document
//! (`sidebar-doc-v1`): Pin is the document's Pinned section, and a drop is
//! one `sidebar.move` next to the drawn neighbor. The tree is already in the
//! document's order, so a drop slot's neighbors are the drawn ones. Without
//! the document a drop keeps the old `move-workspace` and there is no pin.

use cmux_tui_core::{Rect, WorkspaceId};

use crate::app::{App, MenuAction};
use crate::session::{SidebarDropAnchors, WorkspaceView};

/// The workspace rows as the rail last drew them: its area, the visible
/// body, the body's scroll offset in rows, and the row metrics. Drop slots
/// come from this, so a drop lands under the pointer at any scroll, row gap
/// or action placement.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct WorkspaceDropGeometry {
    pub area: Rect,
    pub body: Rect,
    pub body_offset: usize,
    pub stride: usize,
    pub height: usize,
    pub len: usize,
}

/// Where a dragged workspace would land.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct WorkspaceDropSlot {
    /// The insertion index in the drawn list (it counts the dragged row).
    pub index: usize,
    /// The pointer is on the lower half of the row above the slot or the
    /// gap under it, not on the upper half of the row below.
    pub below_row: bool,
    /// On a border of two sidebar sections: `Some(true)` joins the section
    /// above, `Some(false)` the one below. `None` inside one section.
    pub border: Option<bool>,
}

impl App {
    /// The drop slot under the pointer, from the drawn rows. A row's upper
    /// half is the slot before it; its lower half and the gap under it are
    /// the slot after it. Above the visible body (top pad, actions at the
    /// top) is the first visible row; below it, the row after the last.
    pub(super) fn workspace_drop_slot_at(
        &self,
        workspace: WorkspaceId,
        x: u16,
        y: u16,
    ) -> Option<WorkspaceDropSlot> {
        let geometry = self.workspace_drop_geometry?;
        let area = geometry.area;
        if self.workspace_sidebar_area(self.content_area.height.saturating_add(1)) != Some(area)
            || area.width < 3
            || geometry.stride == 0
            || x < area.x
            || x >= area.x + area.width.saturating_sub(1)
            || y < area.y
            || y >= area.y.saturating_add(area.height)
        {
            return None;
        }
        let body = geometry.body;
        let body_end = body.y.saturating_add(body.height);
        let (index, below_row) = if y < body.y {
            // Above a scrolled body the slot would be off screen: none.
            if geometry.body_offset > 0 {
                return None;
            }
            (0, false)
        } else if y >= body_end {
            // Below the body: after the last fully drawn row.
            let shown = geometry.body_offset + usize::from(body.height);
            let rows = shown.saturating_sub(geometry.height) / geometry.stride + 1;
            let index = rows.min(geometry.len);
            (index, index > 0)
        } else {
            let logical = geometry.body_offset + usize::from(y - body.y);
            let (row, within) = (logical / geometry.stride, logical % geometry.stride);
            if row >= geometry.len {
                (geometry.len, geometry.len > 0)
            } else if within < geometry.height.div_ceil(2) {
                (row, false)
            } else {
                (row + 1, true)
            }
        };
        // The dragged row's own slot changes nothing, so it joins no section.
        let own = self.tree.workspaces().iter().position(|view| view.id == workspace);
        let border = if own.is_some_and(|own| index == own || index == own + 1) {
            None
        } else {
            self.workspace_slot_neighbors(workspace, index).and_then(|(after, before)| {
                let above = self.session.sidebar_workspace_container(&after)?;
                let below = self.session.sidebar_workspace_container(&before)?;
                (above != below).then_some(below_row)
            })
        };
        Some(WorkspaceDropSlot { index, below_row, border })
    }

    /// The public ids of the drawn rows on either side of slot `insertion`,
    /// without the dragged row.
    fn workspace_slot_neighbors(
        &self,
        workspace: WorkspaceId,
        insertion: usize,
    ) -> Option<(String, String)> {
        let anchors = self.workspace_drop_anchors(workspace, insertion, false);
        Some((anchors.after?, anchors.before?))
    }

    fn workspace_drop_anchors(
        &self,
        workspace: WorkspaceId,
        insertion: usize,
        below_row: bool,
    ) -> SidebarDropAnchors {
        let workspaces = self.tree.workspaces();
        let insertion = insertion.min(workspaces.len());
        let (above, below) = workspaces.split_at(insertion);
        let public = |candidate: &WorkspaceView| {
            candidate.resource_id.as_ref().map(|resource| resource.as_str().to_string())
        };
        SidebarDropAnchors {
            before: below.iter().find(|candidate| candidate.id != workspace).and_then(public),
            after: above.iter().rev().find(|candidate| candidate.id != workspace).and_then(public),
            prefer_after: below_row,
        }
    }

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

    /// Drop a dragged workspace at slot `insertion` of the drawn list;
    /// `below_row`: the pointer is under the row above the slot, so on a
    /// section border the drop joins that row's section.
    pub(super) fn move_workspace_to_drop_slot(
        &mut self,
        workspace: WorkspaceId,
        insertion: usize,
        below_row: bool,
    ) {
        let workspaces = self.tree.workspaces();
        let insertion = insertion.min(workspaces.len());
        // A drop on the dragged row's own slot changes nothing.
        if let Some(index) = workspaces.iter().position(|view| view.id == workspace)
            && (insertion == index || insertion == index + 1)
        {
            return;
        }
        let anchors = self.workspace_drop_anchors(workspace, insertion, below_row);
        let resource = self.workspace_public_id(workspace);
        self.session.move_workspace_to_slot(workspace, insertion, resource, anchors);
    }
}
