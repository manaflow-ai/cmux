//! `control-topology-v1` (server/control_topology.rs): the daemon maps its
//! tree into the app control socket's `snapshot.get` topology shape with the
//! rules of the app's `ControlTopologyMapper`, and joins the asking
//! connection's own app-only view record.
//!
//! The corpus below is the app mapper's: each expected value is what
//! `ControlTopology.json` prints for the same daemon tree (the Swift rules
//! are named beside each case), so the daemon's answer is proved equal before
//! the app reads it.

use super::control_topology::{
    ControlView, DaemonFacts, terminal_title_text, topology_json, valid_attention,
};
use super::*;
use serde_json::Map;
use std::collections::HashMap;

/// `TerminalTitleTests.leadingStatusGlyphsBecomeTheActivity`, the text half.
#[test]
fn a_terminal_title_loses_its_leading_status_glyphs() {
    for (raw, text) in [
        ("⠐ Fix the login bug", "Fix the login bug"),
        ("⠂ Fix the login bug", "Fix the login bug"),
        ("✳ Claude Code", "Claude Code"),
        ("● build", "build"),
        ("✔︎ tests passed", "tests passed"),
        ("✘ deploy", "deploy"),
        ("✳ ⠂ Task", "Task"),
        ("vim notes.md", "vim notes.md"),
        ("~/src · main", "~/src · main"),
        ("⠂", "⠂"),
        ("  zsh  ", "zsh"),
        ("", ""),
    ] {
        assert_eq!(terminal_title_text(raw), text, "{raw:?}");
    }
}

#[test]
fn an_attention_mark_needs_a_reason_and_a_whole_time() {
    assert!(valid_attention(&json!({"reason": "permission", "at_ms": 5})));
    assert!(valid_attention(&json!({"reason": "permission", "at_ms": 5.0, "request_id": "bad"})));
    assert!(!valid_attention(&json!({"reason": "", "at_ms": 5})));
    assert!(!valid_attention(&json!({"reason": "permission"})));
    assert!(!valid_attention(&json!({"reason": "permission", "at_ms": 5.5})));
    assert!(!valid_attention(&json!({"reason": "permission", "at_ms": -1})));
}

/// One workspace with every rule the app's mapper applies: title over name,
/// public ids with their fallbacks, the window's columns (a left dock, two
/// scrolling columns, a right dock, a bottom band), the zoomed pane, tab
/// kinds and titles, tab groups, unread from the notification and the state
/// record, agent status by surface, and a workspace without a key.
fn corpus_tree() -> Value {
    // Built in parts: one `json!` of the whole tree passes the macro recursion limit.
    let notification = json!({"notification": 3, "unread": true, "level": "info", "source": "cli"});
    let terminal = json!({
        "surface": 1, "kind": "pty", "tab_resource_id": "tab_1", "terminal_id": "term-key-1",
        "terminal_resource_id": "term_1", "title": "⠂ Fix the login bug", "name": null,
        "size": {"cols": 80, "rows": 24}, "cwd": "/src", "git_branch": "main", "pinned": true,
        "dead": false, "group": "tg_1", "notification": notification,
    });
    let named = json!({
        "surface": 2, "kind": "pty", "terminal_id": "term-key-2", "title": "⠂ busy", "name": "Release",
        "size": null, "dead": true,
    });
    let browser = json!({
        "surface": 5, "kind": "browser", "tab_resource_id": "tab_5", "title": "● Slack | general",
        "url": "https://example.com",
    });
    let tab_group = json!({"id": "tg_1", "name": "Build", "color": "blue", "collapsed": true, "surfaces": [1, 99]});
    let main = json!({
        "id": 12, "resource_id": "pane_cccc", "name": "main",
        "tab_groups": [tab_group], "tabs": [terminal, named, browser],
    });
    let files_ref = json!({"page": "files", "route": "/README.md"});
    let files = json!({
        "surface": 6, "kind": "conversation", "tab_resource_id": "tab_6", "title": "about:blank",
        "conversation": files_ref,
    });
    let chat_ref = json!({"agent_session": {"host": "install:x", "session": "chat-1"}});
    let chat = json!({
        "surface": 7, "kind": "conversation", "tab_resource_id": "tab_7", "title": "about:blank",
        "conversation": chat_ref,
    });
    let pages = json!({"id": 13, "name": null, "tabs": [files, chat]});
    let remote_tab = json!({
        "surface": 8, "kind": "remote-terminal", "tab_resource_id": "tab_8", "title": "✳ remote job",
        "terminal_id": null, "cwd": null,
    });
    let right = json!({"id": 14, "resource_id": "pane_right", "tabs": [remote_tab]});
    let stacked = json!({"id": 15, "resource_id": "pane_stacked", "tabs": [{"surface": 9, "kind": "sidebar-plugin"}]});
    let band = json!({"id": 16, "resource_id": "pane_band", "tabs": []});
    let strip2 = json!({"id": 17, "resource_id": "pane_strip2", "tabs": []});
    let left_layout = json!({
        "type": "split", "split": 1, "dir": "down", "ratio": 0.5,
        "a": {"type": "leaf", "pane": 12}, "b": {"type": "stack", "panes": [15], "expanded": 15},
    });
    let columns = vec![
        json!({"id": 20, "layout": {"type": "leaf", "pane": 13}}),
        json!({"id": 21, "layout": {"type": "leaf", "pane": 14}, "dock": {"edge": "right", "mode": "docked"}}),
        json!({"id": 22, "layout": left_layout, "dock": {"edge": "left", "mode": "docked"}}),
        json!({"id": 23, "layout": {"type": "leaf", "pane": 16}, "dock": {"edge": "bottom", "mode": "docked"}}),
        json!({"id": 24, "layout": {"type": "leaf", "pane": 17}}),
    ];
    let screen = json!({
        "id": 3, "resource_id": "screen_bbbb", "name": null, "zoomed_pane": 12,
        "columns": columns, "panes": [main, pages, right, stacked, band, strip2],
    });
    let release = json!({
        "id": 4, "resource_id": "ws_aaaa", "key": "6ba7b810-9dad-41d1-80b4-00c04fd430c8",
        "name": "workspace-1", "title": "Release", "color": "#ff0000", "icon": null,
        "group": "grp_1", "unread_count": 9, "screens": [screen],
    });
    let bare =
        json!({"id": 30, "name": "workspace-2", "title": "", "screens": [], "unread_count": 2});
    let groups =
        json!([{"id": "shared-group", "name": "Shared", "color": null, "collapsed": false}]);
    json!({"groups": groups, "workspaces": [release, bare]})
}

