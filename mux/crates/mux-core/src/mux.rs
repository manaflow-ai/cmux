//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use crate::model::{Node, Pane, State, Workspace};
use crate::surface::{Surface, SurfaceOptions};
use crate::{PaneId, SplitDir, SurfaceId, WorkspaceId};

/// Events pushed to subscribed frontends.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// New output arrived in a surface (coalesced; cleared when rendered).
    SurfaceOutput(SurfaceId),
    /// A surface's child exited. The mux has already reaped it from the
    /// tree (a tree-changed follows) by the time this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged(SurfaceId),
    Bell(SurfaceId),
    /// The workspace/pane/tab tree changed (from any frontend or the
    /// control socket).
    TreeChanged,
    /// Every workspace is gone.
    Empty,
}

/// The multiplexer. Shared by frontends and the control socket server.
pub struct Mux {
    state: Mutex<State>,
    subscribers: Mutex<Vec<Sender<MuxEvent>>>,
    next_id: AtomicU64,
    surface_options: SurfaceOptions,
    pub session: String,
}

impl Mux {
    pub fn new(session: impl Into<String>, surface_options: SurfaceOptions) -> Arc<Self> {
        Arc::new(Mux {
            state: Mutex::new(State {
                workspaces: Vec::new(),
                active_workspace: 0,
                panes: HashMap::new(),
                surfaces: HashMap::new(),
            }),
            subscribers: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
            surface_options,
            session: session.into(),
        })
    }

    fn next_id(&self) -> u64 {
        self.next_id.fetch_add(1, Ordering::Relaxed)
    }

    pub fn subscribe(&self) -> Receiver<MuxEvent> {
        let (tx, rx) = channel();
        self.subscribers.lock().unwrap().push(tx);
        rx
    }

    pub fn emit(&self, event: MuxEvent) {
        let mut subs = self.subscribers.lock().unwrap();
        subs.retain(|tx| tx.send(event.clone()).is_ok());
    }

    fn spawn_surface(
        self: &Arc<Self>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let id = self.next_id();
        let mut opts = self.surface_options.clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        // Spawn at the final size when the frontend knows it: starting at
        // the default 80x24 and resizing a frame later makes shells emit
        // artifacts (e.g. zsh's reverse-video %% partial-line marker).
        if let Some((cols, rows)) = size {
            opts.cols = cols.max(1);
            opts.rows = rows.max(1);
        }
        let surface = Surface::spawn(id, opts, Arc::downgrade(self))?;
        self.state.lock().unwrap().surfaces.insert(id, surface.clone());
        Ok(surface)
    }

    pub fn surface(&self, id: SurfaceId) -> Option<Arc<Surface>> {
        self.state.lock().unwrap().surfaces.get(&id).cloned()
    }

    /// Run `f` with the session state.
    ///
    /// The state lock is held for the duration of `f`; do not call back
    /// into `Mux` methods that take it (`surface()`, `close_pane()`, ...).
    pub fn with_state<R>(&self, f: impl FnOnce(&State) -> R) -> R {
        f(&self.state.lock().unwrap())
    }

    pub fn surface_count(&self) -> usize {
        self.state.lock().unwrap().surfaces.len()
    }

    /// Create a workspace with one pane holding one tab. Returns the tab's
    /// surface. `size` is the expected content size in cells, when the
    /// caller knows it (spawning at the final size avoids shell redraw
    /// artifacts).
    pub fn new_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let surface = self.spawn_surface(None, size)?;
        let pane_id = self.next_id();
        let ws_id = self.next_id();
        {
            let mut state = self.state.lock().unwrap();
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.panes.insert(
                pane_id,
                Pane { id: pane_id, name: None, tabs: vec![surface.id], active_tab: 0 },
            );
            state.workspaces.push(Workspace {
                id: ws_id,
                name,
                root: Node::Leaf(pane_id),
                active_pane: pane_id,
            });
            state.active_workspace = state.workspaces.len() - 1;
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(surface)
    }

