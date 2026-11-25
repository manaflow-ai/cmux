use super::*;
use cmux_tui_core::{Node, SurfaceKind};

use crate::session::tree::{PaneView, ScreenView, TabView, WorkspaceView};

fn tree() -> TreeView {
    TreeView::from_parts(
        vec![WorkspaceView {
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
        1,
        Some(1),
        0,
    )
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
        program_status: None,
        attention: None,
        git_branch: None,
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
        agent: None,
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
    assert!(matches!(rows[1].target, ProjectionTarget::Surface { surface: 5, agent: true, .. }));
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
fn screen_detect_agents_view_sorts_by_attention_then_recency() {
    let mut tree = tree();
    tree.workspaces_mut()[0].screens[0].panes[0].tabs = vec![
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
    let rows = rows(&spec(vec![SidebarResourceKind::Agents]), &tree, &agents, 0, &HashSet::new());

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
    let rows = rows(&spec(vec![SidebarResourceKind::Agents]), &tree(), &[], 0, &HashSet::new());
    assert!(rows.is_empty());
}

#[test]
fn agent_order_cache_reuses_order_until_roster_or_tree_changes() {
    let mut tree = tree();
    tree.workspaces_mut()[0].screens[0].panes[0].tabs = vec![tab(4, "working"), tab(5, "blocked")];
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
    tree.workspaces_mut()[0].screens[0].panes[0].tabs.reverse();
    let rows = rows_cached(
        &spec(vec![SidebarResourceKind::Agents]),
        &tree,
        &agents,
        0,
        &HashSet::new(),
        &mut cache,
    );
    assert_eq!(
        rows.iter().map(|row| row.name.as_str()).collect::<Vec<_>>(),
        ["blocked", "working"]
    );
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
