//! Wire tests for `move-tab-to-split` `respawn` (`tab-split-respawn-v1`).
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
        handle_message(&self.mux, 7, &request.to_string(), &self.writer);
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