    /// Create a tab in a pane (default: the active pane of the active
    /// workspace). When the session has no workspaces yet (headless before
    /// any command), a workspace is created around the new tab.
    pub fn new_tab(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        // Resolve and validate the target before spawning a child.
        let target = {
            let state = self.state.lock().unwrap();
            match pane {
                Some(id) => {
                    if !state.panes.contains_key(&id) {
                        anyhow::bail!("unknown pane {id}");
                    }
                    Some(id)
                }
                None => state.active_pane(),
            }
        };
        let Some(target) = target else {
            return self.new_workspace(None, size);
        };

        let cwd = cwd.or_else(|| self.pane_cwd(target));
        // A sibling tab renders at the size the pane already has.
        let size = size.or_else(|| self.pane_size(target));
        let surface = self.spawn_surface(cwd, size)?;
        let attached = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    true
                }
                None => {
                    // Pane disappeared between validation and attach.
                    state.surfaces.remove(&surface.id);
                    false
                }
            }
        };
        if !attached {
            surface.kill();
            anyhow::bail!("pane disappeared while creating tab");
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(surface)
    }

    /// Working directory of a pane's active surface, if reported.
    fn pane_cwd(&self, pane: PaneId) -> Option<String> {
        let surface = {
            let state = self.state.lock().unwrap();
            let active = state.panes.get(&pane)?.active_surface()?;
            state.surfaces.get(&active).cloned()
        };
        surface.and_then(|s| s.pwd())
    }

    /// Current cell size of a pane's active surface.
    fn pane_size(&self, pane: PaneId) -> Option<(u16, u16)> {
        let state = self.state.lock().unwrap();
        let active = state.panes.get(&pane)?.active_surface()?;
        state.surfaces.get(&active).map(|s| s.size())
    }

    /// Split the workspace containing `target`, putting a new single-tab
    /// pane after it. Returns the new pane's surface. `size` is the
    /// expected content size of the new pane, when the caller knows it.
    pub fn split(
        self: &Arc<Self>,
        target: PaneId,
        dir: SplitDir,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let cwd = self.pane_cwd(target);
        // Halve the split axis as a fallback estimate; the frontend sends
        // the exact size on its next layout pass.
        let size = size.or_else(|| {
            self.pane_size(target).map(|(cols, rows)| match dir {
                SplitDir::Right => ((cols.saturating_sub(1) / 2).max(1), rows),
                SplitDir::Down => (cols, (rows.saturating_sub(1) / 2).max(1)),
            })
        });
        let surface = self.spawn_surface(cwd, size)?;
        let pane_id = self.next_id();
        let mut done = false;
        {
            let mut state = self.state.lock().unwrap();
            for ws in state.workspaces.iter_mut() {
                if ws.root.split_leaf(target, dir, pane_id) {
                    ws.active_pane = pane_id;
                    done = true;
                    break;
                }
            }
            if done {
                state.panes.insert(
                    pane_id,
                    Pane { id: pane_id, name: None, tabs: vec![surface.id], active_tab: 0 },
                );
            } else {
                state.surfaces.remove(&surface.id);
            }
        }
        if !done {
            surface.kill();
            anyhow::bail!("pane {target} not found");
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(surface)
    }

    /// Close one tab. When it was the pane's last tab, the pane collapses
    /// out of its split tree (and an emptied workspace is removed).
    pub fn close_surface(&self, target: SurfaceId) {
        let (removed, empty) = {
            let mut state = self.state.lock().unwrap();
            (remove_surface(&mut state, target), state.workspaces.is_empty())
        };
        if removed {
            self.emit(MuxEvent::TreeChanged);
        }
        if empty {
            self.emit(MuxEvent::Empty);
        }
    }

    /// Close a pane and every tab in it.
    pub fn close_pane(&self, target: PaneId) {
        let (removed, empty) = {
            let mut state = self.state.lock().unwrap();
            let tabs = match state.panes.get(&target) {
                Some(pane) => pane.tabs.clone(),
                None => return,
            };
            let mut removed = false;
            for surface in tabs {
                removed |= remove_surface(&mut state, surface);
            }
            (removed, state.workspaces.is_empty())
        };
        if removed {
            self.emit(MuxEvent::TreeChanged);
        }
        if empty {
            self.emit(MuxEvent::Empty);
        }
    }

    /// Close a workspace and every pane/tab in it.
    pub fn close_workspace(&self, target: WorkspaceId) -> bool {
        let (removed, empty) = {
            let mut state = self.state.lock().unwrap();
            let Some(ws) = state.workspaces.iter().find(|ws| ws.id == target) else {
                return false;
            };
            let mut pane_ids = Vec::new();
            ws.root.pane_ids(&mut pane_ids);
            let tabs: Vec<SurfaceId> = pane_ids
                .iter()
                .filter_map(|id| state.panes.get(id))
                .flat_map(|pane| pane.tabs.iter().copied())
                .collect();
            let mut removed = false;
            for surface in tabs {
                removed |= remove_surface(&mut state, surface);
            }
            (removed, state.workspaces.is_empty())
        };
        if removed {
            self.emit(MuxEvent::TreeChanged);
        }
        if empty {
            self.emit(MuxEvent::Empty);
        }
        removed
    }

    pub fn rename_workspace(&self, target: WorkspaceId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state.workspaces.iter_mut().find(|ws| ws.id == target) {
                Some(ws) => {
                    ws.name = name;
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.emit(MuxEvent::TreeChanged);
        }
        renamed
    }

    /// Set a pane's user-visible name. An empty name clears it (the pane
    /// falls back to its active tab's title).
    pub fn rename_pane(&self, target: PaneId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.name = (!name.is_empty()).then_some(name);
                    true
                }
                None => false,
            }
        };
        if renamed {
            self.emit(MuxEvent::TreeChanged);
        }
        renamed
    }

    /// Called by a surface's reader thread when its child exits. The mux
    /// reaps the surface out of the tree itself, so frontends only need to
    /// drop their render state.
    pub fn surface_exited(&self, id: SurfaceId) {
        self.close_surface(id);
        self.emit(MuxEvent::SurfaceExited(id));
    }

    /// Make `pane` the active pane of its workspace (and that workspace
    /// active).
    pub fn focus_pane(&self, pane: PaneId) -> bool {
        let found = {
            let mut state = self.state.lock().unwrap();
            match state.workspace_of(pane) {
                Some(ws_idx) => {
                    state.active_workspace = ws_idx;
                    state.workspaces[ws_idx].active_pane = pane;
                    true
                }
                None => false,
            }
        };
        if found {
            self.emit(MuxEvent::TreeChanged);
        }
        found
    }

    /// Select a tab within a pane (default: the active pane) by index or
    /// relative delta.
    pub fn select_tab(&self, pane: Option<PaneId>, index: Option<usize>, delta: Option<isize>) {
        {
            let mut state = self.state.lock().unwrap();
            let Some(target) = pane.or_else(|| state.active_pane()) else { return };
            let Some(pane) = state.panes.get_mut(&target) else { return };
            let len = pane.tabs.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    pane.active_tab = index;
                }
            } else if let Some(delta) = delta {
                pane.active_tab =
                    ((pane.active_tab as isize + delta).rem_euclid(len as isize)) as usize;
            }
        }
        self.emit(MuxEvent::TreeChanged);
    }

    /// Select a workspace by index or relative delta.
    pub fn select_workspace(&self, index: Option<usize>, delta: Option<isize>) {
        {
            let mut state = self.state.lock().unwrap();
            let len = state.workspaces.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    state.active_workspace = index;
                }
            } else if let Some(delta) = delta {
                state.active_workspace =
                    ((state.active_workspace as isize + delta).rem_euclid(len as isize)) as usize;
            }
        }
        self.emit(MuxEvent::TreeChanged);
    }
}

