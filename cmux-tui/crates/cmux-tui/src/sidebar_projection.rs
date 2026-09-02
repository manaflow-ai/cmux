//! Pure projection of mux resources into configurable native sidebar trees.

use std::collections::{HashMap, HashSet};

use cmux_tui_core::{PaneId, SurfaceId, WorkspaceId};

use crate::config::{SidebarResourceKind, SidebarViewSpec};
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProjectionRow {
    pub resource: SidebarResourceKind,
    pub depth: u16,
    pub name: String,
    pub subtitle: String,
    pub agent_state: Option<String>,
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
    pub selected_action: Option<usize>,
    pub scroll: usize,
    pub footer_scroll: usize,
    pub follow_selection: bool,
    pub collapsed: HashSet<ProjectionBranch>,
}

/// Reusable ordering for agent rows. The order changes only when the agent
/// roster or tree topology changes, so renders can reuse the index.
#[derive(Default)]
pub(crate) struct AgentOrderCache {
    key: Option<AgentOrderCacheKey>,
    order: Vec<SurfaceId>,
}

#[derive(Clone, PartialEq, Eq)]
struct AgentOrderCacheKey {
    tree_workspace_revision: u64,
    tree_pane_revision: Option<u64>,
    tree_surfaces: Vec<SurfaceId>,
    agents: Vec<(SurfaceId, u8, u64)>,
}

impl AgentOrderCache {
    fn ordered_surfaces(&mut self, tree: &TreeView, agents: &[AgentInfo]) -> &[SurfaceId] {
        let revisions_match = self.key.as_ref().is_some_and(|key| {
            if key.tree_workspace_revision != tree.workspace_revision
                || key.tree_pane_revision != tree.pane_revision
                || key.agents.len() != agents.len()
            {
                return false;
            }
            if !key.agents.iter().zip(agents).all(
                |(&(surface, attention, updated_at_ms), agent)| {
                    (surface, attention, updated_at_ms)
                        == (agent.surface, agent_attention(&agent.state), agent.updated_at_ms)
                },
            ) {
                return false;
            }
            tree_surface_sequence_matches(tree, &key.tree_surfaces)
        });
        if revisions_match {
            return &self.order;
        }

        let tree_surfaces = tree
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .map(|tab| tab.surface)
            .collect::<Vec<_>>();
        let agent_metadata = agents
            .iter()
            .map(|agent| (agent.surface, agent_attention(&agent.state), agent.updated_at_ms))
            .collect::<Vec<_>>();
        let agent_keys = agents
            .iter()
            .map(|agent| {
                (
                    agent.surface,
                    (u8::MAX - agent_attention(&agent.state), u64::MAX - agent.updated_at_ms),
                )
            })
            .collect::<HashMap<_, _>>();
        let mut indexed = tree_surfaces
            .iter()
            .enumerate()
            .filter_map(|(index, surface)| {
                agent_keys
                    .get(surface)
                    .map(|&(attention, recency)| (attention, recency, index, *surface))
            })
            .collect::<Vec<_>>();
        indexed.sort_unstable_by_key(|&(attention, recency, index, _)| (attention, recency, index));
        self.order = indexed.into_iter().map(|(_, _, _, surface)| surface).collect();
        self.key = Some(AgentOrderCacheKey {
            tree_workspace_revision: tree.workspace_revision,
            tree_pane_revision: tree.pane_revision,
            tree_surfaces,
            agents: agent_metadata,
        });
        &self.order
    }
}

fn tree_surface_sequence_matches(tree: &TreeView, expected: &[SurfaceId]) -> bool {
    let mut expected = expected.iter();
    for surface in tree
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.panes.iter())
        .flat_map(|pane| pane.tabs.iter())
        .map(|tab| tab.surface)
    {
        if expected.next() != Some(&surface) {
            return false;
        }
    }
    expected.next().is_none()
}

impl Default for ProjectionRailState {
    fn default() -> Self {
        Self {
            selected: 0,
            selected_action: None,
            scroll: 0,
            footer_scroll: 0,
            follow_selection: true,
            collapsed: HashSet::new(),
        }
    }
}

#[derive(Clone, Copy)]
struct ProjectionContext {
    workspace: usize,
    screen: Option<usize>,
    pane: Option<PaneId>,
}

pub(crate) fn rows(
    spec: &SidebarViewSpec,
    tree: &TreeView,
    agents: &[AgentInfo],
    selected_workspace: usize,
    collapsed: &HashSet<ProjectionBranch>,
) -> Vec<ProjectionRow> {
    let mut order_cache = AgentOrderCache::default();
    rows_cached(spec, tree, agents, selected_workspace, collapsed, &mut order_cache)
}

pub(crate) fn rows_cached(
    spec: &SidebarViewSpec,
    tree: &TreeView,
    agents: &[AgentInfo],
    selected_workspace: usize,
    collapsed: &HashSet<ProjectionBranch>,
    order_cache: &mut AgentOrderCache,
) -> Vec<ProjectionRow> {
    // Workspace rows are the common projection and can reach roughly 1000
    // entries. Reserve that baseline up front so a render does not repeatedly
    // grow and copy the backing buffer while appending the tree.
    let mut rows = Vec::with_capacity(tree.workspaces.len());
    let agents_by_surface: HashMap<SurfaceId, &AgentInfo> =
        agents.iter().map(|agent| (agent.surface, agent)).collect();
    let agent_order = if spec.levels.contains(&SidebarResourceKind::Agents) {
        order_cache.ordered_surfaces(tree, agents)
    } else {
        &[]
    };
    append_level(
        &mut rows,
        &spec.levels,
        0,
        None,
        tree,
        &agents_by_surface,
        agent_order,
        selected_workspace.min(tree.workspaces.len().saturating_sub(1)),
        collapsed,
    );
    rows
}

