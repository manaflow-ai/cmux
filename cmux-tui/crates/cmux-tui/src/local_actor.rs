//! The in-process TUI is the local user's own frontend (P8, plans/cmux-next/
//! identity.md section 3): every durable Mux op it makes names the local user.

use std::sync::OnceLock;

use cmux_tui_core::Actor;
#[cfg(test)]
use cmux_tui_core::{Mux, PaneId, SplitDir, Surface, SurfaceId, WorkspaceId, ZoomMode, ZoomState};
#[cfg(test)]
use std::sync::Arc;

/// The actor of the in-process TUI: the local user.
pub(crate) fn me() -> &'static Actor {
    static ME: OnceLock<Actor> = OnceLock::new();
    ME.get_or_init(Actor::local_user)
}

/// Tests keep the key-less op names; each acts as the local user.
#[cfg(test)]
pub(crate) trait TuiMuxOps {
    fn set_viewport_pane_width(&self, pane: PaneId, width: f32) -> bool;
    fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn close_surface(&self, target: SurfaceId) -> anyhow::Result<bool>;
    fn new_workspace(
        &self,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn new_tab(
        &self,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn split(
        &self,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn select_workspace(&self, index: Option<usize>, delta: Option<isize>);
    fn zoom_pane(&self, pane: Option<PaneId>, mode: ZoomMode) -> anyhow::Result<ZoomState>;
    fn new_screen(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> bool;
    fn focus_pane(&self, pane: PaneId) -> bool;
    fn close_pane(&self, target: PaneId) -> anyhow::Result<bool>;
    fn select_screen(&self, index: Option<usize>, delta: Option<isize>);
    fn rename_surface(&self, target: SurfaceId, name: String) -> bool;
    fn new_pane_right(
        &self,
        target: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
}

#[cfg(test)]
impl TuiMuxOps for Arc<Mux> {
    fn set_viewport_pane_width(&self, pane: PaneId, width: f32) -> bool {
        self.set_viewport_pane_width_as(me(), pane, width)
    }

    fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_as(me(), url, pane, size)
    }

    fn close_surface(&self, target: SurfaceId) -> anyhow::Result<bool> {
        self.close_surface_as(me(), target)
    }

    fn new_workspace(
        &self,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_workspace_as(me(), name, size)
    }

    fn new_tab(
        &self,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_as(me(), pane, cwd, size)
    }

    fn split(
        &self,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.split_as(me(), target, dir, size)
    }

    fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        self.select_workspace_as(me(), index, delta);
    }

    fn zoom_pane(&self, pane: Option<PaneId>, mode: ZoomMode) -> anyhow::Result<ZoomState> {
        self.zoom_pane_as(me(), pane, mode)
    }

    fn new_screen(
        &self,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_screen_as(me(), workspace, size)
    }

    fn move_tab(&self, surface: SurfaceId, pane: PaneId, index: usize) -> bool {
        self.move_tab_as(me(), surface, pane, index)
    }

    fn focus_pane(&self, pane: PaneId) -> bool {
        self.focus_pane_as(me(), pane)
    }

    fn close_pane(&self, target: PaneId) -> anyhow::Result<bool> {
        self.close_pane_as(me(), target)
    }

    fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        self.select_screen_as(me(), index, delta);
    }

    fn rename_surface(&self, target: SurfaceId, name: String) -> bool {
        self.rename_surface_as(me(), target, name)
    }

    fn new_pane_right(
        &self,
        target: PaneId,
        width: f32,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_pane_right_as(me(), target, width, size)
    }
}
