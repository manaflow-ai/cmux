//! Agent status for the default sidebar and the tab chips: each agent tab's
//! status, each workspace's rolled-up status and second rail line, and the
//! cross-workspace agents section in attention order.
//!
//! The index is a pure function of one tree snapshot and the agent roster.
//! The app rebuilds it with the tree on a `Draw` (layout) frame and only
//! reads it on `Paint` frames, so typing never rebuilds it.
//!
//! Status words and the done-until-seen rule are [`AgentStatus`]'s: an idle
//! agent whose tab still shows the daemon's unread marker is `done`.

use std::collections::HashMap;

use cmux_tui_core::{AgentStatus, PaneId, SurfaceId, WorkspaceId};

use crate::localization;
use crate::session::{AgentInfo, TreeView};
use crate::sidebar_projection::ProjectionTarget;

/// What the default sidebar and tab chips show about agents.
#[derive(Debug, Default)]
pub(crate) struct SidebarStatus {
    tabs: HashMap<SurfaceId, AgentStatus>,
    workspaces: Vec<WorkspaceStatus>,
    agents: Vec<AgentRow>,
}

/// One workspace row's agent rollup and second line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkspaceStatus {
    /// The workspace this entry describes, so a renderer never pairs it
    /// with another workspace after a reorder it has not rebuilt for yet.
    pub id: WorkspaceId,
    /// The most urgent status of the workspace's agents; `None` without one.
    pub status: Option<AgentStatus>,
    /// `active pane title (N screens)`; the screen count only with more
    /// than one screen.
    pub subtitle: String,
}

/// One agent of the agents section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentRow {
    pub surface: SurfaceId,
    pub status: AgentStatus,
    /// Where the agent's tab is; a click or Enter focuses it.
    pub target: ProjectionTarget,
    /// The row's first line: the tab name, its title without a leading
    /// spinner glyph, or the agent's adapter id.
    pub label: String,
    /// The row's second line: localized status and workspace name.
    pub detail: String,
}

impl SidebarStatus {
    /// Build the index for `tree` and `agents` (the roster as the session
    /// lists it; ended sessions are skipped).
    pub(crate) fn build(tree: &TreeView, agents: &[AgentInfo]) -> Self {
        let messages = &localization::catalog().sidebar;
        let by_surface: HashMap<SurfaceId, &AgentInfo> =
            agents.iter().map(|agent| (agent.surface, agent)).collect();
        let mut tabs = HashMap::with_capacity(agents.len());
        let mut workspaces = Vec::with_capacity(tree.workspaces().len());
        // (rank, updated_at_ms, tree order) sorts the agents section.
        let mut ranked: Vec<(u8, u64, usize, AgentRow)> = Vec::with_capacity(agents.len());
        for (workspace_index, workspace) in tree.workspaces().iter().enumerate() {
            let mut rollup: Option<AgentStatus> = None;
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                for pane in &screen.panes {
                    for (tab_index, tab) in pane.tabs.iter().enumerate() {
                        let Some(agent) = by_surface.get(&tab.surface) else { continue };
                        let unseen = tab.notification.is_some_and(|marker| marker.unread);
                        let Some(status) = AgentStatus::from_state_str(&agent.state, unseen) else {
                            continue;
                        };
                        if tabs.insert(tab.surface, status).is_some() {
                            continue;
                        }
                        rollup = AgentStatus::rollup(rollup.into_iter().chain([status]));
                        let label = agent_label(
                            tab.name.as_deref(),
                            &tab.title,
                            agent.agent.as_deref(),
                            &tab.short_id,
                        );
                        let detail = format!("{} · {}", status_label(status), workspace.name);
                        ranked.push((
                            status.rank(),
                            agent.updated_at_ms,
                            ranked.len(),
                            AgentRow {
                                surface: tab.surface,
                                status,
                                target: surface_target(
                                    workspace_index,
                                    screen_index,
                                    pane.id,
                                    tab_index,
                                    tab.surface,
                                ),
                                label: label.to_string(),
                                detail,
                            },
                        ));
                    }
                }
            }
            workspaces.push(WorkspaceStatus {
                id: workspace.id,
                status: rollup,
                subtitle: workspace_subtitle(workspace, messages.screens_count),
            });
        }
        // Blocked first, then done, working, idle, unknown; inside a status
        // the most recent change first; ties keep tree order.
        ranked.sort_by(|left, right| {
            right.0.cmp(&left.0).then(right.1.cmp(&left.1)).then(left.2.cmp(&right.2))
        });
        let agents = ranked.into_iter().map(|(_, _, _, row)| row).collect();
        Self { tabs, workspaces, agents }
    }

    /// The status of the agent in tab `surface`, if one runs there.
    pub(crate) fn tab(&self, surface: SurfaceId) -> Option<AgentStatus> {
        self.tabs.get(&surface).copied()
    }

    /// The workspace at tree index `index`.
    pub(crate) fn workspace(&self, index: usize) -> Option<&WorkspaceStatus> {
        self.workspaces.get(index)
    }

    /// Every agent, most urgent first.
    pub(crate) fn agents(&self) -> &[AgentRow] {
        &self.agents
    }
}

