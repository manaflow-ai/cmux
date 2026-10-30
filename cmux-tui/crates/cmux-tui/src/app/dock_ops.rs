//! Docked workspaces in the App (plans/cmux-next/docked-workspace-DESIGN.md):
//! placing the frame for a layout, the dock actions, focus following a click
//! into a dock, the dock menu, and the client's record in its frontend
//! projection.
//!
//! The stage shows the active workspace unless a docked workspace has focus;
//! then it keeps the last workspace it showed (W5). Focus in a dock is the
//! tree's active workspace, so keys and actions follow the workspace the user
//! types in, while the stage stays where it was (W4).

use cmux_tui_core::{
    Node, PaneId, Rect, ScreenId, ViewportLayoutResult, WorkspaceId, layout_screen,
};

use crate::app::menu::MenuItem;
use crate::app::pane_projection::{PaneAreaProjection, rebuild_pane_areas};
use crate::app::window_docks::{
    PROJECTION_FRONTEND, PROJECTION_SCHEMA_VERSION, PROJECTION_SCOPE, PROJECTION_SUBJECT_PREFIX,
    WindowFrameRecord,
};
use crate::app::window_frame::{DockEdge, place_frame};
use crate::app::{App, MenuAction, RenderAction};
use crate::config::Action;
use crate::localization;
use crate::session::tree::ScreenView;
use crate::session::{ProjectionKey, TreeView};

/// The dock actions in menu order.
const DOCK_ACTIONS: [Action; 11] = [
    Action::DockWorkspaceLeft,
    Action::DockWorkspaceRight,
    Action::DockWorkspaceTop,
    Action::DockWorkspaceBottom,
    Action::UndockWorkspace,
    Action::ToggleDockLeft,
    Action::ToggleDockRight,
    Action::ToggleDockTop,
    Action::ToggleDockBottom,
    Action::ToggleDockFloating,
    Action::ToggleDockOrientation,
];

/// The active screen of `stage`, or the tree's active screen without one.
pub(super) fn stage_screen_of(tree: &TreeView, stage: Option<WorkspaceId>) -> Option<&ScreenView> {
    match stage {
        Some(id) => tree
            .workspaces()
            .iter()
            .find(|workspace| workspace.id == id)
            .and_then(|workspace| workspace.active_screen_ref()),
        None => tree.active_screen(),
    }
}

/// What one layout placed: the stage's rect and screen, and the docked
/// workspaces' screens (their pane areas are in `App::docks`).
pub(super) struct FrameLayout {
    pub(super) stage: Rect,
    pub(super) stage_screen: Option<ScreenView>,
    pub(super) dock_screens: Vec<ScreenView>,
}

impl App {
    /// Docked workspaces are on (cmux-tui.json `viewport.docked_workspaces`)
    /// and this is a full client, not a scoped single-surface attach.
    pub(crate) fn docked_workspaces_enabled(&self) -> bool {
        self.surface_only.is_none() && self.config.viewport.docked_workspaces
    }

    /// The rect the stage's screen lays out in.
    pub(super) fn stage_area(&self) -> Rect {
        self.docks.stage.unwrap_or(self.content_area)
    }

    /// The rect the active workspace shows in: its dock, else the stage.
    pub(super) fn active_frame_area(&self) -> Rect {
        let active = self.tree.active_workspace().map(|workspace| workspace.id);
        self.docks
            .placed
            .iter()
            .find(|(_, workspace)| Some(*workspace) == active)
            .map(|(placement, _)| placement.rect)
            .unwrap_or_else(|| self.stage_area())
    }

    /// The screen the stage shows: the active screen without a frame.
    pub(super) fn stage_screen(&self) -> Option<&ScreenView> {
        stage_screen_of(&self.tree, self.docks.stage_workspace)
    }

    pub(super) fn stage_screen_id(&self) -> Option<ScreenId> {
        self.stage_screen().map(|screen| screen.id)
    }