#[allow(clippy::too_many_arguments)]
fn append_level(
    output: &mut Vec<ProjectionRow>,
    levels: &[SidebarResourceKind],
    depth: usize,
    context: Option<ProjectionContext>,
    tree: &TreeView,
    agents: &HashMap<SurfaceId, &AgentInfo>,
    agent_order: &[SurfaceId],
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
                        depth + 1,
                        Some(ProjectionContext {
                            workspace: workspace_index,
                            screen: None,
                            pane: None,
                        }),
                        tree,
                        agents,
                        agent_order,
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
                            depth + 1,
                            Some(ProjectionContext {
                                workspace: workspace_index,
                                screen: Some(screen_index),
                                pane: Some(pane.id),
                            }),
                            tree,
                            agents,
                            agent_order,
                            selected_workspace,
                            collapsed,
                        );
                    }
                }
            }
        }
        SidebarResourceKind::Tabs | SidebarResourceKind::Agents => {
            let agent_only = resource == SidebarResourceKind::Agents;
            let mut agent_entries = HashMap::<SurfaceId, ProjectionRow>::new();
            let workspace_index = context.map_or(selected_workspace, |context| context.workspace);
            let Some(workspace) = tree.workspaces.get(workspace_index) else { return };
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
                        if agent_only && agent.is_none() {
                            continue;
                        }
                        let name = tab
                            .name
                            .as_deref()
                            .filter(|name| !name.is_empty())
                            .or_else(|| (!tab.title.is_empty()).then_some(tab.title.as_str()))
                            .unwrap_or(tab.short_id.as_str())
                            .to_string();
                        let subtitle = if let Some(agent) = agent.filter(|_| agent_only) {
                            agent
                                .session
                                .as_deref()
                                .filter(|session| !session.is_empty())
                                .unwrap_or(pane.short_id.as_str())
                                .to_string()
                        } else {
                            pane.short_id.clone()
                        };
                        let row = ProjectionRow {
                            resource,
                            depth: depth as u16,
                            name,
                            subtitle,
                            agent_state: agent
                                .filter(|_| agent_only)
                                .map(|agent| agent.state.clone()),
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
                        if agent_only {
                            debug_assert!(agent.is_some(), "agent rows are filtered above");
                            agent_entries.insert(tab.surface, row);
                        } else {
                            output.push(row);
                        }
                    }
                }
            }
            for surface in agent_order {
                if let Some(row) = agent_entries.remove(surface) {
                    output.push(row);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::{Node, SurfaceKind};

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
            updated_at_ms: 1,
        }];
        let rows = rows(
            &spec(vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Agents]),
            &tree,
            &agents,
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
    fn flat_agent_view_is_empty_when_no_agents_are_running() {
        let rows = rows(&spec(vec![SidebarResourceKind::Agents]), &tree(), &[], 0, &HashSet::new());
        assert!(rows.is_empty());
    }

    #[test]
    fn agent_order_cache_reuses_order_until_roster_or_tree_changes() {
        let mut tree = tree();
        tree.workspaces[0].screens[0].panes[0].tabs = vec![tab(4, "working"), tab(5, "blocked")];
        let agent = |surface: SurfaceId, state: &str, updated_at_ms: u64| AgentInfo {
            surface,
            state: state.into(),
            source: "detected".into(),
            session: None,
            agent: Some("codex".into()),
            updated_at_ms,
        };
        let mut agents = vec![agent(4, "working", 10), agent(5, "blocked", 1)];
        let mut cache = AgentOrderCache::default();
        let first = rows_cached(
            &spec(vec![SidebarResourceKind::Agents]),
            &tree,
            &agents,
            0,
            &HashSet::new(),
            &mut cache,
        );
        assert_eq!(
            first.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
            ["blocked", "working"]
        );
        let cached_order = cache.order.clone();
        let _ = rows_cached(
            &spec(vec![SidebarResourceKind::Agents]),
            &tree,
            &agents,
            0,
            &HashSet::new(),
            &mut cache,
        );
        assert_eq!(cache.order, cached_order);

        agents[0].updated_at_ms = 20;
        let _ = rows_cached(
            &spec(vec![SidebarResourceKind::Agents]),
            &tree,
            &agents,
            0,
            &HashSet::new(),
            &mut cache,
        );
        assert_eq!(cache.order, vec![5, 4]);

        agents[0].updated_at_ms = 1;
        agents[1].state = "working".into();
        let _ = rows_cached(
            &spec(vec![SidebarResourceKind::Agents]),
            &tree,
            &agents,
            0,
            &HashSet::new(),
            &mut cache,
        );
        assert_eq!(cache.order, vec![4, 5]);
        tree.workspaces[0].screens[0].panes[0].tabs.reverse();
        let _ = rows_cached(
            &spec(vec![SidebarResourceKind::Agents]),
            &tree,
            &agents,
            0,
            &HashSet::new(),
            &mut cache,
        );
        assert_eq!(cache.order, vec![5, 4]);
    }

    #[test]
    fn tabs_view_does_not_build_agent_order_cache() {
        let tree = tree();
        let agents = vec![AgentInfo {
            surface: 4,
            state: "working".into(),
            source: "detected".into(),
            session: None,
            agent: Some("codex".into()),
            updated_at_ms: 1,
        }];
        let mut cache = AgentOrderCache::default();

        let _ = rows_cached(
            &spec(vec![SidebarResourceKind::Tabs]),
            &tree,
            &agents,
            0,
            &HashSet::new(),
            &mut cache,
        );

        assert!(cache.key.is_none());
    }
}