/// Remove one surface from the state: kill its child, detach it from its
/// pane, and collapse emptied panes/workspaces. Returns whether anything
/// was removed. Runs under the state lock.
fn remove_surface(state: &mut State, target: SurfaceId) -> bool {
    let removed = state.surfaces.remove(&target);
    if let Some(surface) = &removed {
        surface.kill();
    }
    let Some(pane_id) = state.pane_of(target) else {
        return removed.is_some();
    };
    let pane = state.panes.get_mut(&pane_id).expect("pane_of returned live id");
    let idx = pane.tabs.iter().position(|id| *id == target).expect("tab in pane");
    pane.tabs.remove(idx);
    if !pane.tabs.is_empty() {
        if pane.active_tab >= idx && pane.active_tab > 0 {
            pane.active_tab -= 1;
        }
        return true;
    }

    // Last tab gone: the pane collapses out of its workspace.
    state.panes.remove(&pane_id);
    let Some(ws_idx) = state.workspace_of(pane_id) else { return true };
    let ws = &mut state.workspaces[ws_idx];
    match std::mem::replace(&mut ws.root, Node::Leaf(0)).remove_leaf(pane_id) {
        Some(root) => {
            ws.root = root;
            if ws.active_pane == pane_id {
                let mut ids = Vec::new();
                ws.root.pane_ids(&mut ids);
                ws.active_pane = ids[0];
            }
        }
        None => {
            // Whole workspace emptied.
            let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
            state.workspaces.remove(ws_idx);
            state.active_workspace = active_id
                .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_mux() -> Arc<Mux> {
        // A child that stays alive without doing anything.
        let opts =
            SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() };
        Mux::new("test", opts)
    }

    #[test]
    fn split_and_close_collapses_tree() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p2, SplitDir::Down, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p2, p3]);
        });

        mux.close_pane(p2);
        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p3]);
        });

        mux.close_pane(p1);
        mux.close_pane(p3);
        assert_eq!(mux.surface_count(), 0);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn tabs_within_pane() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let pane = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.new_tab(Some(pane), None, None).unwrap();

        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id, s2.id]);
            assert_eq!(p.active_tab, 1);
        });

        // Closing the active tab activates the previous one; the pane stays.
        mux.close_surface(s2.id);
        mux.with_state(|s| {
            let p = &s.panes[&pane];
            assert_eq!(p.tabs, vec![s1.id]);
            assert_eq!(p.active_tab, 0);
            assert_eq!(s.workspaces.len(), 1);
        });

        // Closing the last tab collapses the pane and the workspace.
        mux.close_surface(s1.id);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn workspaces_and_renames() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(None, None).unwrap();
        mux.new_workspace(Some("dev".into()), None).unwrap();

        let (ws0, ws1, pane1) = mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 2);
            assert_eq!(s.workspaces[1].name, "dev");
            assert_eq!(s.active_workspace, 1);
            (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[1].active_pane)
        });

        assert!(mux.rename_workspace(ws0, "ops".into()));
        assert!(mux.rename_pane(pane1, "logs".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].name, "ops");
            assert_eq!(s.panes[&pane1].name.as_deref(), Some("logs"));
        });
        // Clearing the name falls back to the tab title.
        assert!(mux.rename_pane(pane1, String::new()));
        mux.with_state(|s| assert_eq!(s.panes[&pane1].name, None));

        assert!(mux.close_workspace(ws1));
        mux.with_state(|s| {
            assert_eq!(s.workspaces.len(), 1);
            assert_eq!(s.workspaces[0].id, ws0);
            assert_eq!(s.active_workspace, 0);
        });
        assert!(events.try_iter().count() > 0);
    }
}
