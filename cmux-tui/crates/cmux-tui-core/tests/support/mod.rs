//! Shared by integration tests: the key-less Mux op names, each acting as the
//! daemon (P8 landing 3a; production code names its actor with `*_as`).
#![allow(dead_code)]

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_tui_core::{Actor, Mux, PaneId, RunPlacement, Surface, SurfaceId, WorkspaceId};

pub trait DaemonMuxOps {
    fn close_workspace(&self, target: WorkspaceId) -> bool;
    #[allow(clippy::too_many_arguments)]
    fn run_command_surface(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement>;
    fn close_surface(&self, target: SurfaceId) -> anyhow::Result<bool>;
    fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn new_tab(
        &self,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
    fn new_workspace(
        &self,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>>;
}

impl DaemonMuxOps for Arc<Mux> {
    fn close_workspace(&self, target: WorkspaceId) -> bool {
        self.close_workspace_as(&Actor::Daemon, target)
    }

    fn run_command_surface(
        &self,
        argv: Vec<String>,
        pane: Option<PaneId>,
        new_workspace: bool,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<RunPlacement> {
        self.run_command_surface_as(&Actor::Daemon, argv, pane, new_workspace, cwd, name, size)
    }

    fn close_surface(&self, target: SurfaceId) -> anyhow::Result<bool> {
        self.close_surface_as(&Actor::Daemon, target)
    }

    fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_browser_tab_as(&Actor::Daemon, url, pane, size)
    }

    fn new_tab(
        &self,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_tab_as(&Actor::Daemon, pane, cwd, size)
    }

    fn new_workspace(
        &self,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        self.new_workspace_as(&Actor::Daemon, name, size)
    }
}

pub fn wait_for<T>(mut f: impl FnMut() -> Option<T>, timeout: Duration) -> Option<T> {
    let timeout_scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|scale| *scale > 0)
        .unwrap_or(1);
    let timeout = timeout.saturating_mul(timeout_scale);
    let start = Instant::now();
    while start.elapsed() < timeout {
        if let Some(v) = f() {
            return Some(v);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}
