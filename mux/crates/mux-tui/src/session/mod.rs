//! Frontend-facing session abstraction.
//!
//! The TUI runs against either an in-process mux (`Session::Local`) or a
//! remote one over the control socket (`Session::Remote`). Remote
//! surfaces are mirrored locally: the server sends a VT replay of each
//! surface's state followed by the live pty stream, and the client feeds
//! both into its own ghostty terminal. Rendering, key encoding, and mode
//! queries then work identically in both cases.

mod remote;
mod tree;

use std::sync::atomic::Ordering;
use std::sync::mpsc::Receiver;
use std::sync::Arc;

use ghostty_vt::{RenderState, Terminal};
use mux_core::{
    BrowserFrame, DefaultColors, Mux, MuxEvent, PaneId, ScreenId, SplitDir, Surface, SurfaceId,
    SurfaceKind, WorkspaceId,
};
use serde_json::json;

pub use remote::{RemoteSession, RemoteSurface};
pub use tree::TreeView;

pub enum Session {
    Local(Arc<Mux>),
    Remote(Arc<RemoteSession>),
}

/// Attach optional cols/rows fields to a remote command.
fn with_size(mut cmd: serde_json::Value, size: Option<(u16, u16)>) -> serde_json::Value {
    if let Some((cols, rows)) = size {
        cmd["cols"] = json!(cols);
        cmd["rows"] = json!(rows);
    }
    cmd
}

#[derive(Clone)]
pub enum SurfaceHandle {
    Local(Arc<Surface>),
    Remote(Arc<RemoteSurface>, Arc<RemoteSession>),
    RemoteBrowser,
}

impl Session {
    /// Make sure the session has at least one workspace to show. `size`
    /// is the expected content size of the first pane, when known.
    pub fn ensure_initial(&self, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.new_workspace(None, size)?;
                Ok(())
            }
            Session::Remote(remote) => {
                if remote.tree()?.workspaces.is_empty() {
                    remote.request(with_size(json!({"cmd": "new-workspace"}), size))?;
                }
                Ok(())
            }
        }
    }

    pub fn events(&self) -> Receiver<MuxEvent> {
        match self {
            Session::Local(mux) => mux.subscribe(),
            Session::Remote(remote) => remote.subscribe(),
        }
    }

    pub fn set_default_colors(&self, colors: DefaultColors) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.set_default_colors(colors);
                Ok(())
            }
            Session::Remote(remote) => remote.set_default_colors(colors),
        }
    }

    pub fn tree(&self) -> TreeView {
        match self {
            Session::Local(mux) => mux.with_state(tree::tree_from_state),
            Session::Remote(remote) => remote.tree().unwrap_or_default(),
        }
    }

    pub fn surface(&self, id: SurfaceId) -> Option<SurfaceHandle> {
        self.surface_sized(id, None)
    }

    /// Like [`Session::surface`], but passes the render size for remote
    /// mirrors created on first use (the server surface is resized before
    /// the attach replay, so the replay arrives at final geometry).
    pub fn surface_sized(&self, id: SurfaceId, size: Option<(u16, u16)>) -> Option<SurfaceHandle> {
        match self {
            Session::Local(mux) => mux.surface(id).map(SurfaceHandle::Local),
            Session::Remote(remote) => {
                if remote.surface_kind(id) == SurfaceKind::Browser {
                    Some(SurfaceHandle::RemoteBrowser)
                } else {
                    remote
                        .ensure_surface(id, size)
                        .map(|surface| SurfaceHandle::Remote(surface, remote.clone()))
                }
            }
        }
    }

    pub fn new_tab(&self, pane: Option<PaneId>, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_tab(pane, None, size).map(|_| ()),
            Session::Remote(remote) => {
                remote.request(with_size(json!({"cmd": "new-tab", "pane": pane}), size)).map(|_| ())
            }
        }
    }

    pub fn new_browser_tab(
        &self,
        url: String,
        pane: Option<PaneId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_browser_tab(url, pane, size).map(|_| ()),
            Session::Remote(_) => anyhow::bail!("browser panes are not supported over attach yet"),
        }
    }

    pub fn set_cell_pixel_size(&self, width_px: u16, height_px: u16) {
        if let Session::Local(mux) = self {
            mux.set_cell_pixel_size(width_px, height_px);
        }
    }

    pub fn new_workspace(&self, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_workspace(None, size).map(|_| ()),
            Session::Remote(remote) => {
                remote.request(with_size(json!({"cmd": "new-workspace"}), size)).map(|_| ())
            }
        }
    }

    /// New screen in the active workspace.
    pub fn new_screen(&self, size: Option<(u16, u16)>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_screen(None, size).map(|_| ()),
            Session::Remote(remote) => {
                remote.request(with_size(json!({"cmd": "new-screen"}), size)).map(|_| ())
            }
        }
    }

    pub fn close_screen(&self, screen: ScreenId) {
        match self {
            Session::Local(mux) => {
                mux.close_screen(screen);
            }
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "close-screen", "screen": screen}));
            }
        }
    }

    pub fn rename_screen(&self, screen: ScreenId, name: String) {
        match self {
            Session::Local(mux) => {
                mux.rename_screen(screen, name);
            }
            Session::Remote(remote) => {
                let _ =
                    remote.request(json!({"cmd": "rename-screen", "screen": screen, "name": name}));
            }
        }
    }

    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        match self {
            Session::Local(mux) => mux.select_screen(index, delta),
            Session::Remote(remote) => {
                let _ =
                    remote.request(json!({"cmd": "select-screen", "index": index, "delta": delta}));
            }
        }
    }

    pub fn split(
        &self,
        pane: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.split(pane, dir, size).map(|_| ()),
            Session::Remote(remote) => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                remote
                    .request(with_size(json!({"cmd": "split", "pane": pane, "dir": dir}), size))
                    .map(|_| ())
            }
        }
    }

    pub fn set_ratio(&self, pane: PaneId, dir: SplitDir, ratio: f32) {
        match self {
            Session::Local(mux) => {
                mux.set_ratio(pane, dir, ratio);
            }
            Session::Remote(remote) => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                let _ = remote
                    .request(json!({"cmd": "set-ratio", "pane": pane, "dir": dir, "ratio": ratio}));
            }
        }
    }

    pub fn close_surface(&self, surface: SurfaceId) {
        match self {
            Session::Local(mux) => mux.close_surface(surface),
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "close-surface", "surface": surface}));
            }
        }
    }

    pub fn close_pane(&self, pane: PaneId) {
        match self {
            Session::Local(mux) => mux.close_pane(pane),
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "close-pane", "pane": pane}));
            }
        }
    }

    pub fn close_workspace(&self, workspace: WorkspaceId) {
        match self {
            Session::Local(mux) => {
                mux.close_workspace(workspace);
            }
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "close-workspace", "workspace": workspace}));
            }
        }
    }

    pub fn rename_surface(&self, surface: SurfaceId, name: String) {
        match self {
            Session::Local(mux) => {
                mux.rename_surface(surface, name);
            }
            Session::Remote(remote) => {
                let _ = remote
                    .request(json!({"cmd": "rename-surface", "surface": surface, "name": name}));
            }
        }
    }

    pub fn rename_workspace(&self, workspace: WorkspaceId, name: String) {
        match self {
            Session::Local(mux) => {
                mux.rename_workspace(workspace, name);
            }
            Session::Remote(remote) => {
                let _ = remote.request(
                    json!({"cmd": "rename-workspace", "workspace": workspace, "name": name}),
                );
            }
        }
    }

    /// Drop the local mirror of an exited surface. The server (local mux
    /// or remote session) reaps its own tree.
    pub fn forget_surface(&self, surface: SurfaceId) {
        if let Session::Remote(remote) = self {
            remote.drop_surface(surface);
        }
    }

    pub fn focus_pane(&self, pane: PaneId) {
        match self {
            Session::Local(mux) => {
                mux.focus_pane(pane);
            }
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "focus-pane", "pane": pane}));
            }
        }
    }

    pub fn select_tab(&self, pane: Option<PaneId>, index: Option<usize>, delta: Option<isize>) {
        match self {
            Session::Local(mux) => mux.select_tab(pane, index, delta),
            Session::Remote(remote) => {
                let _ = remote.request(
                    json!({"cmd": "select-tab", "pane": pane, "index": index, "delta": delta}),
                );
            }
        }
    }

    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        match self {
            Session::Local(mux) => mux.select_workspace(index, delta),
            Session::Remote(remote) => {
                let _ = remote
                    .request(json!({"cmd": "select-workspace", "index": index, "delta": delta}));
            }
        }
    }
}

