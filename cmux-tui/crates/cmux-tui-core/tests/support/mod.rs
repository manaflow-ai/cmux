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

/// Threads of this process.
#[cfg(target_os = "linux")]
pub fn process_threads() -> usize {
    std::fs::read_dir("/proc/self/task").expect("/proc/self/task").count()
}

/// Threads of this process.
#[cfg(target_os = "macos")]
pub fn process_threads() -> usize {
    // SAFETY: proc_taskinfo is plain integers; all zeroes is a valid value.
    let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_taskinfo>() as libc::c_int;
    // SAFETY: `info` is a proc_taskinfo, the layout of PROC_PIDTASKINFO.
    let read = unsafe {
        libc::proc_pidinfo(
            std::process::id() as libc::c_int,
            libc::PROC_PIDTASKINFO,
            0,
            (&raw mut info).cast(),
            size,
        )
    };
    assert_eq!(read, size, "proc_pidinfo");
    info.pti_threadnum as usize
}

/// The thread count once it held still for 300 ms (threads that start or
/// exit after a step settle first).
pub fn settled_threads() -> usize {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = process_threads();
    let mut since = Instant::now();
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(25));
        let now = process_threads();
        if now != last {
            (last, since) = (now, Instant::now());
        } else if since.elapsed() >= Duration::from_millis(300) {
            break;
        }
    }
    last
}