fn corpus_facts() -> DaemonFacts {
    DaemonFacts {
        tree: corpus_tree(),
        personal_groups: None,
        agents: HashMap::from([(1, ("working".to_string(), Some("claude".to_string())))]),
        marked_tabs: ["tab_5".to_string()].into_iter().collect(),
    }
}

fn corpus_view() -> ControlView {
    ControlView::parse(json!({
        "panes": {
            "pane_cccc": {"selected_tab": "tab_5", "mirrored_tabs": ["tab_other"]},
            "pane:13": {"page_tabs": [{"id": "local-page:settings:1", "page": "settings", "title": "Settings", "selected": true}]},
        },
        "page_titles": {"tab_6": "README.md", "tab_7": "not a page"},
    }))
    .unwrap()
}

#[test]
fn the_daemon_maps_its_tree_as_the_apps_control_mapper_does() {
    let topology = topology_json(&corpus_facts(), &corpus_view());
    assert_eq!(topology["tab_count"], 7, "daemon tabs only, not app page tabs");
    assert_eq!(
        topology["workspace_groups"],
        json!([{"id": "shared-group", "name": "Shared", "color": null, "collapsed": false}])
    );
    let workspace = &topology["workspaces"][0];
    assert_eq!(
        workspace
            .as_object()
            .unwrap()
            .iter()
            .filter(|(key, _)| *key != "screens")
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect::<Map<_, _>>(),
        json!({
            "id": "ws_aaaa", "key": "6ba7b810-9dad-41d1-80b4-00c04fd430c8", "handle": "4",
            "name": "Release", "title": "Release", "color": "#ff0000", "icon": null, "group": "grp_1",
            // Counted from the tabs (one notification unread), not the rollup.
            "unread": 1, "machine": null, "session": null,
        })
        .as_object()
        .unwrap()
        .clone()
    );
    let screen = &workspace["screens"][0];
    assert_eq!(screen["id"], "screen_bbbb");
    assert_eq!(screen["handle"], "3");
    assert_eq!(screen["zoomed_pane"], "pane_cccc");
    let panes = screen["panes"].as_array().unwrap();
    // Columns left to right: the left dock (panes 12, 15), the strip's two
    // columns (13, 17), the right dock (14); the bottom band (16) is none.
    let placement = panes
        .iter()
        .map(|pane| (pane["id"].as_str().unwrap(), pane["column"].clone(), pane["dock"].clone()))
        .collect::<Vec<_>>();
    assert_eq!(
        placement,
        vec![
            ("pane_cccc", json!(0), json!("left")),
            ("pane:13", json!(1), Value::Null),
            ("pane_right", json!(3), json!("right")),
            ("pane_stacked", json!(0), json!("left")),
            ("pane_band", Value::Null, Value::Null),
            ("pane_strip2", json!(2), Value::Null),
        ]
    );

    let main = &panes[0];
    assert_eq!(main["handle"], "12");
    assert_eq!(main["name"], "main");
    assert_eq!(main["selected_tab"], "tab_5");
    assert_eq!(main["mirrored_tabs"], json!(["tab_other"]));
    assert_eq!(
        main["tab_groups"],
        json!([{"id": "tg_1", "name": "Build", "color": "blue", "collapsed": true, "members": ["tab_1", "99"]}])
    );
    let first = main["tabs"][0].as_object().unwrap();
    let expected = [
        ("id", json!("tab_1")),
        ("surface", json!("1")),
        ("kind", json!("terminal")),
        ("page", Value::Null),
        ("title", json!("Fix the login bug")),
        ("name", Value::Null),
        ("terminal", json!("term_1")),
        ("terminal_key", json!("term-key-1")),
        ("columns", json!(80)),
        ("rows", json!(24)),
        ("cwd", json!("/src")),
        ("url", Value::Null),
        ("git_branch", json!("main")),
        ("pinned", json!(true)),
        ("dead", json!(false)),
        ("unread", json!(true)),
        ("tab_group", json!("tg_1")),
        ("agent_state", json!("working")),
        ("agent", json!("claude")),
        ("agent_session", Value::Null),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value))
    .collect::<Map<_, _>>();
    assert_eq!(first, &expected);
    // No public id: the terminal key names it; a name wins over the title.
    let named = &main["tabs"][1];
    assert_eq!(named["id"], "terminal:term-key-2");
    assert_eq!(named["title"], "Release");
    assert_eq!(named["terminal"], "term-key-2");
    assert_eq!(named["columns"], Value::Null);
    assert_eq!(named["dead"], true);
    assert_eq!(named["unread"], false);
    // A page keeps its glyphs; its state record marks it unread.
    let browser = &main["tabs"][2];
    assert_eq!(browser["kind"], "browser");
    assert_eq!(browser["title"], "● Slack | general");
    assert_eq!(browser["url"], "https://example.com");
    assert_eq!(browser["unread"], true);

    let pages = &panes[1];
    assert_eq!(pages["selected_tab"], Value::Null);
    assert!(pages.get("mirrored_tabs").is_none(), "only a pane that mirrors a tab says so");
    let tabs = pages["tabs"].as_array().unwrap();
    assert_eq!(tabs.len(), 3, "two daemon tabs, then the app's page tab");
    assert_eq!(tabs[0]["kind"], "page");
    assert_eq!(tabs[0]["page"], "files");
    assert_eq!(tabs[0]["title"], "README.md", "the page's title names a store page tab");
    assert_eq!(tabs[1]["kind"], "conversation");
    assert_eq!(tabs[1]["page"], Value::Null);
    assert_eq!(tabs[1]["title"], "about:blank", "a title in the view names page tabs only");
    assert_eq!(tabs[1]["agent_session"], "chat-1");
    assert_eq!(
        tabs[2],
        json!({"id": "local-page:settings:1", "kind": "page", "page": "settings", "title": "Settings", "selected": true})
    );

    let remote = &panes[2]["tabs"][0];
    assert_eq!(remote["kind"], "remote-terminal");
    assert_eq!(remote["title"], "remote job");
    assert_eq!(panes[3]["tabs"][0]["kind"], "sidebar-plugin");

    // No key: `handle:<id>`; an empty title falls back to the name; no
    // screens: the rollup.
    let bare = &topology["workspaces"][1];
    assert_eq!(bare["id"], "handle:30");
    assert_eq!(bare["key"], "handle:30");
    assert_eq!(bare["name"], "workspace-2");
    assert_eq!(bare["title"], "");
    assert_eq!(bare["unread"], 2);
}