impl SurfaceHandle {
    pub fn kind(&self) -> SurfaceKind {
        match self {
            SurfaceHandle::Local(surface) => surface.kind(),
            SurfaceHandle::Remote(_, _) => SurfaceKind::Pty,
            SurfaceHandle::RemoteBrowser => SurfaceKind::Browser,
        }
    }

    pub fn write_bytes(&self, bytes: &[u8]) {
        match self {
            SurfaceHandle::Local(surface) => {
                let _ = surface.write_bytes(bytes);
            }
            SurfaceHandle::Remote(surface, session) => {
                session.send_bytes(surface.id, bytes);
            }
            SurfaceHandle::RemoteBrowser => {}
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        match self {
            SurfaceHandle::Local(surface) => surface.resize(cols, rows),
            SurfaceHandle::Remote(surface, session) => {
                if surface.set_size(cols, rows) {
                    let _ = session.request(json!({
                        "cmd": "resize-surface",
                        "surface": surface.id,
                        "cols": cols,
                        "rows": rows,
                    }));
                }
            }
            SurfaceHandle::RemoteBrowser => {}
        }
    }

    pub fn take_dirty(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface) => surface.take_dirty(),
            SurfaceHandle::Remote(surface, _) => surface.dirty.swap(false, Ordering::AcqRel),
            SurfaceHandle::RemoteBrowser => false,
        }
    }

    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        match self {
            SurfaceHandle::Local(surface) => surface.snapshot(rs),
            SurfaceHandle::Remote(surface, _) => rs.update(&mut surface.term.lock().unwrap()),
            SurfaceHandle::RemoteBrowser => Err(ghostty_vt::Error::InvalidValue),
        }
    }

    /// Run `f` against the surface's terminal state (the mirror, for
    /// remote surfaces — modes and keyboard state replay there too).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        match self {
            SurfaceHandle::Local(surface) => surface.with_terminal(f),
            SurfaceHandle::Remote(surface, _) => Some(f(&mut surface.term.lock().unwrap())),
            SurfaceHandle::RemoteBrowser => None,
        }
    }

    pub fn browser_frame(&self) -> Option<BrowserFrame> {
        match self {
            SurfaceHandle::Local(surface) => surface.browser_frame(),
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowser => None,
        }
    }

    pub fn browser_url(&self) -> Option<String> {
        match self {
            SurfaceHandle::Local(surface) => surface.browser_url(),
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowser => None,
        }
    }

    pub fn browser_insert_text(&self, text: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface) => surface.browser_insert_text(text),
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowser => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_key_event(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface) => surface.browser_key_event(
                event_type,
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            ),
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowser => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface) => {
                surface.browser_mouse_event(event_type, x, y, button, click_count)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowser => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface) => surface.browser_wheel(x, y, delta_y),
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowser => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }
}