    /// Place the frame in `area` for this layout. Without a frame (the
    /// feature off, no dock, no workspace for the stage, or the focused dock
    /// not placed) the stage is `area` and shows the active screen.
    pub(super) fn sync_frame(&mut self, area: Rect) -> FrameLayout {
        self.docks.clear_placement();
        if !self.docked_workspaces_enabled() {
            return self.unframed_layout(area);
        }
        if !self.docks.loaded {
            self.restore_docks_from_session();
        }
        self.reconcile_docks();
        if self.docks.record.docks.is_empty() {
            return self.unframed_layout(area);
        }
        let Some(active_key) = self.tree.active_workspace().map(|workspace| workspace.key.clone())
        else {
            return self.unframed_layout(area);
        };
        let stage_key = {
            let order = self
                .tree
                .workspaces()
                .iter()
                .map(|workspace| workspace.key.as_str())
                .collect::<Vec<_>>();
            self.docks
                .record
                .stage_for(&active_key, &self.docks.recent_stage, &order)
                .map(str::to_string)
        };
        let Some(stage_key) = stage_key else { return self.unframed_layout(area) };
        let placement =
            place_frame(area, &self.docks.record.docks, self.docks.record.dock_orientation);
        let active_docked = self.docks.record.is_docked(&active_key);
        let active_placed = placement.docks.iter().any(|placed| {
            self.docks
                .record
                .dock_at(placed.edge)
                .is_some_and(|dock| dock.workspace_key == active_key)
        });
        if active_docked && !active_placed {
            return self.unframed_layout(area);
        }
        let Some((stage_workspace, stage_screen)) = self
            .tree
            .workspaces()
            .iter()
            .find(|workspace| workspace.key == stage_key)
            .map(|workspace| (workspace.id, workspace.active_screen_ref().cloned()))
        else {
            return self.unframed_layout(area);
        };
        self.docks.record.stage_key = Some(stage_key.clone());
        self.docks.note_stage(&stage_key);

        let mut dock_screens = Vec::new();
        for placed in &placement.docks {
            let Some(dock) = self.docks.record.dock_at(placed.edge) else { continue };
            let Some(workspace) =
                self.tree.workspaces().iter().find(|workspace| workspace.key == dock.workspace_key)
            else {
                continue;
            };
            let Some(screen) = workspace.active_screen_ref() else { continue };
            let layout: ViewportLayoutResult = match screen.zoomed_pane {
                Some(pane) => layout_screen(&Node::Leaf(pane), placed.rect, Some(pane)).into(),
                None => layout_screen(&screen.layout, placed.rect, Some(screen.active_pane)).into(),
            };
            let mut areas = Vec::new();
            rebuild_pane_areas(
                &mut areas,
                PaneAreaProjection {
                    screen,
                    layout: &layout.panes,
                    stacked_headers: &layout.stacked_headers,
                    area: placed.rect,
                    scrollbar_position: self.config.scrollbar.position,
                    pane_padding: self.config.pane.padding,
                    surface_only: None,
                    viewport_offset: None,
                },
            );
            if placed.floating {
                self.docks.floating_panes.extend(areas.iter().map(|area| area.pane));
            }
            self.docks.pane_areas.extend(areas);
            self.docks.placed.push((*placed, workspace.id));
            dock_screens.push(screen.clone());
        }
        self.docks.stage = Some(placement.stage);
        self.docks.stage_workspace = Some(stage_workspace);
        FrameLayout { stage: placement.stage, stage_screen, dock_screens }
    }

    /// The layout without a frame: the stage is `area` and shows the
    /// active screen.
    fn unframed_layout(&self, area: Rect) -> FrameLayout {
        FrameLayout {
            stage: area,
            stage_screen: self.tree.active_screen().cloned(),
            dock_screens: Vec::new(),
        }
    }

