//! Terminal multiplexer core.
//!
//! Owns the workspace → tab → pane tree and each pane's runtime (a PTY
//! child whose output feeds a libghostty-vt terminal). Frontends (the
//! bundled TUI, or the cmux app over the control socket) subscribe to
//! [`MuxEvent`]s and read pane state; they never own terminal state
//! themselves, which is what makes the backend attachable.

mod layout;
mod pane;
pub mod server;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};

pub use layout::{layout_tab, LayoutResult, Rect, Separator};
pub use pane::{Pane, PaneOptions};

pub type PaneId = u64;
pub type TabId = u64;
pub type WorkspaceId = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitDir {
    /// Split into left/right columns.
    Right,
    /// Split into top/bottom rows.
    Down,
}

/// Binary split tree for one tab.
#[derive(Debug, Clone)]
pub enum Node {
    Leaf(PaneId),
    Split {
        dir: SplitDir,
        ratio: f32,
        a: Box<Node>,
        b: Box<Node>,
    },
}

impl Node {
    pub fn pane_ids(&self, out: &mut Vec<PaneId>) {
        match self {
            Node::Leaf(id) => out.push(*id),
            Node::Split { a, b, .. } => {
                a.pane_ids(out);
                b.pane_ids(out);
            }
        }
    }

    fn split_leaf(&mut self, target: PaneId, dir: SplitDir, new_pane: PaneId) -> bool {
        match self {
            Node::Leaf(id) if *id == target => {
                let old = Node::Leaf(*id);
                *self = Node::Split {
                    dir,
                    ratio: 0.5,
                    a: Box::new(old),
                    b: Box::new(Node::Leaf(new_pane)),
                };
                true
            }
            Node::Leaf(_) => false,
            Node::Split { a, b, .. } => {
                a.split_leaf(target, dir, new_pane) || b.split_leaf(target, dir, new_pane)
            }
        }
    }

    /// Remove a leaf, collapsing its parent split. Returns None when the
    /// whole node was the removed leaf.
    fn remove_leaf(self, target: PaneId) -> Option<Node> {
        match self {
            Node::Leaf(id) if id == target => None,
            leaf @ Node::Leaf(_) => Some(leaf),
            Node::Split { dir, ratio, a, b } => {
                match (a.remove_leaf(target), b.remove_leaf(target)) {
                    (Some(a), Some(b)) => Some(Node::Split {
                        dir,
                        ratio,
                        a: Box::new(a),
                        b: Box::new(b),
                    }),
                    (Some(a), None) => Some(a),
                    (None, Some(b)) => Some(b),
                    (None, None) => None,
                }
            }
        }
    }
}

#[derive(Debug)]
pub struct Tab {
    pub id: TabId,
    pub root: Node,
    pub active_pane: PaneId,
}

#[derive(Debug)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub name: String,
    pub tabs: Vec<Tab>,
    pub active_tab: usize,
}

/// Events pushed to subscribed frontends.
#[derive(Debug, Clone)]
pub enum MuxEvent {
    /// New output arrived in a pane (coalesced; cleared when rendered).
    PaneOutput(PaneId),
    PaneExited(PaneId),
    TitleChanged(PaneId),
    Bell(PaneId),
    /// The workspace/tab/pane tree changed (from any frontend or the
    /// control socket).
    TreeChanged,
    /// Every pane is gone.
    Empty,
}

struct State {
    workspaces: Vec<Workspace>,
    active_workspace: usize,
    panes: HashMap<PaneId, Arc<Pane>>,
}

/// The multiplexer. Shared by frontends and the control socket server.
pub struct Mux {
    state: Mutex<State>,
    subscribers: Mutex<Vec<Sender<MuxEvent>>>,
    next_id: AtomicU64,
    pane_options: PaneOptions,
    pub session: String,
}

