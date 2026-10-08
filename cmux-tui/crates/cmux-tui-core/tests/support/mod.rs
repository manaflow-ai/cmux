//! Shared by integration tests: the key-less Mux op names, each acting as the
//! daemon (P8 landing 3a; production code names its actor with `*_as`).
#![allow(dead_code)]

use std::sync::Arc;

use cmux_tui_core::{Actor, Mux, PaneId, Surface, SurfaceId};

pub trait DaemonMuxOps {
    fn close_surface(&self, target: SurfaceId) -> anyhow::Result<bool>;
    fn new_browser_tab(&self, url: String, pane: Option<PaneId>, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>>;
    fn new_tab(&self, pane: Option<PaneId>, cwd: Option<String>, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>>;
    fn new_workspace(&self, name: Option<String>, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>>;
}

impl DaemonMuxOps for Arc<Mux> {
    fn close_surface(&self, target: SurfaceId) -> anyhow::Result<bool> {
        self.close_surface_as(&Actor::Daemon, target)
    }

    fn new_browser_tab(&self, url: String, pane: Option<PaneId>, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_as(&Actor::Daemon, url, pane, size)
    }

    fn new_tab(&self, pane: Option<PaneId>, cwd: Option<String>, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_as(&Actor::Daemon, pane, cwd, size)
    }

    fn new_workspace(&self, name: Option<String>, size: Option<(u16, u16)>) -> anyhow::Result<Arc<Surface>> {
        self.new_workspace_as(&Actor::Daemon, name, size)
    }
}
