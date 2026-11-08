//! The TUI's attention jump and list: `next-attention` (`Ctrl-b a`) focuses
//! the next tab that needs the person, `attention-list` (`Ctrl-b A`) opens a
//! searchable list of them. Both read the queue order of `crate::attention`
//! from this client's tree and agent roster, on the key press only (never per
//! frame), and focus through the sidebar's tab activation, so the jump
//! reports client focus and acknowledges the tab like any user focus change.

use cmux_tui_core::SurfaceId;
use ghostty_vt::ProgramStatusState;

use crate::app::layout::SidebarTabTarget;
use crate::app::menu::MenuItem;
use crate::app::menu::context_menu::ContextMenu;
use crate::app::{App, MenuAction};
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
    /// The agent's reason for a requested tab.
    pub reason: Option<String>,
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
                    let mut push = |kind, level, age| {
                        candidates.push(AttentionCandidate {
                            key: tab.surface,
                            kind,
                            level,
                            age,
                            position,
                        });
                    };
                    if let Some(attention) = &tab.attention {
                        push(AttentionKind::Requested, AttentionLevel::Warning, attention.at_ms);
                    }
                    if tab
                        .program_status
                        .is_some_and(|status| status.state == ProgramStatusState::Blocked)
                    {
                        push(AttentionKind::Blocked, AttentionLevel::Warning, u64::MAX);
                    }
                    if let Some(notification) = tab.notification.filter(|marker| marker.unread) {
                        push(
                            AttentionKind::Unread,
                            AttentionLevel::parse(notification.level),
                            notification.sequence,
                        );
                    }
                    let name = tab.name.as_deref().filter(|name| !name.is_empty());
                    let title = if tab.title.is_empty() { "shell" } else { tab.title.as_str() };
                    labels.insert(
                        tab.surface,
                        (
                            workspace.name.clone(),
                            name.unwrap_or(title).to_string(),
                            tab.attention.as_ref().map(|mark| mark.reason.to_string()),
                            position,
                        ),
                    );
                }
            }
        }
    }
    for agent in agents.iter().filter(|agent| agent.state == "blocked") {
        if let Some((_, _, _, position)) = labels.get(&agent.surface) {
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
            let (workspace, tab, reason, _) = labels.get(&candidate.key)?.clone();
            Some(AttentionEntry { candidate, workspace, tab, reason })
        })
        .collect()
}

impl App {
    fn attention_entries(&self) -> Vec<AttentionEntry> {
        tree_attention_entries(&self.tree, &self.session.agents())
    }

    /// `next-attention`: focus the tab after the focused one in the queue,
    /// or the first. A toast says so when nothing needs the person, and
    /// shows the agent's reason when the jump lands on a requested tab.
    pub(super) fn jump_to_next_attention(&mut self) -> anyhow::Result<()> {
        let entries = self.attention_entries();
        let queue: Vec<_> = entries.iter().map(|entry| entry.candidate.clone()).collect();
        let current = self.active_surface();
        let Some(target) = next_attention(&queue, current.as_ref()).map(|entry| entry.key) else {
            self.show_toast(localization::catalog().attention.nothing.to_string());
            return Ok(());
        };
        let reason = entries
            .iter()
            .find(|entry| entry.candidate.key == target)
            .and_then(|entry| entry.reason.clone());
        self.focus_attention_surface(target)?;
        if let Some(reason) = reason {
            self.show_toast(format!("{}: {reason}", localization::catalog().attention.needs_you));
        }
        Ok(())
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
    /// the tree since the queue was read is skipped.
    pub(super) fn focus_attention_surface(&mut self, surface: SurfaceId) -> anyhow::Result<()> {
        let location = self.tree.workspaces().iter().enumerate().find_map(|(w, workspace)| {
            workspace.screens.iter().enumerate().find_map(|(s, screen)| {
                screen.panes.iter().find_map(|pane| {
                    let index = pane.tabs.iter().position(|tab| tab.surface == surface)?;
                    Some((w, s, pane.id, index))
                })
            })
        });
        let Some((workspace, screen, pane, index)) = location else { return Ok(()) };
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

/// `! work › claude · needs you: approve deploy`: the marker (`!` the person
/// must act, `•` unread), the workspace, the tab, and why.
fn attention_row_label(entry: &AttentionEntry) -> String {
    let messages = &localization::catalog().attention;
    let (marker, detail) = match entry.candidate.kind {
        AttentionKind::Requested => (
            "!",
            match &entry.reason {
                Some(reason) => format!("{}: {reason}", messages.requested),
                None => messages.requested.to_string(),
            },
        ),
        AttentionKind::Blocked => ("!", messages.blocked.to_string()),
        AttentionKind::Unread | AttentionKind::Done => ("•", messages.unread.to_string()),
    };
    let label = format!("{marker} {} › {} · {detail}", entry.workspace, entry.tab);
    crate::ui::truncate(&label, 72)
}