impl Mux {
    pub fn new(session: impl Into<String>, pane_options: PaneOptions) -> Arc<Self> {
        Arc::new(Mux {
            state: Mutex::new(State {
                workspaces: Vec::new(),
                active_workspace: 0,
                panes: HashMap::new(),
            }),
            subscribers: Mutex::new(Vec::new()),
            next_id: AtomicU64::new(1),
            pane_options,
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

    fn spawn_pane(self: &Arc<Self>, cwd: Option<String>) -> anyhow::Result<Arc<Pane>> {
        let id = self.next_id();
        let mut opts = self.pane_options.clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        let pane = Pane::spawn(id, opts, Arc::downgrade(self))?;
        self.state.lock().unwrap().panes.insert(id, pane.clone());
        Ok(pane)
    }

    pub fn pane(&self, id: PaneId) -> Option<Arc<Pane>> {
        self.state.lock().unwrap().panes.get(&id).cloned()
    }

    /// Create a workspace with one tab and one pane. Returns the pane.
    pub fn new_workspace(self: &Arc<Self>, name: Option<String>) -> anyhow::Result<Arc<Pane>> {
        let pane = self.spawn_pane(None)?;
        let tab = Tab {
            id: self.next_id(),
            root: Node::Leaf(pane.id),
            active_pane: pane.id,
        };
        let ws_id = self.next_id();
        {
            let mut state = self.state.lock().unwrap();
            let name = name.unwrap_or_else(|| format!("{}", state.workspaces.len() + 1));
            state.workspaces.push(Workspace {
                id: ws_id,
                name,
                tabs: vec![tab],
                active_tab: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(pane)
    }

    /// Create a tab in a workspace (default: the active one). When the
    /// session has no workspaces yet (headless before any command), a
    /// workspace is created around the new tab.
    pub fn new_tab(
        self: &Arc<Self>,
        workspace: Option<WorkspaceId>,
        cwd: Option<String>,
    ) -> anyhow::Result<Arc<Pane>> {
        // Validate the target before spawning a child.
        self.with_tree(|workspaces, _| match workspace {
            Some(id) if !workspaces.iter().any(|w| w.id == id) => {
                anyhow::bail!("unknown workspace {id}")
            }
            _ => Ok(()),
        })?;
        if self.with_tree(|workspaces, _| workspaces.is_empty()) {
            return self.new_workspace(None);
        }

        let pane = self.spawn_pane(cwd)?;
        let tab_id = self.next_id();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let ws_idx = match workspace {
                Some(id) => state.workspaces.iter().position(|w| w.id == id),
                None => Some(state.active_workspace.min(state.workspaces.len().saturating_sub(1))),
            };
            match ws_idx.and_then(|i| state.workspaces.get_mut(i)) {
                Some(ws) => {
                    ws.tabs.push(Tab {
                        id: tab_id,
                        root: Node::Leaf(pane.id),
                        active_pane: pane.id,
                    });
                    ws.active_tab = ws.tabs.len() - 1;
                    true
                }
                None => {
                    // Workspace disappeared between validation and attach.
                    state.panes.remove(&pane.id);
                    false
                }
            }
        };
        if !attached {
            pane.kill();
            anyhow::bail!("workspace disappeared while creating tab");
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(pane)
    }

    /// Split the tab containing `target`, putting a new pane after it.
    pub fn split(self: &Arc<Self>, target: PaneId, dir: SplitDir) -> anyhow::Result<Arc<Pane>> {
        let cwd = self.pane(target).and_then(|p| p.pwd());
        let pane = self.spawn_pane(cwd)?;
        let mut done = false;
        {
            let mut state = self.state.lock().unwrap();
            'outer: for ws in state.workspaces.iter_mut() {
                for tab in ws.tabs.iter_mut() {
                    if tab.root.split_leaf(target, dir, pane.id) {
                        tab.active_pane = pane.id;
                        done = true;
                        break 'outer;
                    }
                }
            }
            if !done {
                state.panes.remove(&pane.id);
            }
        }
        if !done {
            pane.kill();
            anyhow::bail!("pane {target} not found");
        }
        self.emit(MuxEvent::TreeChanged);
        Ok(pane)
    }

    /// Remove a pane from the tree and kill its child. Cleans up empty
    /// tabs and workspaces.
    pub fn close_pane(&self, target: PaneId) {
        let mut removed = false;
        let empty;
        {
            let mut state = self.state.lock().unwrap();
            if let Some(pane) = state.panes.remove(&target) {
                pane.kill();
                removed = true;
            }
            for ws in state.workspaces.iter_mut() {
                let mut kept = Vec::with_capacity(ws.tabs.len());
                let mut removed_before_active = 0usize;
                for (i, mut tab) in std::mem::take(&mut ws.tabs).into_iter().enumerate() {
                    match std::mem::replace(&mut tab.root, Node::Leaf(0)).remove_leaf(target) {
                        Some(root) => {
                            tab.root = root;
                            if tab.active_pane == target {
                                let mut ids = Vec::new();
                                tab.root.pane_ids(&mut ids);
                                tab.active_pane = ids[0];
                            }
                            kept.push(tab);
                        }
                        None => {
                            if i < ws.active_tab {
                                removed_before_active += 1;
                            }
                        }
                    }
                }
                ws.tabs = kept;
                ws.active_tab = ws
                    .active_tab
                    .saturating_sub(removed_before_active)
                    .min(ws.tabs.len().saturating_sub(1));
            }
            let active_ws_id = state
                .workspaces
                .get(state.active_workspace)
                .map(|w| w.id);
            state.workspaces.retain(|w| !w.tabs.is_empty());
            state.active_workspace = active_ws_id
                .and_then(|id| state.workspaces.iter().position(|w| w.id == id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            empty = state.workspaces.is_empty();
        }
        if removed {
            self.emit(MuxEvent::TreeChanged);
        }
        if empty {
            self.emit(MuxEvent::Empty);
        }
    }

    pub fn pane_exited(&self, id: PaneId) {
        self.emit(MuxEvent::PaneExited(id));
    }

    /// Run `f` with the state tree.
    ///
    /// The state lock is held for the duration of `f`; do not call back
    /// into `Mux` methods that take it (`pane()`, `close_pane()`, ...).
    /// Use [`Mux::with_state`] when pane handles are needed alongside the
    /// tree.
    pub fn with_tree<R>(&self, f: impl FnOnce(&[Workspace], usize) -> R) -> R {
        let state = self.state.lock().unwrap();
        f(&state.workspaces, state.active_workspace)
    }

    /// Like [`Mux::with_tree`], but also exposes the pane map so callers
    /// can read titles/sizes without re-entering the state lock.
    pub fn with_state<R>(
        &self,
        f: impl FnOnce(&[Workspace], usize, &HashMap<PaneId, Arc<Pane>>) -> R,
    ) -> R {
        let state = self.state.lock().unwrap();
        f(&state.workspaces, state.active_workspace, &state.panes)
    }

    /// Run `f` with mutable access to the tree (focus changes, ratios).
    pub fn with_tree_mut<R>(&self, f: impl FnOnce(&mut Vec<Workspace>, &mut usize) -> R) -> R {
        let mut state = self.state.lock().unwrap();
        let state = &mut *state;
        f(&mut state.workspaces, &mut state.active_workspace)
    }

    pub fn pane_count(&self) -> usize {
        self.state.lock().unwrap().panes.len()
    }

    /// Make `pane` the active pane of whichever tab contains it (and make
    /// that tab/workspace active).
    pub fn focus_pane(&self, pane: PaneId) -> bool {
        let mut found = false;
        {
            let mut state = self.state.lock().unwrap();
            let mut target: Option<(usize, usize)> = None;
            for (wi, ws) in state.workspaces.iter().enumerate() {
                for (ti, tab) in ws.tabs.iter().enumerate() {
                    let mut ids = Vec::new();
                    tab.root.pane_ids(&mut ids);
                    if ids.contains(&pane) {
                        target = Some((wi, ti));
                    }
                }
            }
            if let Some((wi, ti)) = target {
                state.active_workspace = wi;
                state.workspaces[wi].active_tab = ti;
                state.workspaces[wi].tabs[ti].active_pane = pane;
                found = true;
            }
        }
        if found {
            self.emit(MuxEvent::TreeChanged);
        }
        found
    }

    /// Select a tab in the active workspace by index or relative delta.
    pub fn select_tab(&self, index: Option<usize>, delta: Option<isize>) {
        {
            let mut state = self.state.lock().unwrap();
            let active_ws = state.active_workspace;
            if let Some(ws) = state.workspaces.get_mut(active_ws) {
                let len = ws.tabs.len();
                if len == 0 {
                    return;
                }
                if let Some(index) = index {
                    if index < len {
                        ws.active_tab = index;
                    }
                } else if let Some(delta) = delta {
                    ws.active_tab =
                        ((ws.active_tab as isize + delta).rem_euclid(len as isize)) as usize;
                }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn test_mux() -> Arc<Mux> {
        let mut opts = PaneOptions::default();
        // A shell that stays alive without doing anything.
        opts.command = Some(vec!["/bin/cat".to_string()]);
        Mux::new("test", opts)
    }

    #[test]
    fn split_and_close_collapses_tree() {
        let mux = test_mux();
        let p1 = mux.new_workspace(None).unwrap();
        let p2 = mux.split(p1.id, SplitDir::Right).unwrap();
        let p3 = mux.split(p2.id, SplitDir::Down).unwrap();

        mux.with_tree(|ws, _| {
            let mut ids = Vec::new();
            ws[0].tabs[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1.id, p2.id, p3.id]);
        });

        mux.close_pane(p2.id);
        mux.with_tree(|ws, _| {
            let mut ids = Vec::new();
            ws[0].tabs[0].root.pane_ids(&mut ids);
            assert_eq!(ids, vec![p1.id, p3.id]);
        });

        mux.close_pane(p1.id);
        mux.close_pane(p3.id);
        assert_eq!(mux.pane_count(), 0);
        mux.with_tree(|ws, _| assert!(ws.is_empty()));
    }

    #[test]
    fn tabs_and_workspaces() {
        let mux = test_mux();
        let events = mux.subscribe();
        mux.new_workspace(None).unwrap();
        let t2 = mux.new_tab(None, None).unwrap();
        mux.new_workspace(Some("dev".into())).unwrap();

        mux.with_tree(|ws, active| {
            assert_eq!(ws.len(), 2);
            assert_eq!(ws[0].tabs.len(), 2);
            assert_eq!(ws[1].name, "dev");
            assert_eq!(active, 1);
        });

        // Tab close keeps the workspace.
        mux.close_pane(t2.id);
        mux.with_tree(|ws, _| assert_eq!(ws[0].tabs.len(), 1));
        assert!(events.try_iter().count() > 0);
    }
}