#[test]
fn personal_groups_are_the_groups_when_the_session_serves_them() {
    let mut facts = corpus_facts();
    facts.personal_groups = Some(vec![
        json!({"id": "grp_b", "profile": "default", "name": "Beta", "color": "red", "collapsed": true, "index": 1}),
        json!({"id": "grp_a", "profile": "work", "name": "Alpha", "color": null, "collapsed": false, "index": 0}),
    ]);
    let topology = topology_json(&facts, &ControlView::default());
    assert_eq!(
        topology["workspace_groups"],
        json!([
            {"id": "grp_b", "name": "Beta", "color": "red", "collapsed": true},
            {"id": "grp_a", "name": "Alpha", "color": null, "collapsed": false},
        ]),
        "in the order the session lists them, of every room"
    );
}

#[test]
fn a_screen_stored_as_one_split_tree_is_column_zero() {
    let mut facts = corpus_facts();
    facts.tree["workspaces"][0]["screens"][0].as_object_mut().unwrap().remove("columns");
    let topology = topology_json(&facts, &ControlView::default());
    for pane in topology["workspaces"][0]["screens"][0]["panes"].as_array().unwrap() {
        assert_eq!(pane["column"], 0, "{pane}");
        assert_eq!(pane["dock"], Value::Null, "{pane}");
    }
}

