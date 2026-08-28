//! Pure projection of mux resources into configurable native sidebar trees.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::{PaneId, SurfaceId, WorkspaceId};

use crate::config::{SidebarResourceKind, SidebarViewScope, SidebarViewSpec};
use crate::session::{AgentInfo, TreeView};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum ProjectionBranch {
    Workspace(WorkspaceId),
    Pane { workspace: WorkspaceId, pane: PaneId },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ProjectionTarget {
    Workspace {
        index: usize,
        id: WorkspaceId,
    },
    Pane {
        workspace: usize,
        screen: usize,
        pane: PaneId,
    },
    Surface {
        workspace: usize,
        screen: usize,
        pane: PaneId,
        index: usize,
        surface: SurfaceId,
        agent: bool,
    },
}

impl ProjectionTarget {
    /// Compare the projected resource identity while ignoring positions that
    /// can change when a fresh tree snapshot is rebuilt.
    pub(crate) fn same_resource(self, other: Self) -> bool {
        match (self, other) {
            (Self::Workspace { id: left, .. }, Self::Workspace { id: right, .. }) => left == right,
            (Self::Pane { pane: left, .. }, Self::Pane { pane: right, .. }) => left == right,
            (
                Self::Surface { surface: left, agent: left_agent, .. },
                Self::Surface { surface: right, agent: right_agent, .. },
            ) => left == right && left_agent == right_agent,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProjectionRow {
    pub resource: SidebarResourceKind,
    pub depth: u16,
    pub name: String,
    pub subtitle: String,
    pub agent_state: Option<String>,
    pub agent_label: Option<String>,
    pub active: bool,
    pub branch: Option<ProjectionBranch>,
    pub expanded: bool,
    pub target: ProjectionTarget,
}

#[derive(Debug, Clone)]
pub(crate) struct ProjectionRailState {
    /// Selected resource-row index. Action selection is tracked separately so
    /// live resource insertions cannot retarget a pinned action.
    pub selected: usize,
    /// Stable resource identity for preserving selection when rows reorder.
    pub selected_target: Option<ProjectionTarget>,
    pub selected_action: Option<usize>,
    pub scroll: usize,
    pub footer_scroll: usize,
    pub follow_selection: bool,
    pub collapsed: HashSet<ProjectionBranch>,
}

impl Default for ProjectionRailState {
    fn default() -> Self {
        Self {
            selected: 0,
            selected_target: None,
            selected_action: None,
            scroll: 0,
            footer_scroll: 0,
            follow_selection: true,
            collapsed: HashSet::new(),
        }
    }
}

impl ProjectionRailState {
    pub(crate) fn reconcile_selection(&mut self, rows: &[ProjectionRow]) {
        if rows.is_empty() {
            self.selected = 0;
            self.selected_target = None;
            return;
        }
        if let Some(target) = self.selected_target
            && let Some((index, row)) =
                rows.iter().enumerate().find(|(_, row)| row.target.same_resource(target))
        {
            self.selected = index;
            self.selected_target = Some(row.target);
            return;
        }
        self.selected = self.selected.min(rows.len().saturating_sub(1));
        self.selected_target = rows.get(self.selected).map(|row| row.target);
    }
}

/// Return the workspace-selection component that can affect this projection.
/// Flat all-scoped tab/agent views enumerate every workspace themselves, and
/// workspace rows do the same. Keeping those views independent of the current
/// highlight lets their snapshots survive a highlight-only move.
pub(crate) fn selected_workspace_cache_key(
    spec: &SidebarViewSpec,
    selected_workspace: usize,
) -> Option<usize> {
    match spec.levels.first().copied() {
        Some(SidebarResourceKind::Panes) => Some(selected_workspace),
        Some(SidebarResourceKind::Tabs | SidebarResourceKind::Agents)
            if spec.scope != SidebarViewScope::All =>
        {
            Some(selected_workspace)
        }
        _ => None,
    }
}

#[derive(Clone, Copy)]
struct ProjectionContext {
    workspace: usize,
    screen: Option<usize>,
    pane: Option<PaneId>,
}

/// Surfaces whose CURRENT idle state the user has already looked at. Seen
/// is per-client presentation state (derived from this client's focus
/// history), never journal state: two attached clients can rank the same
/// idle agent differently, which is correct for a per-viewer property.
pub(crate) type SeenIdleSurfaces = HashSet<SurfaceId>;

pub(crate) fn rows(
    spec: &SidebarViewSpec,
    tree: &TreeView,
    agents: &[AgentInfo],
    seen_idle: &SeenIdleSurfaces,
    selected_workspace: usize,
    collapsed: &HashSet<ProjectionBranch>,
) -> Vec<ProjectionRow> {
    // Workspace rows are the common projection and can reach roughly 1000
    // entries. Reserve that baseline up front so a render does not repeatedly
    // grow and copy the backing buffer while appending the tree.
    let mut rows = Vec::with_capacity(tree.workspaces.len());
    let agents_by_surface: HashMap<SurfaceId, &AgentInfo> =
        agents.iter().map(|agent| (agent.surface, agent)).collect();
    append_level(
        &mut rows,
        &spec.levels,
        spec.scope,
        0,
        None,
        tree,
        &agents_by_surface,
        seen_idle,
        selected_workspace.min(tree.workspaces.len().saturating_sub(1)),
        collapsed,
    );
    rows
}

/// herdr's agent priority order: a blocked agent waits on a human, an idle
/// agent the user has not looked at yet carries unreviewed output, a working
/// agent is in flight, and a seen idle agent is at rest.
fn agent_priority(state: &str, seen: bool) -> u8 {
    match state {
        "blocked" => 4,
        "idle" if !seen => 3,
        "working" => 2,
        "idle" => 1,
        _ => 0,
    }
}

#[allow(clippy::too_many_arguments)]
fn append_level(
    output: &mut Vec<ProjectionRow>,
    levels: &[SidebarResourceKind],
    scope: SidebarViewScope,
    depth: usize,
    context: Option<ProjectionContext>,
    tree: &TreeView,
    agents: &HashMap<SurfaceId, &AgentInfo>,
    seen_idle: &SeenIdleSurfaces,
    selected_workspace: usize,
    collapsed: &HashSet<ProjectionBranch>,
) {
    let Some(resource) = levels.get(depth).copied() else { return };
    let has_children = depth + 1 < levels.len();
    match resource {
        SidebarResourceKind::Machines => {}
        SidebarResourceKind::Workspaces => {
            for (workspace_index, workspace) in tree.workspaces.iter().enumerate() {
                let branch = has_children.then_some(ProjectionBranch::Workspace(workspace.id));
                let expanded = branch.is_none_or(|branch| !collapsed.contains(&branch));
                output.push(ProjectionRow {
                    resource,
                    depth: depth as u16,
                    name: workspace.name.clone(),
                    subtitle: workspace.short_id.clone(),
                    agent_state: None,
                    agent_label: None,
                    active: workspace_index == tree.active_workspace,
                    branch,
                    expanded,
                    target: ProjectionTarget::Workspace {
                        index: workspace_index,
                        id: workspace.id,
                    },
                });
                if has_children && expanded {
                    append_level(
                        output,
                        levels,
                        scope,
                        depth + 1,
                        Some(ProjectionContext {
                            workspace: workspace_index,
                            screen: None,
                            pane: None,
                        }),
                        tree,
                        agents,
                        seen_idle,
                        selected_workspace,
                        collapsed,
                    );
                }
            }
        }
        SidebarResourceKind::Panes => {
            let workspace_index = context.map_or(selected_workspace, |context| context.workspace);
            let Some(workspace) = tree.workspaces.get(workspace_index) else { return };
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                for pane in &screen.panes {
                    if context.is_some_and(|context| {
                        context.screen.is_some_and(|candidate| candidate != screen_index)
                            || context.pane.is_some_and(|candidate| candidate != pane.id)
                    }) {
                        continue;
                    }
                    let branch = has_children.then_some(ProjectionBranch::Pane {
                        workspace: workspace.id,
                        pane: pane.id,
                    });
                    let expanded = branch.is_none_or(|branch| !collapsed.contains(&branch));
                    output.push(ProjectionRow {
                        resource,
                        depth: depth as u16,
                        name: pane.display_name().to_string(),
                        subtitle: pane.short_id.clone(),
                        agent_state: None,
                        agent_label: None,
                        active: workspace_index == tree.active_workspace
                            && screen_index == workspace.active_screen
                            && pane.id == screen.active_pane,
                        branch,
                        expanded,
                        target: ProjectionTarget::Pane {
                            workspace: workspace_index,
                            screen: screen_index,
                            pane: pane.id,
                        },
                    });
                    if has_children && expanded {
                        append_level(
                            output,
                            levels,
                            scope,
                            depth + 1,
                            Some(ProjectionContext {
                                workspace: workspace_index,
                                screen: Some(screen_index),
                                pane: Some(pane.id),
                            }),
                            tree,
                            agents,
                            seen_idle,
                            selected_workspace,
                            collapsed,
                        );
                    }
                }
            }
        }
        SidebarResourceKind::Tabs | SidebarResourceKind::Agents => {
            let agent_only = resource == SidebarResourceKind::Agents;
            // A flat `all`-scoped view sweeps every workspace; the historical
            // behavior scopes the flat view to the selected workspace and a
            // nested view to its parent context.
            let all_workspaces = context.is_none() && scope == SidebarViewScope::All;
            let workspace_indices: Vec<usize> = if all_workspaces {
                (0..tree.workspaces.len()).collect()
            } else {
                vec![context.map_or(selected_workspace, |context| context.workspace)]
            };
            // Complexity note: this is the only O(A log A) projection path,
            // where A is the agent-row count of the view. Every other path
            // appends in O(A). The ignored 1000-workspace fixture below is
            // the measurement hook for this intentional tradeoff, without
            // claiming a local timing.
            //
            // Agents views sort by herdr's priority order (blocked >
            // idle-unseen > working > idle-seen > unknown), most recent
            // state change first inside a bucket; the tree-order index
            // breaks exact ties. `u8::MAX - ...` / `u64::MAX - ...` invert
            // so one ascending sort produces descending buckets.
            let mut entries: Vec<((u8, u64, usize), ProjectionRow)> = Vec::new();
            for workspace_index in workspace_indices {
                let Some(workspace) = tree.workspaces.get(workspace_index) else { continue };
                for (screen_index, screen) in workspace.screens.iter().enumerate() {
                    if context.is_some_and(|context| {
                        context.screen.is_some_and(|candidate| candidate != screen_index)
                    }) {
                        continue;
                    }
                    for pane in &screen.panes {
                        if context.is_some_and(|context| {
                            context.pane.is_some_and(|candidate| candidate != pane.id)
                        }) {
                            continue;
                        }
                        for (tab_index, tab) in pane.tabs.iter().enumerate() {
                            let agent = agents.get(&tab.surface).copied();
                            if agent_only
                                && (agent.is_none()
                                    || agent.is_some_and(|agent| agent.state == "unknown"))
                            {
                                continue;
                            }
                            let name = tab
                                .name
                                .as_deref()
                                .filter(|name| !name.is_empty())
                                .or_else(|| (!tab.title.is_empty()).then_some(tab.title.as_str()))
                                // An untitled agent tab reads better as its
                                // agent type than as a short id.
                                .or_else(|| {
                                    agent
                                        .filter(|_| agent_only)
                                        .and_then(|agent| agent.agent.as_deref())
                                })
                                .unwrap_or(tab.short_id.as_str())
                                .to_string();
                            let subtitle = if let Some(agent) = agent.filter(|_| agent_only) {
                                agent
                                    .session
                                    .as_deref()
                                    .filter(|session| !session.is_empty())
                                    .unwrap_or_else(|| {
                                        // In an all-workspaces sweep the
                                        // workspace locates the agent better
                                        // than a pane short id.
                                        if all_workspaces {
                                            workspace.name.as_str()
                                        } else {
                                            pane.short_id.as_str()
                                        }
                                    })
                                    .to_string()
                            } else {
                                pane.short_id.clone()
                            };
                            let sort_key = agent.filter(|_| agent_only).map(|agent| {
                                let seen = seen_idle.contains(&agent.surface);
                                (
                                    u8::MAX - agent_priority(&agent.state, seen),
                                    u64::MAX - agent.updated_at_ms,
                                )
                            });
                            let row = ProjectionRow {
                                resource,
                                depth: depth as u16,
                                name,
                                subtitle,
                                agent_state: agent
                                    .filter(|_| agent_only)
                                    .map(|agent| agent.state.clone()),
                                agent_label: agent
                                    .filter(|_| agent_only)
                                    .and_then(|agent| agent.agent.clone()),
                                active: workspace_index == tree.active_workspace
                                    && screen_index == workspace.active_screen
                                    && pane.id == screen.active_pane
                                    && pane.active_tab == tab_index,
                                branch: None,
                                expanded: false,
                                target: ProjectionTarget::Surface {
                                    workspace: workspace_index,
                                    screen: screen_index,
                                    pane: pane.id,
                                    index: tab_index,
                                    surface: tab.surface,
                                    agent: agent_only,
                                },
                            };
                            match sort_key {
                                Some((priority, recency)) => {
                                    entries.push(((priority, recency, entries.len()), row));
                                }
                                None => output.push(row),
                            }
                        }
                    }
                }
            }
            entries.sort_by_key(|(key, _)| *key);
            output.extend(entries.into_iter().map(|(_, row)| row));
        }
    }
}

/// How urgently an agent state needs the user: blocked agents wait on a
/// human, working agents may block next, idle agents are at rest.
fn agent_attention(state: &str) -> u8 {
    match state {
        "blocked" => 3,
        "working" => 2,
        "idle" => 1,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::{Node, SurfaceKind};
    use std::time::Instant;

    use crate::session::tree::{PaneView, ScreenView, TabView, WorkspaceView};

    fn tree() -> TreeView {
        TreeView {
            workspaces: vec![WorkspaceView {
                id: 1,
                resource_id: None,
                key: "workspace-1".into(),
                short_id: "w1".into(),
                name: "project".into(),
                screens: vec![ScreenView {
                    id: 2,
                    resource_id: None,
                    short_id: "s2".into(),
                    name: None,
                    layout: Node::Leaf(3),
                    active_pane: 3,
                    zoomed_pane: None,
                    viewport_base_width: None,
                    viewport_splits: Default::default(),
                    panes: vec![PaneView {
                        id: 3,
                        resource_id: None,
                        short_id: "p3".into(),
                        name: Some("editor".into()),
                        tabs: vec![tab(4, "shell"), tab(5, "codex")],
                        active_tab: 1,
                        focused_at: 0,
                    }],
                }],
                active_screen: 0,
            }],
            workspace_revision: 1,
            pane_revision: Some(1),
            active_workspace: 0,
        }
    }

    fn tab(surface: SurfaceId, title: &str) -> TabView {
        TabView {
            surface,
            public_id: None,
            content_id: None,
            terminal_id: None,
            short_id: format!("t{surface}"),
            name: None,
            title: title.into(),
            kind: SurfaceKind::Pty,
            browser_source: None,
            browser_frames_stalled: false,
            supports_clear_history_key_fallback: false,
            notification: None,
        }
    }

    fn spec(levels: Vec<SidebarResourceKind>) -> SidebarViewSpec {
        SidebarViewSpec {
            id: "test".into(),
            levels,
            actions: Vec::new(),
            actions_position: crate::config::ActionsPosition::Bottom,
            width: 22,
            max_width: 0,
            collapse_priority: 20,
            row_lines: 1,
            scope: SidebarViewScope::Workspace,
        }
    }

    #[test]
    fn workspace_agent_tree_uses_canonical_agent_records() {
        let tree = tree();
        let agents = vec![AgentInfo {
            surface: 5,
            state: "working".into(),
            source: "detected".into(),
            session: Some("fix sidebar".into()),
            agent: None,
            updated_at_ms: 1,
        }];
        let rows = rows(
            &spec(vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents]),
            &tree,
            &agents,
            &HashSet::new(),
            0,
            &HashSet::new(),
        );

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].resource, SidebarResourceKind::Workspaces);
        assert_eq!(rows[1].name, "codex");
        assert_eq!(rows[1].subtitle, "fix sidebar");
        assert_eq!(rows[1].agent_state.as_deref(), Some("working"));
        assert_eq!(rows[1].depth, 1);
        assert!(matches!(
            rows[1].target,
            ProjectionTarget::Surface { surface: 5, agent: true, .. }
        ));
    }

    #[test]
    fn collapsed_workspace_hides_its_projected_children() {
        let tree = tree();
        let mut collapsed = HashSet::new();
        collapsed.insert(ProjectionBranch::Workspace(1));
        let rows = rows(
            &spec(vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Panes]),
            &tree,
            &[],
            &HashSet::new(),
            0,
            &collapsed,
        );

        assert_eq!(rows.len(), 1);
        assert!(!rows[0].expanded);
    }

    #[test]
    fn three_level_tree_preserves_exact_tab_locations() {
        let tree = tree();
        let rows = rows(
            &spec(vec![
                SidebarResourceKind::Workspaces,
                SidebarResourceKind::Panes,
                SidebarResourceKind::Tabs,
            ]),
            &tree,
            &[],
            &HashSet::new(),
            0,
            &HashSet::new(),
        );

        assert_eq!(rows.len(), 4);
        assert_eq!(rows[3].depth, 2);
        assert!(matches!(
            rows[3].target,
            ProjectionTarget::Surface {
                workspace: 0,
                screen: 0,
                pane: 3,
                index: 1,
                surface: 5,
                agent: false,
            }
        ));
    }

    #[test]
    fn screen_detect_agents_view_sorts_by_attention_then_recency() {
        let mut tree = tree();
        tree.workspaces[0].screens[0].panes[0].tabs = vec![
            tab(4, "idle-late"),
            tab(5, "working-old"),
            tab(6, "blocked-old"),
            tab(7, "working-new"),
            tab(8, "shell"),
        ];
        let agent = |surface: SurfaceId, state: &str, updated_at_ms: u64| AgentInfo {
            surface,
            state: state.into(),
            source: "detected".into(),
            session: None,
            agent: Some("codex".into()),
            updated_at_ms,
        };
        // The most recent update is an idle agent: attention still outranks
        // recency, so blocked > working > idle, newest first inside buckets.
        let agents = vec![
            agent(4, "idle", 90),
            agent(5, "working", 30),
            agent(6, "blocked", 10),
            agent(7, "working", 40),
        ];
        let rows =
            rows(&spec(vec![SidebarResourceKind::Agents]), &tree, &agents, 0, &HashSet::new());

        let order: Vec<&str> = rows.iter().map(|row| row.name.as_str()).collect();
        assert_eq!(order, vec!["blocked-old", "working-new", "working-old", "idle-late"]);

        // Tab views keep tree order even when agents are present.
        let tabs = rows_tab_order(&tree, &agents);
        assert_eq!(tabs, vec!["idle-late", "working-old", "blocked-old", "working-new", "shell"]);
    }

    fn rows_tab_order(tree: &TreeView, agents: &[AgentInfo]) -> Vec<String> {
        rows(&spec(vec![SidebarResourceKind::Tabs]), tree, agents, 0, &HashSet::new())
            .into_iter()
            .map(|row| row.name)
            .collect()
    }

    #[test]
    fn flat_agent_view_is_empty_when_no_agents_are_running() {
        let rows = rows(&spec(vec![SidebarResourceKind::Agents]), &tree(), &[], &HashSet::new(), 0, &HashSet::new());
        assert!(rows.is_empty());
    }

    #[test]
    fn agent_projection_hides_unknown_records_at_its_boundary() {
        let agents = vec![AgentInfo {
            surface: 5,
            state: "unknown".into(),
            source: "hook".into(),
            session: None,
            agent: None,
            updated_at_ms: 1,
        }];
        let rows =
            rows(&spec(vec![SidebarResourceKind::Agents]), &tree(), &agents, &HashSet::new(), 0, &HashSet::new());
        assert!(rows.is_empty());
    }

    fn workspace(
        id: WorkspaceId,
        name: &str,
        pane: PaneId,
        surfaces: [SurfaceId; 2],
    ) -> WorkspaceView {
        WorkspaceView {
            id,
            resource_id: None,
            key: format!("workspace-{id}"),
            short_id: format!("w{id}"),
            name: name.into(),
            screens: vec![ScreenView {
                id: id + 100,
                resource_id: None,
                short_id: format!("s{id}"),
                name: None,
                layout: Node::Leaf(pane),
                active_pane: pane,
                zoomed_pane: None,
                viewport_base_width: None,
                viewport_splits: Default::default(),
                panes: vec![PaneView {
                    id: pane,
                    resource_id: None,
                    short_id: format!("p{pane}"),
                    name: None,
                    tabs: vec![tab(surfaces[0], "claude"), tab(surfaces[1], "codex")],
                    active_tab: 0,
                    focused_at: 0,
                }],
            }],
            active_screen: 0,
        }
    }

    #[test]
    fn all_scope_agents_sweep_workspaces_by_priority() {
        let tree = TreeView {
            workspaces: vec![
                workspace(1, "alpha", 10, [11, 12]),
                workspace(2, "beta", 20, [21, 22]),
            ],
            workspace_revision: 1,
            pane_revision: Some(1),
            active_workspace: 0,
        };
        let agents = vec![
            AgentInfo {
                surface: 11,
                state: "idle".into(),
                source: "hook".into(),
                session: Some("older task".into()),
                agent: None,
                updated_at_ms: 100,
            },
            AgentInfo {
                surface: 22,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 900,
            },
            AgentInfo {
                surface: 12,
                state: "done".into(),
                source: "hook".into(),
                session: Some("finished task".into()),
                agent: None,
                updated_at_ms: 500,
            },
        ];
        let mut all_spec = spec(vec![SidebarResourceKind::Agents]);
        all_spec.scope = SidebarViewScope::All;
        // The selected workspace must not scope the sweep.
        let rows = rows(&all_spec, &tree, &agents, &HashSet::new(), 1, &HashSet::new());

        assert_eq!(rows.len(), 3, "agents from every workspace appear");
        let order: Vec<u64> = rows
            .iter()
            .map(|row| match row.target {
                ProjectionTarget::Surface { surface, .. } => surface,
                _ => panic!("agent rows target surfaces"),
            })
            .collect();
        assert_eq!(order, vec![11, 22, 12], "unseen idle > working > everything else");
        assert_eq!(rows[0].agent_state.as_deref(), Some("idle"));
        assert_eq!(rows[1].agent_state.as_deref(), Some("working"));
        assert_eq!(
            rows[1].subtitle, "beta",
            "a session-less agent names its workspace in an all sweep"
        );
        assert_eq!(rows[2].agent_state.as_deref(), Some("done"));
    }

    #[test]
    fn workspace_scope_keeps_the_selected_workspace_filter() {
        let tree = TreeView {
            workspaces: vec![
                workspace(1, "alpha", 10, [11, 12]),
                workspace(2, "beta", 20, [21, 22]),
            ],
            workspace_revision: 1,
            pane_revision: Some(1),
            active_workspace: 0,
        };
        let agents = vec![
            AgentInfo {
                surface: 11,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 100,
            },
            AgentInfo {
                surface: 22,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 900,
            },
        ];
        let rows =
            rows(&spec(vec![SidebarResourceKind::Agents]), &tree, &agents, &HashSet::new(), 1, &HashSet::new());
        assert_eq!(rows.len(), 1);
        assert!(matches!(rows[0].target, ProjectionTarget::Surface { surface: 22, .. }));
    }

    #[test]
    fn workspace_scoped_agents_keep_tree_order() {
        let tree = tree();
        let agents = vec![
            AgentInfo {
                surface: 4,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 900,
            },
            AgentInfo {
                surface: 5,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 100,
            },
        ];
        let rows =
            rows(&spec(vec![SidebarResourceKind::Agents]), &tree, &agents, &HashSet::new(), 0, &HashSet::new());
        let surfaces = rows
            .iter()
            .map(|row| match row.target {
                ProjectionTarget::Surface { surface, .. } => surface,
                _ => panic!("agent rows target surfaces"),
            })
            .collect::<Vec<_>>();
        assert_eq!(surfaces, vec![4, 5]);
    }

    #[test]
    fn agents_view_priority_ranks_blocked_unseen_working_seen_with_recency_ties() {
        let tree = TreeView {
            workspaces: vec![
                workspace(1, "alpha", 10, [11, 12]),
                workspace(2, "beta", 20, [21, 22]),
            ],
            workspace_revision: 1,
            pane_revision: Some(1),
            active_workspace: 0,
        };
        let agent = |surface: SurfaceId, state: &str, updated_at_ms: u64| AgentInfo {
            surface,
            state: state.into(),
            source: "detected".into(),
            session: None,
            agent: Some("codex".into()),
            updated_at_ms,
        };
        // The blocked agent is the OLDEST update and still ranks first;
        // the idle agents split on the client-local seen bit around the
        // newest (working) agent.
        let agents = vec![
            agent(11, "idle", 500),
            agent(12, "blocked", 100),
            agent(21, "working", 900),
            agent(22, "idle", 700),
        ];
        let mut all_spec = spec(vec![SidebarResourceKind::Agents]);
        all_spec.scope = SidebarViewScope::All;
        let seen: SeenIdleSurfaces = [22].into_iter().collect();
        let rows = rows(&all_spec, &tree, &agents, &seen, 0, &HashSet::new());

        let order: Vec<u64> = rows
            .iter()
            .map(|row| match row.target {
                ProjectionTarget::Surface { surface, .. } => surface,
                _ => panic!("agent rows target surfaces"),
            })
            .collect();
        assert_eq!(
            order,
            vec![12, 11, 21, 22],
            "blocked > idle-unseen > working > idle-seen"
        );

        // Marking the remaining idle agent seen drops it below working.
        let seen: SeenIdleSurfaces = [11, 22].into_iter().collect();
        let reranked = super::rows(&all_spec, &tree, &agents, &seen, 0, &HashSet::new());
        let order: Vec<u64> = reranked
            .iter()
            .map(|row| match row.target {
                ProjectionTarget::Surface { surface, .. } => surface,
                _ => panic!("agent rows target surfaces"),
            })
            .collect();
        assert_eq!(order, vec![12, 21, 22, 11], "seen idle sorts by recency after working");
    }

    #[test]
    fn selection_reconciles_by_surface_when_agent_recency_reorders_rows() {
        let tree = TreeView {
            workspaces: vec![
                workspace(1, "alpha", 10, [11, 12]),
                workspace(2, "beta", 20, [21, 22]),
            ],
            workspace_revision: 1,
            pane_revision: Some(1),
            active_workspace: 0,
        };
        let mut all_spec = spec(vec![SidebarResourceKind::Agents]);
        all_spec.scope = SidebarViewScope::All;
        let initial_agents = vec![
            AgentInfo {
                surface: 11,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 100,
            },
            AgentInfo {
                surface: 22,
                state: "working".into(),
                source: "hook".into(),
                session: None,
                agent: None,
                updated_at_ms: 900,
            },
        ];
        let initial = rows(&all_spec, &tree, &initial_agents, &HashSet::new(), 0, &HashSet::new());
        let selected_target = initial[1].target;
        let mut state = ProjectionRailState {
            selected: 1,
            selected_target: Some(selected_target),
            ..ProjectionRailState::default()
        };

        let updated_agents = vec![
            AgentInfo { updated_at_ms: 1_000, ..initial_agents[0].clone() },
            initial_agents[1].clone(),
        ];
        let reordered = rows(&all_spec, &tree, &updated_agents, &HashSet::new(), 0, &HashSet::new());
        assert_ne!(reordered[1].target, selected_target);
        state.reconcile_selection(&reordered);
        assert_eq!(state.selected_target, Some(selected_target));
        assert_eq!(reordered[state.selected].target, selected_target);
    }

    /// Manual performance fixture for the intentional all-scope agent sort.
    /// Run with `--ignored --nocapture` when a hosted or local timing sample is
    /// needed. This test records no threshold and makes no timing claim.
    #[test]
    #[ignore = "manual projection performance measurement"]
    fn benchmark_all_scope_agents_at_thousand_workspaces() {
        let tree = TreeView {
            workspaces: (0..1_000)
                .map(|index| {
                    workspace(
                        index as WorkspaceId + 1,
                        "workspace",
                        index as PaneId + 10,
                        [index as SurfaceId + 100, index as SurfaceId + 10_100],
                    )
                })
                .collect(),
            workspace_revision: 1,
            pane_revision: Some(1),
            active_workspace: 0,
        };
        let agents = (0..1_000)
            .map(|index| AgentInfo {
                surface: index as SurfaceId + 100,
                state: "working".into(),
                source: "fixture".into(),
                session: None,
                agent: None,
                updated_at_ms: index as u64,
            })
            .collect::<Vec<_>>();
        let mut all_spec = spec(vec![SidebarResourceKind::Agents]);
        all_spec.scope = SidebarViewScope::All;

        let started = Instant::now();
        let projected = rows(&all_spec, &tree, &agents, &HashSet::new(), 0, &HashSet::new());
        eprintln!(
            "all-scope agent projection: {} rows in {:?}",
            projected.len(),
            started.elapsed()
        );
        assert_eq!(projected.len(), 1_000);
    }
}
