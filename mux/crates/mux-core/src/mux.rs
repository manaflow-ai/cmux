//! The multiplexer: owns the session [`State`] and every surface runtime,
//! and broadcasts [`MuxEvent`]s to subscribed frontends.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

use crate::model::{Node, Pane, Screen, State, Workspace};
use crate::surface::{DefaultColors, Surface, SurfaceOptions};
use crate::{PaneId, ScreenId, SplitDir, SurfaceId, WorkspaceId};

/// Events pushed to subscribed frontends.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// New output arrived in a surface (coalesced; cleared when rendered).
    SurfaceOutput(SurfaceId),
    /// A surface's PTY and terminal grid changed size.
    SurfaceResized {
        surface: SurfaceId,
        cols: u16,
        rows: u16,
    },
    /// A surface's child exited. The mux has already reaped it from the
    /// tree (a tree-changed follows) by the time this arrives.
    SurfaceExited(SurfaceId),
    TitleChanged(SurfaceId),
    Bell(SurfaceId),
    /// The workspace/screen/pane/tab tree changed (from any frontend or
    /// the control socket).
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
    default_colors: Mutex<DefaultColors>,
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
            default_colors: Mutex::new(DefaultColors::default()),
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

    /// A fresh single-tab pane wrapping `surface`.
    fn make_pane(&self, surface: SurfaceId) -> (PaneId, Pane) {
        let id = self.next_id();
        (id, Pane { id, name: None, tabs: vec![surface], active_tab: 0 })
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

    pub fn default_colors(&self) -> DefaultColors {
        *self.default_colors.lock().unwrap()
    }

    pub fn set_default_colors(&self, colors: DefaultColors) {
        *self.default_colors.lock().unwrap() = colors;
        let surfaces = self.state.lock().unwrap().surfaces.values().cloned().collect::<Vec<_>>();
        for surface in surfaces {
            surface.set_default_colors(colors);
            self.emit(MuxEvent::SurfaceOutput(surface.id));
        }
    }

    /// Resize a surface and broadcast the final clamped size when it
    /// actually changes.
    pub fn resize_surface(&self, id: SurfaceId, cols: u16, rows: u16) -> anyhow::Result<bool> {
        let Some(surface) = self.surface(id) else {
            anyhow::bail!("unknown surface {id}");
        };
        if !surface.resize(cols, rows) {
            return Ok(false);
        }
        let (cols, rows) = surface.size();
        self.emit(MuxEvent::SurfaceResized { surface: id, cols, rows });
        Ok(true)
    }

    /// Create a workspace with one screen holding one pane with one tab.
    /// Returns the tab's surface. `size` is the expected content size in
    /// cells, when the caller knows it (spawning at the final size avoids
    /// shell redraw artifacts).
    pub fn new_workspace(
        self: &Arc<Self>,
        name: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        let surface = self.spawn_surface(None, size)?;
        let (pane_id, pane) = self.make_pane(surface.id);
        let screen_id = self.next_id();
        let ws_id = self.next_id();
        {
            let mut state = self.state.lock().unwrap();
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.panes.insert(pane_id, pane);
            state.workspaces.push(Workspace {
                id: ws_id,
                name,
                screens: vec![Screen {
                    id: screen_id,
                    name: None,
                    root: Node::Leaf(pane_id),
                    active_pane: pane_id,
                }],
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(surface)
    }

    /// Create a screen in a workspace (default: the active one) with one
    /// pane/tab, and make it active. Returns the tab's surface.
    pub fn new_screen(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Arc<Surface>> {
        // Validate the target before spawning a child.
        {
            let state = self.state.lock().unwrap();
            match workspace {
                Some(id) if !state.workspaces.iter().any(|w| w.id == id) => {
                    anyhow::bail!("unknown workspace {id}")
                }
                None if state.workspaces.is_empty() => {
                    drop(state);
                    return self.new_workspace(None, size);
                }
                _ => {}
            }
        }
        let surface = self.spawn_surface(None, size)?;
        let (pane_id, pane) = self.make_pane(surface.id);
        let screen_id = self.next_id();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let ws = match workspace {
                Some(id) => state.workspaces.iter_mut().find(|w| w.id == id),
                None => state.workspaces.get_mut(active),
            };
            match ws {
                Some(ws) => {
                    ws.screens.push(Screen {
                        id: screen_id,
                        name: None,
                        root: Node::Leaf(pane_id),
                        active_pane: pane_id,
                    });
                    ws.active_screen = ws.screens.len() - 1;
                    state.panes.insert(pane_id, pane);
                    true
                }
                None => {
                    state.surfaces.remove(&surface.id);
                    false
                }
            }
        };
        if !attached {
            surface.kill();
            anyhow::bail!("workspace disappeared while creating screen");
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(surface)
    }

    /// Create a tab in a pane (default: the active pane of the active
    /// screen). When the session has no workspaces yet (headless before
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

    /// Split the screen containing `target`, putting a new single-tab
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
            'outer: for ws in state.workspaces.iter_mut() {
                for screen in ws.screens.iter_mut() {
                    if screen.root.split_leaf(target, dir, pane_id) {
                        screen.active_pane = pane_id;
                        done = true;
                        break 'outer;
                    }
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
    /// out of its split tree (and emptied screens/workspaces are removed).
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

    /// Close every surface in `tabs` (helper for pane/screen/workspace
    /// close). Emits events outside the lock.
    fn close_surfaces(&self, tabs: Vec<SurfaceId>) {
        let (removed, empty) = {
            let mut state = self.state.lock().unwrap();
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

    /// Close a pane and every tab in it.
    pub fn close_pane(&self, target: PaneId) {
        let tabs = {
            let state = self.state.lock().unwrap();
            match state.panes.get(&target) {
                Some(pane) => pane.tabs.clone(),
                None => return,
            }
        };
        self.close_surfaces(tabs);
    }

    /// Close a screen and every pane/tab in it.
    pub fn close_screen(&self, target: ScreenId) -> bool {
        let tabs = {
            let state = self.state.lock().unwrap();
            let Some(screen) =
                state.workspaces.iter().flat_map(|ws| ws.screens.iter()).find(|s| s.id == target)
            else {
                return false;
            };
            screen_tabs(&state, screen)
        };
        self.close_surfaces(tabs);
        true
    }

    /// Close a workspace and every screen/pane/tab in it.
    pub fn close_workspace(&self, target: WorkspaceId) -> bool {
        let tabs = {
            let state = self.state.lock().unwrap();
            let Some(ws) = state.workspaces.iter().find(|ws| ws.id == target) else {
                return false;
            };
            ws.screens.iter().flat_map(|screen| screen_tabs(&state, screen)).collect::<Vec<_>>()
        };
        self.close_surfaces(tabs);
        true
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

    /// Set a screen's user-visible name. An empty name clears it (the
    /// screen falls back to its number).
    pub fn rename_screen(&self, target: ScreenId, name: String) -> bool {
        let renamed = {
            let mut state = self.state.lock().unwrap();
            match state
                .workspaces
                .iter_mut()
                .flat_map(|ws| ws.screens.iter_mut())
                .find(|s| s.id == target)
            {
                Some(screen) => {
                    screen.name = (!name.is_empty()).then_some(name);
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

    /// Make `pane` the active pane of its screen (and that screen and
    /// workspace active).
    pub fn focus_pane(&self, pane: PaneId) -> bool {
        let found = {
            let mut state = self.state.lock().unwrap();
            match state.screen_of(pane) {
                Some((wi, si)) => {
                    state.active_workspace = wi;
                    let ws = &mut state.workspaces[wi];
                    ws.active_screen = si;
                    ws.screens[si].active_pane = pane;
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

    /// Set the deepest split ratio in `dir` on the path to `pane`.
    pub fn set_ratio(&self, pane: PaneId, dir: SplitDir, ratio: f32) -> bool {
        let ratio = ratio.clamp(0.05, 0.95);
        let found = {
            let mut state = self.state.lock().unwrap();
            state
                .workspaces
                .iter_mut()
                .flat_map(|ws| ws.screens.iter_mut())
                .any(|screen| screen.root.set_deepest_ratio(pane, dir, ratio))
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

    /// Select a screen in the active workspace by index or relative delta.
    pub fn select_screen(&self, index: Option<usize>, delta: Option<isize>) {
        {
            let mut state = self.state.lock().unwrap();
            let active = state.active_workspace;
            let Some(ws) = state.workspaces.get_mut(active) else { return };
            let len = ws.screens.len();
            if len == 0 {
                return;
            }
            if let Some(index) = index {
                if index < len {
                    ws.active_screen = index;
                }
            } else if let Some(delta) = delta {
                ws.active_screen =
                    ((ws.active_screen as isize + delta).rem_euclid(len as isize)) as usize;
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

/// Every surface in a screen (all panes, all tabs).
fn screen_tabs(state: &State, screen: &Screen) -> Vec<SurfaceId> {
    let mut pane_ids = Vec::new();
    screen.root.pane_ids(&mut pane_ids);
    pane_ids
        .iter()
        .filter_map(|id| state.panes.get(id))
        .flat_map(|pane| pane.tabs.iter().copied())
        .collect()
}

/// Remove one surface from the state: kill its child, detach it from its
/// pane, and collapse emptied panes/screens/workspaces. Returns whether
/// anything was removed. Runs under the state lock.
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

    // Last tab gone: the pane collapses out of its screen.
    state.panes.remove(&pane_id);
    let Some((wi, si)) = state.screen_of(pane_id) else { return true };
    let screen = &mut state.workspaces[wi].screens[si];
    match std::mem::replace(&mut screen.root, Node::Leaf(0)).remove_leaf(pane_id) {
        Some(root) => {
            screen.root = root;
            if screen.active_pane == pane_id {
                let mut ids = Vec::new();
                screen.root.pane_ids(&mut ids);
                screen.active_pane = ids[0];
            }
            return true;
        }
        None => {
            // Screen emptied: drop it from the workspace.
            let ws = &mut state.workspaces[wi];
            ws.screens.remove(si);
            ws.active_screen = ws.active_screen.min(ws.screens.len().saturating_sub(1));
            if !ws.screens.is_empty() {
                return true;
            }
        }
    }

    // Workspace emptied too: drop it, keeping the active selection stable.
    let active_id = state.workspaces.get(state.active_workspace).map(|w| w.id);
    state.workspaces.remove(wi);
    state.active_workspace = active_id
        .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
        .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
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
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1, p2, p3]);
        });

        mux.close_pane(p2);
        mux.with_state(|s| {
            let mut ids = Vec::new();
            s.workspaces[0].screens[0].root.pane_ids(&mut ids);
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

        // Closing the last tab collapses the pane, screen, and workspace.
        mux.close_surface(s1.id);
        mux.with_state(|s| assert!(s.workspaces.is_empty()));
    }

    #[test]
    fn set_ratio_updates_deepest_split_and_clamps() {
        let mux = test_mux();
        let s1 = mux.new_workspace(None, None).unwrap();
        let p1 = mux.with_state(|s| s.pane_of(s1.id).unwrap());
        let s2 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        let s3 = mux.split(p1, SplitDir::Right, None).unwrap();
        let p3 = mux.with_state(|s| s.pane_of(s3.id).unwrap());

        assert!(mux.set_ratio(p1, SplitDir::Right, 0.8));
        mux.with_state(|s| {
            let root = &s.workspaces[0].screens[0].root;
            let Node::Split { ratio: root_ratio, a, .. } = root else {
                panic!("root should be split");
            };
            assert_eq!(*root_ratio, 0.5);
            let Node::Split { ratio: inner_ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*inner_ratio, 0.8);
        });

        assert!(mux.set_ratio(p2, SplitDir::Right, -1.0));
        mux.with_state(|s| {
            let Node::Split { ratio, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            assert_eq!(*ratio, 0.05);
        });

        assert!(mux.set_ratio(p3, SplitDir::Right, 2.0));
        mux.with_state(|s| {
            let Node::Split { a, .. } = &s.workspaces[0].screens[0].root else {
                panic!("root should be split");
            };
            let Node::Split { ratio, .. } = a.as_ref() else {
                panic!("first child should be split");
            };
            assert_eq!(*ratio, 0.95);
        });

        assert!(!mux.set_ratio(9999, SplitDir::Right, 0.4));

        mux.close_pane(p1);
        mux.close_pane(p2);
        mux.close_pane(p3);
    }

    #[test]
    fn screens_within_workspace() {
        let mux = test_mux();
        mux.new_workspace(None, None).unwrap();
        let s2 = mux.new_screen(None, None).unwrap();

        let (screen1, screen2) = mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 2);
            assert_eq!(ws.active_screen, 1);
            (ws.screens[0].id, ws.screens[1].id)
        });

        // Select back to screen 1; screen 2 keeps running.
        mux.select_screen(Some(0), None);
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 0));

        // Renaming a screen sticks; clearing falls back.
        assert!(mux.rename_screen(screen2, "logs".into()));
        mux.with_state(|s| {
            assert_eq!(s.workspaces[0].screens[1].name.as_deref(), Some("logs"));
        });

        // Focusing a pane in screen 2 activates that screen.
        let p2 = mux.with_state(|s| s.pane_of(s2.id).unwrap());
        assert!(mux.focus_pane(p2));
        mux.with_state(|s| assert_eq!(s.workspaces[0].active_screen, 1));

        // Closing screen 2 keeps the workspace with screen 1.
        assert!(mux.close_screen(screen2));
        mux.with_state(|s| {
            let ws = &s.workspaces[0];
            assert_eq!(ws.screens.len(), 1);
            assert_eq!(ws.screens[0].id, screen1);
            assert_eq!(ws.active_screen, 0);
        });
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
            (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[1].screens[0].active_pane)
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
