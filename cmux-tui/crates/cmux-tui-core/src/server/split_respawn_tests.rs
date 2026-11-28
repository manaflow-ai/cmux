//! Wire tests for `move-tab-to-split` `respawn` (`tab-split-respawn-v1`) and
//! `keep_focus` (`tab-split-keep-focus-v1`).
//!
//! A pane's only tab dropped on its own pane's edge splits the pane: the tab
//! moves into the new pane and a fresh tab of the requested kind stays in
//! the old one (user requirement 2026-10-02).

use super::*;

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    fn new() -> Self {
        let mux = Mux::new_for_test("split-respawn", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        Self { mux, outbound, writer, next_id: 1 }
    }

    fn send(&mut self, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        handle_message(
            &self.mux,
            self.mux.local_test_client(7),
            &request.to_string(),
            &self.writer,
        );
        let response: Value = serde_json::from_str(&self.outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id, "response must answer the request: {response}");
        response
    }

    fn tabs(&self, pane: PaneId) -> Vec<SurfaceId> {
        self.mux
            .with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()))
            .unwrap_or_default()
    }
}

#[test]
fn only_tab_split_with_a_terminal_respawn_keeps_a_fresh_terminal() {
    assert!(advertised_capabilities(false).contains(&TAB_SPLIT_RESPAWN_CAPABILITY));
    let mut wire = Wire::new();
    let lone = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(lone).unwrap());
    // Without respawn the drop is refused, as before.
    let refused = wire
        .send(json!({"cmd": "move-tab-to-split", "surface": lone, "pane": pane, "edge": "right"}));
    assert_eq!(refused["ok"], false, "{refused}");

    let response = wire.send(json!({
        "cmd": "move-tab-to-split",
        "surface": lone,
        "pane": pane,
        "edge": "right",
        "respawn": {"kind": "terminal", "cwd": std::env::temp_dir().to_string_lossy()},
        "transaction": "drop-1",
    }));
    assert_eq!(response["ok"], true, "{response}");
    let new_pane: PaneId = serde_json::from_value(response["data"]["pane"].clone()).unwrap();
    assert_eq!(wire.tabs(new_pane), vec![lone]);
    let fresh = wire.tabs(pane);
    assert_eq!(fresh.len(), 1);
    assert_ne!(fresh[0], lone);
}

#[test]
fn a_bad_respawn_is_refused_and_creates_nothing() {
    let mut wire = Wire::new();
    let lone = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(lone).unwrap());
    for respawn in [
        json!({"kind": "agent"}),
        json!({"kind": "browser", "url": "about:blank"}),
        json!({"kind": "browser", "engine": "gecko", "url": "about:blank"}),
    ] {
        let response = wire.send(json!({
            "cmd": "move-tab-to-split", "surface": lone, "pane": pane, "edge": "left", "respawn": respawn,
        }));
        assert_eq!(response["ok"], false, "{respawn}: {response}");
        assert_eq!(wire.tabs(pane), vec![lone], "{respawn}");
    }
}

/// A frontend browser tab, the only tab of its pane, dropped on its own
/// pane's edge: it moves into the new pane, and a fresh frontend browser tab
/// with the record the app sends (its New Tab page, same engine and profile)
/// stays in the old pane, never a copy of the dragged tab's URL.
#[test]
fn only_browser_tab_split_with_a_browser_respawn_keeps_a_fresh_browser() {
    let mut wire = Wire::new();
    let terminal = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(terminal).unwrap());
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "cef".into(),
        url: "https://example.com/page".into(),
        title: None,
        favicon_url: None,
        profile_id: Some("work".into()),
        owner: None,
    };
    let browser = wire.mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id;
    // Make the browser the pane's only tab: the terminal goes to a split.
    wire.mux.move_tab_to_split(terminal, pane, crate::TabDropEdge::Left, None, None).unwrap();
    let response = wire.send(json!({
        "cmd": "move-tab-to-split",
        "surface": browser,
        "pane": pane,
        "edge": "bottom",
        "respawn": {"kind": "browser", "url": "about:blank", "engine": "cef", "profile_id": "work"},
    }));
    assert_eq!(response["ok"], true, "{response}");
    let new_pane: PaneId = serde_json::from_value(response["data"]["pane"].clone()).unwrap();
    assert_eq!(wire.tabs(new_pane), vec![browser]);
    let fresh = wire.tabs(pane);
    assert_eq!(fresh.len(), 1);
    let tab = |surface| {
        let decorations = wire.mux.tree_decorations();
        wire.mux
            .with_state(|state| {
                tree_entity_json(state, &decorations, TreeDeltaKind::TabChanged, surface)
            })
            .expect("tab is present in the tree")
    };
    let fresh_tab = tab(fresh[0]);
    assert_eq!(fresh_tab["browser_renderer"], "frontend");
    assert_eq!(fresh_tab["browser_engine"], "cef");
    assert_eq!(fresh_tab["browser_profile_id"], "work");
    assert_eq!(fresh_tab["url"], "about:blank");
    assert_eq!(tab(browser)["url"], "https://example.com/page");
}

