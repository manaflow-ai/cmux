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
use mux_core::{Mux, MuxEvent, PaneId, SplitDir, Surface, SurfaceId, WorkspaceId};
use serde_json::json;

pub use remote::{RemoteSession, RemoteSurface};
pub use tree::TreeView;

pub enum Session {
    Local(Arc<Mux>),
    Remote(Arc<RemoteSession>),
}

#[derive(Clone)]
pub enum SurfaceHandle {
    Local(Arc<Surface>),
    Remote(Arc<RemoteSurface>, Arc<RemoteSession>),
}

impl Session {
    /// Make sure the session has at least one workspace to show.
    pub fn ensure_initial(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => {
                mux.new_workspace(None)?;
                Ok(())
            }
            Session::Remote(remote) => {
                if remote.tree()?.workspaces.is_empty() {
                    remote.request(json!({"cmd": "new-workspace"}))?;
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

    pub fn tree(&self) -> TreeView {
        match self {
            Session::Local(mux) => mux.with_state(tree::tree_from_state),
            Session::Remote(remote) => remote.tree().unwrap_or_default(),
        }
    }

    pub fn surface(&self, id: SurfaceId) -> Option<SurfaceHandle> {
        match self {
            Session::Local(mux) => mux.surface(id).map(SurfaceHandle::Local),
            Session::Remote(remote) => remote
                .ensure_surface(id)
                .map(|surface| SurfaceHandle::Remote(surface, remote.clone())),
        }
    }

    pub fn new_tab(&self, pane: Option<PaneId>) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_tab(pane, None).map(|_| ()),
            Session::Remote(remote) => {
                remote.request(json!({"cmd": "new-tab", "pane": pane})).map(|_| ())
            }
        }
    }

    pub fn new_workspace(&self) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.new_workspace(None).map(|_| ()),
            Session::Remote(remote) => remote.request(json!({"cmd": "new-workspace"})).map(|_| ()),
        }
    }

    pub fn split(&self, pane: PaneId, dir: SplitDir) -> anyhow::Result<()> {
        match self {
            Session::Local(mux) => mux.split(pane, dir).map(|_| ()),
            Session::Remote(remote) => {
                let dir = match dir {
                    SplitDir::Right => "right",
                    SplitDir::Down => "down",
                };
                remote.request(json!({"cmd": "split", "pane": pane, "dir": dir})).map(|_| ())
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
            SurfaceHandle::Local(surface) => {
                let _ = surface.write_bytes(bytes);
            }
            SurfaceHandle::Remote(surface, session) => {
                session.send_bytes(surface.id, bytes);
            }
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
        }
    }

    pub fn take_dirty(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface) => surface.take_dirty(),
            SurfaceHandle::Remote(surface, _) => surface.dirty.swap(false, Ordering::AcqRel),
        }
    }

    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        match self {
            SurfaceHandle::Local(surface) => surface.snapshot(rs),
            SurfaceHandle::Remote(surface, _) => rs.update(&mut surface.term.lock().unwrap()),
        }
    }

    /// Run `f` against the surface's terminal state (the mirror, for
    /// remote surfaces — modes and keyboard state replay there too).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> R {
        match self {
            SurfaceHandle::Local(surface) => surface.with_terminal(f),
            SurfaceHandle::Remote(surface, _) => f(&mut surface.term.lock().unwrap()),
        }
    }
}
