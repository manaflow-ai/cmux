//! Client view preservation: the client focus identity and carrying client
//! view state (active tabs, zoom, focus) from the previous tree to the next.

use std::collections::HashMap;

use crate::session::TreeView;

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

pub(super) fn preserve_client_view(previous: &TreeView, next: &mut TreeView) {
    let workspace_indices = next
        .workspaces()
        .iter()
        .enumerate()
        .map(|(index, workspace)| (workspace.id, index))
        .collect::<HashMap<_, _>>();
    if let Some(active) = previous.active_workspace().map(|workspace| workspace.id)
        && let Some(index) = workspace_indices.get(&active).copied()
    {
        next.active_workspace = index;
    }

    let mut screen_updates = Vec::new();
    let mut pane_updates = Vec::new();
    let mut tab_updates = Vec::new();
    for previous_workspace in previous.workspaces() {
        let Some(next_workspace_index) = workspace_indices.get(&previous_workspace.id).copied()
        else {
            continue;
        };
        let Some(screen_indices) = next.workspaces().get(next_workspace_index).map(|workspace| {
            workspace
                .screens
                .iter()
                .enumerate()
                .map(|(index, screen)| (screen.id, index))
                .collect::<HashMap<_, _>>()
        }) else {
            continue;
        };
        if let Some(active) =
            previous_workspace.screens.get(previous_workspace.active_screen).map(|screen| screen.id)
            && let Some(index) = screen_indices.get(&active).copied()
        {
            screen_updates.push((next_workspace_index, index));
        }

        for previous_screen in &previous_workspace.screens {
            let Some(next_screen_index) = screen_indices.get(&previous_screen.id).copied() else {
                continue;
            };
            let Some((zoomed_pane, pane_indices)) = next
                .workspaces()
                .get(next_workspace_index)
                .and_then(|workspace| workspace.screens.get(next_screen_index))
                .map(|screen| {
                    (
                        screen.zoomed_pane,
                        screen
                            .panes
                            .iter()
                            .enumerate()
                            .map(|(index, pane)| (pane.id, index))
                            .collect::<HashMap<_, _>>(),
                    )
                })
            else {
                continue;
            };
            if let Some(zoomed_pane) =
                zoomed_pane.filter(|zoomed| pane_indices.contains_key(zoomed))
            {
                pane_updates.push((next_workspace_index, next_screen_index, zoomed_pane));
            } else if zoomed_pane.is_none()
                && pane_indices.contains_key(&previous_screen.active_pane)
            {
                pane_updates.push((
                    next_workspace_index,
                    next_screen_index,
                    previous_screen.active_pane,
                ));
            }

            for previous_pane in &previous_screen.panes {
                let Some(next_pane_index) = pane_indices.get(&previous_pane.id).copied() else {
                    continue;
                };
                let Some((pane_id, tab_indices)) = next
                    .workspaces()
                    .get(next_workspace_index)
                    .and_then(|workspace| workspace.screens.get(next_screen_index))
                    .and_then(|screen| screen.panes.get(next_pane_index))
                    .map(|pane| {
                        (
                            pane.id,
                            pane.tabs
                                .iter()
                                .enumerate()
                                .map(|(index, tab)| (tab.surface, index))
                                .collect::<HashMap<_, _>>(),
                        )
                    })
                else {
                    continue;
                };
                if let Some(active) = previous_pane.active_surface()
                    && let Some(index) = tab_indices.get(&active).copied()
                {
                    tab_updates.push((next_workspace_index, next_screen_index, pane_id, index));
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
