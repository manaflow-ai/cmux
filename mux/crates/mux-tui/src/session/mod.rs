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
    DefaultColors, Mux, MuxEvent, PaneId, ScreenId, SplitDir, Surface, SurfaceId, WorkspaceId,
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

pub(crate) fn resize_action(
    desired: (u16, u16),
    asserted: Option<(u16, u16)>,
    server: (u16, u16),
    user_interaction: bool,
) -> bool {
    if user_interaction {
        desired != server
    } else {
        asserted != Some(desired)
    }
}

#[derive(Clone)]
pub enum SurfaceHandle {
    Local(Arc<Surface>, Arc<Mux>),
    Remote(Arc<RemoteSurface>, Arc<RemoteSession>),
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
            Session::Local(mux) => {
                mux.surface(id).map(|surface| SurfaceHandle::Local(surface, mux.clone()))
            }
            Session::Remote(remote) => remote
                .ensure_surface(id, size)
                .map(|surface| SurfaceHandle::Remote(surface, remote.clone())),
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

    pub fn rename_pane(&self, pane: PaneId, name: String) {
        match self {
            Session::Local(mux) => {
                mux.rename_pane(pane, name);
            }
            Session::Remote(remote) => {
                let _ = remote.request(json!({"cmd": "rename-pane", "pane": pane, "name": name}));
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
    pub fn write_bytes(&self, bytes: &[u8]) {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let _ = surface.write_bytes(bytes);
            }
            SurfaceHandle::Remote(surface, session) => {
                session.send_bytes(surface.id, bytes);
            }
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let desired = (cols.max(1), rows.max(1));
        match self {
            SurfaceHandle::Local(surface, mux) => {
                let _ = mux.resize_surface(surface.id, desired.0, desired.1);
            }
            SurfaceHandle::Remote(surface, session) => {
                if resize_action(desired, surface.asserted_size(), surface.server_size(), false) {
                    let _ = session.request(json!({
                        "cmd": "resize-surface",
                        "surface": surface.id,
                        "cols": desired.0,
                        "rows": desired.1,
                    }));
                    surface.set_asserted_size(desired);
                }
            }
        }
    }

    pub fn reassert_size(&self, cols: u16, rows: u16) {
        let desired = (cols.max(1), rows.max(1));
        match self {
            SurfaceHandle::Local(surface, mux) => {
                let _ = mux.resize_surface(surface.id, desired.0, desired.1);
            }
            SurfaceHandle::Remote(surface, session) => {
                if resize_action(desired, surface.asserted_size(), surface.server_size(), true) {
                    let _ = session.request(json!({
                        "cmd": "resize-surface",
                        "surface": surface.id,
                        "cols": desired.0,
                        "rows": desired.1,
                    }));
                }
                surface.set_asserted_size(desired);
            }
        }
    }

    pub fn take_dirty(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.take_dirty(),
            SurfaceHandle::Remote(surface, _) => surface.dirty.swap(false, Ordering::AcqRel),
        }
    }

    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.snapshot(rs),
            SurfaceHandle::Remote(surface, _) => rs.update(&mut surface.term.lock().unwrap()),
        }
    }

    /// Run `f` against the surface's terminal state (the mirror, for
    /// remote surfaces — modes and keyboard state replay there too).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> R {
        match self {
            SurfaceHandle::Local(surface, _) => surface.with_terminal(f),
            SurfaceHandle::Remote(surface, _) => f(&mut surface.term.lock().unwrap()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::resize_action;

    #[test]
    fn first_layout_after_attach_does_not_send_redundant_resize() {
        let desired = (123, 65);
        assert!(!resize_action(desired, Some(desired), desired, false));
    }

    #[test]
    fn remote_resize_with_no_local_change_does_not_send() {
        let desired = (123, 65);
        let server = (341, 92);
        assert!(!resize_action(desired, Some(desired), server, false));
    }

    #[test]
    fn remote_resize_followed_by_user_interaction_sends() {
        let desired = (123, 65);
        let server = (341, 92);
        assert!(resize_action(desired, Some(desired), server, true));
    }

    #[test]
    fn steady_state_does_not_send() {
        let desired = (123, 65);
        assert!(!resize_action(desired, Some(desired), desired, false));
        assert!(!resize_action(desired, Some(desired), desired, true));
    }
}