fn surface_target(
    workspace: usize,
    screen: usize,
    pane: PaneId,
    index: usize,
    surface: SurfaceId,
) -> ProjectionTarget {
    ProjectionTarget::Surface { workspace, screen, pane, index, surface, agent: true }
}

/// The localized status word.
pub(crate) fn status_label(status: AgentStatus) -> &'static str {
    let messages = &localization::catalog().sidebar;
    match status {
        AgentStatus::Blocked => messages.blocked,
        AgentStatus::Done => messages.done,
        AgentStatus::Working => messages.working,
        AgentStatus::Idle => messages.idle,
        AgentStatus::Unknown => messages.unknown,
    }
}

/// The glyph a status shows in the sidebar and on tab chips. Each status
/// has its own shape, so the state reads without color.
pub(crate) fn status_glyph(status: AgentStatus) -> &'static str {
    match status {
        AgentStatus::Blocked => "!",
        AgentStatus::Done => "✓",
        AgentStatus::Working => "●",
        AgentStatus::Idle => "○",
        AgentStatus::Unknown => "·",
    }
}

/// The tab name, else its title without a leading spinner or status glyph
/// (Claude Code titles its terminal `✳ Task` or `⠂ Task`), else the agent's
/// adapter id, else the tab's short id.
fn agent_label<'a>(
    name: Option<&'a str>,
    title: &'a str,
    agent: Option<&'a str>,
    short_id: &'a str,
) -> &'a str {
    if let Some(name) = name.filter(|name| !name.is_empty()) {
        return name;
    }
    let title = strip_title_glyph(title);
    if !title.is_empty() {
        return title;
    }
    agent.filter(|agent| !agent.is_empty()).unwrap_or(short_id)
}

fn strip_title_glyph(title: &str) -> &str {
    let title = title.trim();
    let mut chars = title.chars();
    match chars.next() {
        Some(first)
            if ('\u{2800}'..='\u{28ff}').contains(&first)
                || matches!(first, '✳' | '✻' | '✽' | '✶' | '✢' | '·' | '*' | '●' | '○') =>
        {
            chars.as_str().trim_start()
        }
        _ => title,
    }
}

fn workspace_subtitle(workspace: &crate::session::WorkspaceView, screens_count: &str) -> String {
    let screen = workspace.active_screen_ref();
    let pane = screen.and_then(|screen| screen.pane(screen.active_pane));
    let mut subtitle =
        strip_title_glyph(pane.map(|pane| pane.display_name()).unwrap_or("shell")).to_string();
    if workspace.screens.len() > 1 {
        subtitle.push(' ');
        subtitle.push_str(&screens_count.replace("{count}", &workspace.screens.len().to_string()));
    }
    subtitle
}

#[cfg(test)]
#[path = "sidebar_status_tests.rs"]
mod tests;