#[test]
fn a_view_is_bounded_and_strict() {
    assert!(ControlView::parse(json!({"panes": {}, "page_titles": {}})).is_ok());
    assert!(ControlView::parse(json!({})).is_ok());
    let unknown = ControlView::parse(json!({"windows": []})).unwrap_err().to_string();
    assert!(unknown.contains("bad request"), "{unknown}");
    let long = "x".repeat(control_topology::MAX_VIEW_STRING_BYTES + 1);
    assert!(ControlView::parse(json!({"page_titles": {"tab_1": long}})).is_err());
    let huge = "x".repeat(control_topology::MAX_VIEW_BYTES);
    assert!(ControlView::parse(json!({"page_titles": {"tab_1": huge}})).is_err());
}

struct Wire {
    mux: Arc<Mux>,
    outbound: Arc<BoundedOutbound>,
    writer: MessageWriter,
    next_id: u64,
}

impl Wire {
    fn new() -> Self {
        let mux = Mux::new_for_test("control-topology", crate::SurfaceOptions::default());
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        Self { mux, outbound, writer, next_id: 1 }
    }

    fn send(&mut self, client: u64, mut request: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        request["id"] = json!(id);
        handle_message(
            &self.mux,
            self.mux.local_test_client(client),
            &request.to_string(),
            &self.writer,
        );
        let response: Value = serde_json::from_str(&self.outbound.try_pop().unwrap()).unwrap();
        assert_eq!(response["id"], id, "response must answer the request: {response}");
        response
    }

    fn ok(&mut self, client: u64, request: Value) -> Value {
        let response = self.send(client, request.clone());
        assert_eq!(response["ok"], true, "{request} failed: {response}");
        response["data"].clone()
    }
}

#[test]
fn control_topology_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"control-topology-v1"));
}

/// The daemon's answer for a live session equals the mapping of its own
/// `list-workspaces` tree, and each connection sees only the view record it
/// wrote itself (single writer per client record).
#[test]
fn each_connection_reads_the_session_topology_with_its_own_view() {
    let mut wire = Wire::new();
    let first = wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let tree = wire.ok(1, json!({"cmd": "list-workspaces"}));
    let workspace = &tree["workspaces"][0];
    let pane = &workspace["screens"][0]["panes"][0];
    let pane_id =
        pane["resource_id"].as_str().map_or_else(|| format!("pane:{}", pane["id"]), str::to_string);
    let tab = &pane["tabs"][0];
    let tab_id = tab["tab_resource_id"]
        .as_str()
        .map(str::to_string)
        .or_else(|| tab["terminal_id"].as_str().map(|terminal| format!("terminal:{terminal}")))
        .unwrap_or_else(|| format!("surface:{}", tab["surface"]));
    assert_eq!(pane["tabs"][0]["surface"], first.id);

    let bare = wire.ok(1, json!({"cmd": "control-topology"}));
    assert_eq!(bare["tab_count"], 1);
    let public = workspace["resource_id"].as_str().or(workspace["key"].as_str()).unwrap();
    assert_eq!(bare["workspaces"][0]["id"], public);
    assert_eq!(bare["workspaces"][0]["key"], workspace["key"]);
    assert_eq!(bare["workspaces"][0]["screens"][0]["panes"][0]["id"], json!(pane_id));
    assert_eq!(bare["workspaces"][0]["screens"][0]["panes"][0]["tabs"][0]["id"], json!(tab_id));
    assert_eq!(bare["workspaces"][0]["screens"][0]["panes"][0]["selected_tab"], Value::Null);
    assert!(bare["registry_id"].is_string(), "{bare}");

    let mut panes = Map::new();
    panes.insert(pane_id, json!({"selected_tab": tab_id}));
    wire.ok(1, json!({"cmd": "set-control-view", "view": {"panes": panes}}));
    let mine = wire.ok(1, json!({"cmd": "control-topology"}));
    assert_eq!(mine["workspaces"][0]["screens"][0]["panes"][0]["selected_tab"], json!(tab_id));
    let other = wire.ok(2, json!({"cmd": "control-topology"}));
    assert_eq!(
        other["workspaces"][0]["screens"][0]["panes"][0]["selected_tab"],
        Value::Null,
        "another connection never reads or writes this connection's view"
    );

    // A replacement drops what the old record said.
    wire.ok(1, json!({"cmd": "set-control-view", "view": {}}));
    let cleared = wire.ok(1, json!({"cmd": "control-topology"}));
    assert_eq!(cleared["workspaces"][0]["screens"][0]["panes"][0]["selected_tab"], Value::Null);

    let refused = wire.send(1, json!({"cmd": "set-control-view", "view": {"focus": {}}}));
    assert_eq!(refused["ok"], false, "{refused}");
}

