//! The TUI's attention jump and list: `next-attention` (`Ctrl-b a`) focuses
//! the next tab that needs the person, `attention-list` (`Ctrl-b A`) opens a
//! searchable list of them. Both read the queue order of `crate::attention`
//! from this client's tree and agent roster, on the key press only (never per
//! frame), and focus through the sidebar's tab activation, so the jump
//! reports client focus and acknowledges the tab like any user focus change.

use cmux_tui_core::SurfaceId;

use super::{App, ContextMenu, MenuAction, MenuItem, SidebarTabTarget};
use crate::attention::{
    AttentionCandidate, AttentionKind, AttentionLevel, attention_queue, next_attention,
};
use crate::localization;
use crate::session::{AgentInfo, TreeView};

/// One queue entry with what the list shows for it.
pub(crate) struct AttentionEntry {
    pub candidate: AttentionCandidate<SurfaceId>,
    pub workspace: String,
    pub tab: String,
}

/// The tabs of `tree` that need the person, in queue order. `agents` is the
/// roster; only `blocked` agents count.
pub(crate) fn tree_attention_entries(tree: &TreeView, agents: &[AgentInfo]) -> Vec<AttentionEntry> {
    let mut candidates = Vec::new();
    let mut labels = std::collections::HashMap::new();
    let mut position = 0usize;
    for workspace in tree.workspaces() {
        for screen in &workspace.screens {
            for pane in &screen.panes {
                for tab in &pane.tabs {
                    position = position.saturating_add(1);
                    if let Some(notification) = tab.notification.filter(|marker| marker.unread) {
                        candidates.push(AttentionCandidate {
                            key: tab.surface,
                            kind: AttentionKind::Unread,
                            level: AttentionLevel::parse(notification.level),
                            age: notification.sequence,
                            position,
                        });
                    }
                    let name = tab.name.as_deref().filter(|name| !name.is_empty());
                    let title = if tab.title.is_empty() { "shell" } else { tab.title.as_str() };
                    labels.insert(
                        tab.surface,
                        (workspace.name.clone(), name.unwrap_or(title).to_string(), position),
                    );
                }
            }
        }
    }
    for agent in agents.iter().filter(|agent| agent.state == "blocked") {
        if let Some((_, _, position)) = labels.get(&agent.surface) {
            candidates.push(AttentionCandidate {
                key: agent.surface,
                kind: AttentionKind::Blocked,
                level: AttentionLevel::Warning,
                age: agent.updated_at_ms,
                position: *position,
            });
        }
    }
    attention_queue(candidates)
        .into_iter()
        .filter_map(|candidate| {
            let (workspace, tab, _) = labels.get(&candidate.key)?.clone();
            Some(AttentionEntry { candidate, workspace, tab })
        })
        .collect()
}

impl App {
    fn attention_entries(&self) -> Vec<AttentionEntry> {
        tree_attention_entries(&self.tree, &self.session.agents())
    }

    /// `next-attention`: focus the tab after the focused one in the queue,
    /// or the first. A toast says so when nothing needs the person.
    pub(super) fn jump_to_next_attention(&mut self) -> anyhow::Result<()> {
        let queue: Vec<_> =
            self.attention_entries().into_iter().map(|entry| entry.candidate).collect();
        let current = self.active_surface();
        let Some(target) = next_attention(&queue, current.as_ref()).map(|entry| entry.key) else {
            self.show_toast(localization::catalog().attention.nothing.to_string());
            return Ok(());
        };
        self.focus_attention_surface(target)
    }

    /// `attention-list`: a searchable list of the queue; Enter focuses the
    /// row's tab.
    pub(super) fn open_attention_list(&mut self) {
        let entries = self.attention_entries();
        let messages = &localization::catalog().attention;
        if entries.is_empty() {
            self.show_toast(messages.nothing.to_string());
            return;
        }
        let items = entries
            .iter()
            .map(|entry| MenuItem::LabeledAction {
                label: attention_row_label(entry),
                action: MenuAction::FocusAttention(entry.candidate.key),
            })
            .collect::<Vec<_>>();
        let area = self.content_area;
        let x = area.x.saturating_add(area.width / 4).max(1);
        let y = area.y.saturating_add(2).max(1);
        self.menu = Some(ContextMenu::searchable(
            x,
            y,
            messages.list_title,
            messages.filter_placeholder,
            items,
            Vec::new(),
        ));
        self.capture_menu_resources();
    }

    /// Focus `surface` the way a sidebar tab click does. A tab that left
    /// the tree since the queue was read gets a toast instead.
    pub(super) fn focus_attention_surface(&mut self, surface: SurfaceId) -> anyhow::Result<()> {
        let location = self.tree.workspaces().iter().enumerate().find_map(|(w, workspace)| {
            workspace.screens.iter().enumerate().find_map(|(s, screen)| {
                screen.panes.iter().find_map(|pane| {
                    let index = pane.tabs.iter().position(|tab| tab.surface == surface)?;
                    Some((w, s, pane.id, index))
                })
            })
        });
        let Some((workspace, screen, pane, index)) = location else {
            self.show_toast(localization::catalog().attention.gone.to_string());
            return Ok(());
        };
        self.activate_sidebar_tab(&SidebarTabTarget {
            workspace,
            screen,
            pane,
            index,
            surface,
            name: String::new(),
            subtitle: String::new(),
            active: false,
        })
    }
}

/// `! work › claude · waiting on you`: the marker (`!` the person must act,
/// `•` unread), the workspace, the tab, and why.
fn attention_row_label(entry: &AttentionEntry) -> String {
    let messages = &localization::catalog().attention;
    let (marker, detail) = match entry.candidate.kind {
        AttentionKind::Blocked => ("!", messages.blocked),
        AttentionKind::Unread => ("•", messages.unread),
    };
    let label = format!("{marker} {} › {} · {detail}", entry.workspace, entry.tab);
    crate::ui::truncate(&label, 72)
}