    /// Bring the record in line with the tree: drop docks of closed
    /// workspaces (W3), dock a workspace a Toggle asked for, and show the
    /// dock of a selected docked workspace (W4).
    fn reconcile_docks(&mut self) {
        if self.tree.workspaces().is_empty() {
            return;
        }
        let keys = self
            .tree
            .workspaces()
            .iter()
            .map(|workspace| workspace.key.clone())
            .collect::<Vec<_>>();
        let mut changed = self.docks.record.retain_live(|key| keys.iter().any(|live| live == key));
        if let Some((edge, known)) = self.docks.pending_edge.take() {
            match keys.iter().find(|key| !known.contains(*key)) {
                Some(created) => {
                    self.docks.record.dock(created, edge);
                    changed = true;
                }
                None => self.docks.pending_edge = Some((edge, known)),
            }
        }
        if let Some(active) = self.tree.active_workspace().map(|workspace| workspace.key.clone()) {
            changed |= self.docks.record.show(&active);
        }
        if changed {
            self.persist_docks();
        }
    }

    pub(super) fn run_dock_action(&mut self, action: Action) -> RenderAction {
        let messages = &localization::catalog().menu;
        if !self.docked_workspaces_enabled() {
            self.status_message = Some(messages.docked_workspaces_off.to_string());
            return RenderAction::Draw;
        }
        let Some(active) = self.tree.active_workspace().map(|workspace| workspace.key.clone())
        else {
            return RenderAction::Draw;
        };
        if !self.docks.loaded {
            self.restore_docks_from_session();
        }
        self.docks.pending_edge = None;
        let edge = |action: Action| match action {
            Action::DockWorkspaceLeft | Action::ToggleDockLeft => Some(DockEdge::Left),
            Action::DockWorkspaceRight | Action::ToggleDockRight => Some(DockEdge::Right),
            Action::DockWorkspaceTop | Action::ToggleDockTop => Some(DockEdge::Top),
            Action::DockWorkspaceBottom | Action::ToggleDockBottom => Some(DockEdge::Bottom),
            _ => None,
        };
        match action {
            Action::DockWorkspaceLeft
            | Action::DockWorkspaceRight
            | Action::DockWorkspaceTop
            | Action::DockWorkspaceBottom => {
                let Some(edge) = edge(action) else { return RenderAction::Draw };
                self.docks.record.dock(&active, edge);
                // W2: the stage needs a workspace that is not docked.
                let stage_left = self
                    .tree
                    .workspaces()
                    .iter()
                    .any(|workspace| !self.docks.record.is_docked(&workspace.key));
                if !stage_left {
                    self.request_dock_workspace(None);
                }
            }
            Action::UndockWorkspace => {
                if !self.docks.record.undock(&active) {
                    self.status_message = Some(messages.docked_workspace_none.to_string());
                    return RenderAction::Draw;
                }
            }
            Action::ToggleDockLeft
            | Action::ToggleDockRight
            | Action::ToggleDockTop
            | Action::ToggleDockBottom => {
                let Some(edge) = edge(action) else { return RenderAction::Draw };
                match self.docks.record.toggle_hidden(edge) {
                    // Hiding the dock that has focus hands focus to the stage.
                    Some(true) => {
                        if self
                            .docks
                            .record
                            .dock_at(edge)
                            .is_some_and(|dock| dock.workspace_key == active)
                        {
                            self.focus_stage();
                        }
                    }
                    Some(false) => {}
                    None => self.request_dock_workspace(Some(edge)),
                }
            }
            Action::ToggleDockFloating => {
                if !self.docks.record.toggle_floating(&active) {
                    self.status_message = Some(messages.docked_workspace_none.to_string());
                    return RenderAction::Draw;
                }
            }
            Action::ToggleDockOrientation => self.docks.record.toggle_orientation(),
            _ => return RenderAction::None,
        }
        self.persist_docks();
        RenderAction::Draw
    }