/// A remote device's lane (a phone through the Mac's splice) gets neither
/// command: the answer lists incognito workspaces and every tab title.
#[test]
fn a_remote_device_lane_is_refused() {
    let mut wire = Wire::new();
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let client = wire.mux.local_test_client(3);
    wire.mux.control_clients.mark_remote_device(client);
    for request in
        [json!({"cmd": "control-topology"}), json!({"cmd": "set-control-view", "view": {}})]
    {
        let response = wire.send(3, request.clone());
        assert_eq!(response["ok"], false, "{request}: {response}");
        assert!(response.to_string().contains("forbidden"), "{response}");
    }
}

/// A page connection (a page relay, page origin) gets neither command: a
/// page's JS would read every workspace and tab title of the session.
#[test]
fn a_page_connection_is_refused() {
    let mut wire = Wire::new();
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let client = wire.mux.local_test_client(4);
    {
        let mut state = wire.mux.control_clients.state.lock().unwrap();
        let record = state.clients.get_mut(&client).unwrap();
        record.origin.role = crate::request_origin::HelloRole::PageRelay;
    }
    for request in
        [json!({"cmd": "control-topology"}), json!({"cmd": "set-control-view", "view": {}})]
    {
        let response = wire.send(4, request.clone());
        assert_eq!(response["ok"], false, "{request}: {response}");
        assert!(response.to_string().contains("forbidden"), "{response}");
    }
    let state = wire.mux.control_clients.state.lock().unwrap();
    assert!(state.clients.get(&client).is_some_and(|record| record.control_view.is_none()));
}

/// `set-control-view` takes no connection id: it writes only the caller's
/// own record. A `client` or `id`-shaped member naming another connection
/// changes nothing of that connection's record, and a view member the record
/// does not define (a `client` inside the view) is refused.
#[test]
fn set_control_view_writes_only_the_callers_own_record() {
    let mut wire = Wire::new();
    wire.mux.new_workspace(None, Some((80, 22))).unwrap();
    let owner = wire.mux.local_test_client(5);
    let other = wire.mux.local_test_client(6);
    let mut owned = Map::new();
    owned.insert("pane_owner".into(), json!({"selected_tab": "tab_owner"}));
    wire.ok(5, json!({"cmd": "set-control-view", "view": {"panes": owned}}));

    let mut foreign = Map::new();
    foreign.insert("pane_owner".into(), json!({"selected_tab": "tab_foreign"}));
    // Unknown top-level members of a raw command are ignored, so this is the
    // other connection writing its own record, never the owner's.
    let reply = wire
        .send(6, json!({"cmd": "set-control-view", "client": owner, "view": {"panes": foreign}}));
    assert_eq!(reply["ok"], true, "{reply}");
    let refused = wire.send(6, json!({"cmd": "set-control-view", "view": {"client": owner}}));
    assert_eq!(refused["ok"], false, "{refused}");

    let state = wire.mux.control_clients.state.lock().unwrap();
    let view = |client: u64| {
        state.clients.get(&client).and_then(|record| record.control_view.clone()).unwrap()
    };
    let shown = |client: u64| {
        view(client).panes.get("pane_owner").and_then(|pane| pane.selected_tab.clone())
    };
    assert_eq!(shown(owner).as_deref(), Some("tab_owner"), "the owner's record is its own");
    assert_eq!(shown(other).as_deref(), Some("tab_foreign"), "the other wrote only its own");
}