/// `move-tab-to-column` `respawn` (`tab-column-respawn-v1`): docking a
/// screen's only tab moves it into a new docked column and leaves a fresh
/// terminal in its pane, so a column still scrolls (Dock Column on a
/// one-tab screen, user decision 2026-10-02).
#[test]
fn only_tab_docks_into_a_new_column_and_leaves_a_fresh_terminal() {
    assert!(advertised_capabilities(false).contains(&TAB_COLUMN_RESPAWN_CAPABILITY));
    let mut wire = Wire::new();
    let lone = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(lone).unwrap());
    let dock = json!({"edge": "right", "mode": "docked"});
    // Without respawn the pin would leave nothing to scroll: refused.
    let refused = wire.send(json!({
        "cmd": "move-tab-to-column", "surface": lone, "pane": pane, "width": 0.4, "dock": dock,
    }));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(wire.tabs(pane), vec![lone]);

    let response = wire.send(json!({
        "cmd": "move-tab-to-column",
        "surface": lone,
        "pane": pane,
        "width": 0.4,
        "dock": dock,
        "respawn": {"kind": "terminal", "cwd": std::env::temp_dir().to_string_lossy()},
        "transaction": "dock-1",
    }));
    assert_eq!(response["ok"], true, "{response}");
    let new_pane: PaneId = serde_json::from_value(response["data"]["pane"].clone()).unwrap();
    assert_eq!(wire.tabs(new_pane), vec![lone]);
    let fresh = wire.tabs(pane);
    assert_eq!(fresh.len(), 1);
    assert_ne!(fresh[0], lone);
    let columns = wire.mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        screen.layout_columns.iter().map(|column| column.dock.map(|s| s.edge)).collect::<Vec<_>>()
    });
    assert_eq!(columns, vec![None, Some(crate::model::DockEdge::Right)]);
}

#[test]
fn a_column_respawn_is_only_for_a_panes_only_tab() {
    let mut wire = Wire::new();
    let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(first).unwrap());
    let second = wire.mux.new_tab(Some(pane), None, Some((80, 22))).unwrap().id;
    let response = wire.send(json!({
        "cmd": "move-tab-to-column", "surface": second, "pane": pane, "respawn": {"kind": "terminal"},
    }));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(wire.tabs(pane), vec![first, second]);
}

/// `keep_focus` (cx-3hw0i): an app opens an agent's pane beside the chat the
/// user types in; the split must leave the chat's pane focused (active pane,
/// most recent focus), where a plain drop focuses the new pane.
#[test]
fn a_keep_focus_split_leaves_the_focused_pane_focused() {
    assert!(advertised_capabilities(false).contains(&TAB_SPLIT_KEEP_FOCUS_CAPABILITY));
    let mut wire = Wire::new();
    let chat = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let pane = wire.mux.with_state(|state| state.pane_of(chat).unwrap());
    let focus = |wire: &Wire| {
        wire.mux.with_state(|state| {
            let recent = state.panes.iter().max_by_key(|(_, p)| p.focused_at).map(|(id, _)| *id);
            (state.active_pane(), recent)
        })
    };
    let agent = wire.mux.new_tab(Some(pane), None, None).unwrap().id;
    let before = focus(&wire);
    assert_eq!(before.0, Some(pane));

    let response = wire.send(json!({
        "cmd": "move-tab-to-split", "surface": agent, "pane": pane, "edge": "right",
        "keep_focus": true, "transaction": "agent-pane-1",
    }));
    assert_eq!(response["ok"], true, "{response}");
    let agent_pane: PaneId = serde_json::from_value(response["data"]["pane"].clone()).unwrap();
    assert_eq!(wire.tabs(agent_pane), vec![agent]);
    assert_eq!(wire.tabs(pane), vec![chat]);
    assert_eq!(focus(&wire), before, "the chat's pane keeps focus");

    // A second one stacks under the first, still without focus.
    let second = wire.mux.new_tab(Some(pane), None, None).unwrap().id;
    let before = focus(&wire);
    let response = wire.send(json!({
        "cmd": "move-tab-to-split", "surface": second, "pane": agent_pane, "edge": "bottom",
        "keep_focus": true,
    }));
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(focus(&wire), before, "a split of another pane keeps focus too");

    // A new column (the split had no room) keeps focus too.
    let column = wire.mux.new_tab(Some(pane), None, None).unwrap().id;
    let before = focus(&wire);
    let response = wire.send(json!({
        "cmd": "move-tab-to-column", "surface": column, "pane": pane, "keep_focus": true,
    }));
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(focus(&wire), before, "a column move keeps focus too");
    let new_pane: PaneId = serde_json::from_value(response["data"]["pane"].clone()).unwrap();
    let active_at = wire.mux.with_state(|state| state.panes[&new_pane].active_at);
    assert_eq!(active_at, 0, "the new pane is the least recent one");

    // keep_focus with respawn is a bad request and changes nothing.
    let lone = wire.mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let lone_pane = wire.mux.with_state(|state| state.pane_of(lone).unwrap());
    let refused = wire.send(json!({
        "cmd": "move-tab-to-split", "surface": lone, "pane": lone_pane, "edge": "right",
        "keep_focus": true, "respawn": {"kind": "terminal"},
    }));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(wire.tabs(lone_pane), vec![lone]);

    // Without the flag the drop focuses the new pane, as before.
    let third = wire.mux.new_tab(Some(pane), None, None).unwrap().id;
    let response = wire
        .send(json!({"cmd": "move-tab-to-split", "surface": third, "pane": pane, "edge": "left"}));
    assert_eq!(response["ok"], true, "{response}");
    let dropped: PaneId = serde_json::from_value(response["data"]["pane"].clone()).unwrap();
    assert_eq!(focus(&wire), (Some(dropped), Some(dropped)));
}