    /// Create a workspace; with `edge`, dock it there once it exists.
    fn request_dock_workspace(&mut self, edge: Option<DockEdge>) {
        if let Some(edge) = edge {
            let known =
                self.tree.workspaces().iter().map(|workspace| workspace.key.clone()).collect();
            self.docks.pending_edge = Some((edge, known));
        }
        if let Err(error) = self.new_workspace(None) {
            self.docks.pending_edge = None;
            self.status_message = Some(error.to_string());
        }
    }

    /// Move focus from a dock to the stage's workspace.
    fn focus_stage(&mut self) {
        let Some(stage) = self.docks.stage_workspace else { return };
        let Some(index) = self.tree.workspaces().iter().position(|workspace| workspace.id == stage)
        else {
            return;
        };
        self.select_workspace_for_client(Some(index), None);
    }

    /// A press in a pane of another on-screen workspace (a dock, or the
    /// stage while a dock has focus) focuses that workspace first (K1); it
    /// never moves the workspace to the stage.
    pub(super) fn focus_frame_workspace_of_pane(&mut self, pane: PaneId) {
        if self.docks.placed.is_empty() {
            return;
        }
        let Some(index) = self.tree.workspaces().iter().position(|workspace| {
            workspace
                .active_screen_ref()
                .is_some_and(|screen| screen.panes.iter().any(|candidate| candidate.id == pane))
        }) else {
            return;
        };
        if index != self.tree.active_workspace {
            self.select_workspace_for_client(Some(index), None);
        }
    }

    /// The Docked workspaces submenu of the global menu items.
    pub(super) fn dock_menu_item(&self) -> Option<MenuItem> {
        if !self.docked_workspaces_enabled() {
            return None;
        }
        let items = DOCK_ACTIONS
            .into_iter()
            .map(|action| MenuItem::LabeledAction {
                label: localization::catalog().action_label(action).to_string(),
                action: MenuAction::RunConfigured { action, pane: None },
            })
            .collect();
        Some(MenuItem::Submenu {
            label: localization::catalog().menu.docked_workspaces.to_string(),
            items,
        })
    }

    fn dock_projection_subject(&self) -> Option<String> {
        self.client_focus_id.as_ref().map(|id| format!("{PROJECTION_SUBJECT_PREFIX}{id}"))
    }

    /// Read this client's record from the session (the frontend projection
    /// keyed by the client id). A session without one starts with no docks.
    pub(super) fn restore_docks_from_session(&mut self) {
        self.docks.loaded = true;
        self.docks.record = WindowFrameRecord::default();
        self.docks.pending_edge = None;
        self.docks.recent_stage.clear();
        self.docks.clear_placement();
        if !self.docked_workspaces_enabled() {
            return;
        }
        let Some(subject) = self.dock_projection_subject() else { return };
        let key = ProjectionKey {
            frontend: PROJECTION_FRONTEND,
            scope: PROJECTION_SCOPE,
            subject_key: &subject,
        };
        match self.session.inner.frontend_projection(key) {
            Ok(Some(value)) => match serde_json::from_value::<WindowFrameRecord>(value) {
                Ok(record) => self.docks.record = record,
                Err(error) => {
                    crate::client_log::warn("docks", &format!("unreadable docks: {error}"));
                }
            },
            Ok(None) => {}
            Err(error) => {
                crate::client_log::warn("docks", &format!("docks not read: {error}"));
            }
        }
    }

    /// Save this client's record in its frontend projection.
    fn persist_docks(&mut self) {
        let Some(subject) = self.dock_projection_subject() else { return };
        let Ok(value) = serde_json::to_value(&self.docks.record) else { return };
        let key = ProjectionKey {
            frontend: PROJECTION_FRONTEND,
            scope: PROJECTION_SCOPE,
            subject_key: &subject,
        };
        if let Err(error) =
            self.session.inner.put_frontend_projection(key, PROJECTION_SCHEMA_VERSION, &value)
        {
            crate::client_log::warn("docks", &format!("docks not saved: {error}"));
        }
    }
}
