use super::*;
use cmux_tui_core::{Node, SurfaceKind};

use crate::session::tree::{PaneView, ScreenView, TabNotificationView, TabView, WorkspaceView};

fn tab(surface: SurfaceId, title: &str, unread: bool) -> TabView {
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
        notification: unread.then_some(TabNotificationView {
            unread: true,
            level: "info",
            sequence: surface,
        }),
    }
}

fn workspace(id: u64, name: &str, tabs: Vec<TabView>) -> WorkspaceView {
    WorkspaceView {
        id,
        resource_id: None,
        key: format!("workspace-{id}"),
        short_id: format!("w{id}"),
        name: name.into(),
        screens: vec![ScreenView {
            id: id * 10,
            resource_id: None,
            short_id: format!("s{id}"),
            name: None,
            layout: Node::Leaf(id * 100),
            active_pane: id * 100,
            zoomed_pane: None,
            viewport_base_width: None,
            viewport_splits: Default::default(),
            panes: vec![PaneView {
                id: id * 100,
                resource_id: None,
                short_id: format!("p{id}"),
                name: None,
                tabs,
                active_tab: 0,
                focused_at: 0,
            }],
        }],
        active_screen: 0,
    }
}

fn agent(surface: SurfaceId, state: &str, updated_at_ms: u64) -> AgentInfo {
    AgentInfo {
        surface,
        state: state.into(),
        source: "hook".into(),
        session: None,
        agent: Some("claude".into()),
        updated_at_ms,
    }
}

fn tree() -> TreeView {
    TreeView::from_parts(
        vec![
            workspace(
                1,
                "api",
                vec![
                    tab(11, "✳ Fix login", true),
                    tab(12, "⠂ Write tests", false),
                    tab(13, "zsh", false),
                ],
            ),
            workspace(
                2,
                "web",
                vec![tab(21, "Review", true), tab(22, "", false), tab(23, "old", false)],
            ),
            workspace(3, "docs", vec![tab(31, "zsh", false)]),
        ],
        1,
        Some(1),
        0,
    )
}

#[test]
fn finished_unseen_turn_is_done_and_rolls_up_above_working() {
    let status = SidebarStatus::build(
        &tree(),
        &[
            agent(11, "idle", 5),     // finished, its marker unread: done
            agent(12, "working", 6),  // working
            agent(21, "blocked", 1),  // blocked
            agent(22, "idle", 9),     // seen: idle
            agent(23, "done", 10),    // ended session: no agent
            agent(99, "working", 50), // a surface the tree does not show
        ],
    );

    assert_eq!(status.tab(11), Some(AgentStatus::Done));
    assert_eq!(status.tab(12), Some(AgentStatus::Working));
    assert_eq!(status.tab(13), None, "a shell tab has no agent");
    assert_eq!(status.tab(21), Some(AgentStatus::Blocked));
    assert_eq!(status.tab(22), Some(AgentStatus::Idle));
    assert_eq!(status.tab(23), None, "an ended session is not an agent");

    assert_eq!(status.workspace(0).unwrap().status, Some(AgentStatus::Done));
    assert_eq!(status.workspace(1).unwrap().status, Some(AgentStatus::Blocked));
    assert_eq!(status.workspace(2).unwrap().status, None);
}

#[test]
fn agents_section_is_an_attention_queue_across_workspaces() {
    let status = SidebarStatus::build(
        &tree(),
        &[
            agent(11, "idle", 5),
            agent(12, "working", 6),
            agent(13, "working", 8),
            agent(21, "blocked", 1),
            agent(22, "idle", 9),
        ],
    );
    let order = status.agents().iter().map(|row| (row.surface, row.status)).collect::<Vec<_>>();
    assert_eq!(
        order,
        vec![
            (21, AgentStatus::Blocked),
            (11, AgentStatus::Done),
            (13, AgentStatus::Working),
            (12, AgentStatus::Working),
            (22, AgentStatus::Idle),
        ],
        "blocked > done > working > idle, newest first inside a status"
    );
    let blocked = &status.agents()[0];
    assert_eq!(blocked.label, "Review");
    assert!(blocked.detail.ends_with(" · web"), "{}", blocked.detail);
    assert!(matches!(
        blocked.target,
        ProjectionTarget::Surface { workspace: 1, screen: 0, pane: 200, index: 0, surface: 21, .. }
    ));
    // Spinner glyphs in the title are stripped; an empty title falls back
    // to the adapter id.
    assert_eq!(status.agents()[1].label, "Fix login");
    assert_eq!(status.agents()[3].label, "Write tests");
    assert_eq!(status.agents()[4].label, "claude");
}

#[test]
fn workspace_second_line_is_the_active_pane_title() {
    let status = SidebarStatus::build(&tree(), &[]);
    assert_eq!(status.workspace(0).unwrap().subtitle, "Fix login");
    assert_eq!(status.workspace(1).unwrap().subtitle, "Review");
    assert_eq!(status.workspace(2).unwrap().subtitle, "zsh");
    assert!(status.agents().is_empty());
}
