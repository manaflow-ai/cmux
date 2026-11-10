//! Client view preservation: the client focus identity and carrying client
//! view state (active tabs, zoom, focus) from the previous tree to the next.

use std::collections::HashMap;
use std::hash::Hash;

use crate::session::TreeView;
use crate::session::tree::{PaneView, WorkspaceView};

/// A durable random id naming this client install for per-client focus
/// memory on the mux (client-focus-v1). Stored next to the TUI config;
/// created on first use.
pub(super) fn client_focus_identity() -> Option<String> {
    let path = crate::config::config_path().ok()?.parent()?.join("client-id");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim();
        if !existing.is_empty()
            && existing.len() <= 128
            && existing.bytes().all(|byte| byte.is_ascii_graphic())
        {
            return Some(existing.to_string());
        }
    }
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).ok()?;
    let mut id = String::with_capacity(39);
    id.push_str("client-");
    use std::fmt::Write as _;
    for byte in bytes {
        write!(&mut id, "{byte:02x}").ok()?;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::fs::write(&path, format!("{id}\n")).ok()?;
    Some(id)
}

/// Where a new tree lists the objects of the previous one. An object is
/// found by its public id (`ws_…`, `screen_…`, `pane_…`, `tab_…`) when the
/// previous view has one: a restarted daemon gives every object a new
/// numeric id but keeps its public id (bench round 5, W6-A: after `daemon
/// restart` the TUI lost the tab the person looked at). Without a public id
/// (an older daemon) the numeric id finds it, as before.
struct ViewIndex<P> {
    public: HashMap<P, usize>,
    numeric: HashMap<u64, usize>,
}

impl<P: Eq + Hash + Clone> ViewIndex<P> {
    fn of<T>(items: &[T], key: impl Fn(&T) -> (u64, Option<&P>)) -> Self {
        let mut index = Self { public: HashMap::new(), numeric: HashMap::new() };
        for (position, item) in items.iter().enumerate() {
            let (numeric, public) = key(item);
            if let Some(public) = public {
                index.public.entry(public.clone()).or_insert(position);
            }
            index.numeric.entry(numeric).or_insert(position);
        }
        index
    }

    fn find(&self, numeric: u64, public: Option<&P>) -> Option<usize> {
        match public {
            Some(public) if !self.public.is_empty() => self.public.get(public).copied(),
            _ => self.numeric.get(&numeric).copied(),
        }
    }
}

pub(super) fn preserve_client_view(previous: &TreeView, next: &mut TreeView) {
    let workspace_index = ViewIndex::of(next.workspaces(), |workspace| {
        (workspace.id, workspace.resource_id.as_ref())
    });
    let find_workspace = |workspace: &WorkspaceView| {
        workspace_index.find(workspace.id, workspace.resource_id.as_ref())
    };
    if let Some(index) = previous.active_workspace().and_then(find_workspace) {
        next.active_workspace = index;
    }

    let mut screen_updates = Vec::new();
    let mut pane_updates = Vec::new();
    let mut tab_updates = Vec::new();
    for previous_workspace in previous.workspaces() {
        let Some(next_workspace_index) = find_workspace(previous_workspace) else {
            continue;
        };
        let Some(next_workspace) = next.workspaces().get(next_workspace_index) else {
            continue;
        };
        let screen_index = ViewIndex::of(&next_workspace.screens, |screen| {
            (screen.id, screen.resource_id.as_ref())
        });
        if let Some(index) = previous_workspace
            .screens
            .get(previous_workspace.active_screen)
            .and_then(|screen| screen_index.find(screen.id, screen.resource_id.as_ref()))
        {
            screen_updates.push((next_workspace_index, index));
        }

        for previous_screen in &previous_workspace.screens {
            let Some(next_screen_index) =
                screen_index.find(previous_screen.id, previous_screen.resource_id.as_ref())
            else {
                continue;
            };
            let Some(next_screen) = next_workspace.screens.get(next_screen_index) else {
                continue;
            };
            let pane_index =
                ViewIndex::of(&next_screen.panes, |pane| (pane.id, pane.resource_id.as_ref()));
            let find_pane = |pane: &PaneView| pane_index.find(pane.id, pane.resource_id.as_ref());
            let previous_active =
                previous_screen.panes.iter().find(|pane| pane.id == previous_screen.active_pane);
            let zoomed = next_screen
                .zoomed_pane
                .filter(|zoomed| next_screen.panes.iter().any(|pane| pane.id == *zoomed));
            if let Some(zoomed) = zoomed {
                pane_updates.push((next_workspace_index, next_screen_index, zoomed));
            } else if next_screen.zoomed_pane.is_none()
                && let Some(pane) = previous_active
                    .and_then(find_pane)
                    .and_then(|index| next_screen.panes.get(index))
            {
                pane_updates.push((next_workspace_index, next_screen_index, pane.id));
            }

            for previous_pane in &previous_screen.panes {
                let Some(next_pane) =
                    find_pane(previous_pane).and_then(|index| next_screen.panes.get(index))
                else {
                    continue;
                };
                let tab_index =
                    ViewIndex::of(&next_pane.tabs, |tab| (tab.surface, tab.public_id.as_ref()));
                if let Some(index) = previous_pane
                    .tabs
                    .get(previous_pane.active_tab)
                    .and_then(|tab| tab_index.find(tab.surface, tab.public_id.as_ref()))
                {
                    tab_updates.push((
                        next_workspace_index,
                        next_screen_index,
                        next_pane.id,
                        index,
                    ));
                }
            }
        }
    }
    for (workspace_index, screen_index) in screen_updates {
        next.set_active_screen(workspace_index, screen_index);
    }
    for (workspace_index, screen_index, pane_id) in pane_updates {
        next.set_active_pane(workspace_index, screen_index, pane_id);
    }
    for (workspace_index, screen_index, pane_id, tab_index) in tab_updates {
        next.set_active_tab(workspace_index, screen_index, pane_id, tab_index);
    }
}
