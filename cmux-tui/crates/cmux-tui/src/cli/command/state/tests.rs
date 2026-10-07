use serde_json::{Value, json};

use super::super::{CommandPlan, RequestPlan, Resolve, Selectors, ZoomStep, parse};
use super::status_target;
use crate::cli::Surface;
use cmux_tui_core::resource::ResourceOperation as Op;

const WS: &str = "ws_00000000000000000000000000000004";
const SCREEN: &str = "screen_00000000000000000000000000000005";
const SCREEN2: &str = "screen_00000000000000000000000000000015";
const PANE: &str = "pane_00000000000000000000000000000006";
const TAB: &str = "tab_00000000000000000000000000000007";
const TAB2: &str = "tab_00000000000000000000000000000017";
const TERM: &str = "term_00000000000000000000000000000008";

fn plan(args: &[&str]) -> RequestPlan {
    let args = args.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
    match parse(&args, Surface::Cmux) {
        Ok(CommandPlan::Protocol(plan)) => *plan,
        Ok(_) => panic!("{args:?} is not a protocol plan"),
        Err(error) => panic!("{args:?}: {error}"),
    }
}

fn rejects(args: &[&str]) -> String {
    let args = args.iter().map(|value| (*value).to_string()).collect::<Vec<_>>();
    match parse(&args, Surface::Cmux) {
        Err(error) => error.0,
        Ok(_) => panic!("accepted {args:?}"),
    }
}

/// Operation name and params without the routing defaults.
fn sent(args: &[&str]) -> (String, Value) {
    let plan = plan(args);
    let mut params = plan.params.as_object().unwrap().clone();
    assert_eq!(params.remove("machine"), Some(json!("current")), "{args:?}");
    assert_eq!(params.remove("session"), Some(json!("current")), "{args:?}");
    (plan.operation.name().unwrap(), Value::Object(params))
}

fn state_name(field: &'static str, list: Op) -> Resolve {
    Resolve::StateName { field, list }
}

#[test]
fn workspace_update_sets_and_clears_identity() {
    assert_eq!(
        sent(&["workspace", WS, "update", "--title", "API", "--color", "#ff8800", "--clear-icon"]),
        (
            "workspace.update".into(),
            json!({"workspace": WS, "title": "API", "color": "#ff8800", "icon": null})
        )
    );
    assert_eq!(
        sent(&["workspace", "update", "--clear-title"]),
        ("workspace.update".into(), json!({"workspace": "current", "title": null}))
    );
    assert!(rejects(&["workspace", WS, "update"]).contains("--title"));
    assert!(
        rejects(&["workspace", WS, "update", "--title", "a", "--clear-title"])
            .contains("mutually exclusive")
    );
    assert_eq!(
        sent(&["workspace", "create", "--ephemeral", "--empty"]).1,
        json!({"initial_content": "empty", "ephemeral": true})
    );
}

#[test]
fn workspace_status_progress_and_log_map_to_their_operations() {
    let cases: Vec<(Vec<&str>, &str, Value)> = vec![
        (
            vec!["workspace", WS, "status", "list"],
            "workspace_status.list",
            json!({"workspace": WS}),
        ),
        (vec!["workspace", "status", "list", "--all"], "workspace_status.list", json!({})),
        (
            vec![
                "workspace",
                WS,
                "status",
                "set",
                "build",
                "green",
                "--icon",
                "hammer",
                "--color",
                "green",
            ],
            "workspace_status.set",
            json!({"workspace": WS, "key": "build", "text": "green", "icon": "hammer", "color": "green"}),
        ),
        (
            vec!["workspace", WS, "status", "clear"],
            "workspace_status.clear",
            json!({"workspace": WS}),
        ),
        (
            vec!["workspace", WS, "status", "clear", "build"],
            "workspace_status.clear",
            json!({"workspace": WS, "key": "build"}),
        ),
        (
            vec!["workspace", WS, "progress", "set", "0.25", "--label", "tests"],
            "workspace_progress.set",
            json!({"workspace": WS, "value": 0.25, "label": "tests"}),
        ),
        (
            vec!["workspace", WS, "progress", "set", "--indeterminate"],
            "workspace_progress.set",
            json!({"workspace": WS, "value": null}),
        ),
        (
            vec!["workspace", WS, "progress", "clear"],
            "workspace_progress.clear",
            json!({"workspace": WS}),
        ),
        (
            vec!["workspace", WS, "log", "append", "done", "--level", "success", "--source", "ci"],
            "workspace_log.append",
            json!({"workspace": WS, "text": "done", "level": "success", "source": "ci"}),
        ),
        (
            vec!["workspace", WS, "log", "append", "--", "-5", "failed"],
            "workspace_log.append",
            json!({"workspace": WS, "text": "-5 failed"}),
        ),
        (
            vec!["workspace", WS, "log", "list", "--limit", "20"],
            "workspace_log.list",
            json!({"workspace": WS, "limit": 20}),
        ),
        (vec!["workspace", WS, "log", "clear"], "workspace_log.clear", json!({"workspace": WS})),
        // A workspace named like an area keeps the selector form.
        (
            vec!["workspace", "name:log", "log", "list"],
            "workspace_log.list",
            json!({"workspace": "name:log"}),
        ),
    ];
    for (args, operation, params) in cases {
        assert_eq!(sent(&args), (operation.to_string(), params), "{args:?}");
    }
    assert!(rejects(&["workspace", WS, "progress", "set", "1.5"]).contains("0 to 1"));
    assert!(
        rejects(&["workspace", WS, "progress", "set", "0.5", "--indeterminate"])
            .contains("--indeterminate")
    );
    assert!(
        rejects(&["workspace", WS, "log", "append", "x", "--level", "loud"]).contains("--level")
    );
    assert!(rejects(&["workspace", WS, "log", "list", "--limit", "500"]).contains("--limit"));
    assert!(rejects(&["workspace", WS, "status", "list", "--all"]).contains("--all"));
    assert!(rejects(&["workspace", WS, "status", "explode"]).contains("status"));
}

#[test]
fn status_without_a_selector_targets_the_caller_then_current() {
    let mut selectors = Selectors::default();
    let resolve = status_target(None, false, Some(TERM.into()), &mut selectors).unwrap();
    assert_eq!(resolve, Some(Resolve::CallerWorkspace { terminal: TERM.into() }));
    assert!(selectors.params().is_empty());

    let mut selectors = Selectors::default();
    assert_eq!(status_target(None, false, None, &mut selectors).unwrap(), None);
    assert_eq!(selectors.params()["workspace"], "current");

    let mut selectors = Selectors::default();
    assert_eq!(status_target(Some(WS), false, Some(TERM.into()), &mut selectors).unwrap(), None);
    assert_eq!(selectors.params()["workspace"], WS);

    let mut selectors = Selectors::default();
    assert!(status_target(None, false, Some("term_bad".into()), &mut selectors).is_err());
}

#[test]
fn tab_pin_zoom_and_update() {
    assert_eq!(sent(&["tab", TAB, "pin"]), ("tab.pin".into(), json!({"tab": TAB})));
    assert_eq!(sent(&["tab", TAB, "unpin"]), ("tab.unpin".into(), json!({"tab": TAB})));
    // Every zoom first reads the tab: a browser tab's page zoom is the app's.
    let zoom = plan(&["tab", TAB, "zoom", "1.5"]);
    assert_eq!(zoom.resolve, vec![Resolve::TabZoom { step: ZoomStep::Value }]);
    assert_eq!(
        sent(&["tab", TAB, "zoom", "1.5"]),
        ("tab.update".into(), json!({"tab": TAB, "zoom": 1.5}))
    );
    assert_eq!(
        sent(&["tab", TAB, "zoom", "reset"]),
        ("tab.update".into(), json!({"tab": TAB, "zoom": null}))
    );
    assert_eq!(
        plan(&["tab", TAB, "zoom", "in"]).resolve,
        vec![Resolve::TabZoom { step: ZoomStep::In }]
    );
    assert_eq!(
        plan(&["tab", TAB, "update", "--clear-zoom"]).resolve,
        vec![Resolve::TabZoom { step: ZoomStep::Reset }]
    );
    // The shorthand fills `current`.
    assert_eq!(sent(&["tab", "pin"]).1["tab"], "current");
    // The CLI never writes a browser tab's history.
    let _ = rejects(&["tab", TAB, "update", "--back", "https://a.example"]);
    assert!(rejects(&["tab", TAB, "update", "--zoom", "1", "--back", "x"]).contains("--back"));
    assert!(rejects(&["tab", TAB, "zoom", "9"]).contains("0.25"));
    assert!(rejects(&["tab", TAB, "update"]).contains("--zoom"));
}

#[test]
fn tab_groups_use_v2_operations_with_name_lookups() {
    let created = plan(&[
        "tab",
        "group",
        "create",
        "--tabs",
        &format!("{TAB},{TAB2}"),
        "--name",
        "agents",
        "--color",
        "green",
    ]);
    assert_eq!(created.operation.name().unwrap(), "tab_group.create");
    assert_eq!(created.params["tabs"], json!([TAB, TAB2]));
    assert!(created.resolve.is_empty());

    let cases: Vec<(Vec<&str>, &str, Value)> = vec![
        (vec!["tab", "group", "list", "--pane", PANE], "tab_group.list", json!({"pane_id": PANE})),
        (vec!["tab", "group", "agents", "show"], "tab_group.get", json!({"tab_group": "agents"})),
        (
            vec!["tab", "group", "agents", "update", "--collapse", "--color", "red"],
            "tab_group.update",
            json!({"tab_group": "agents", "collapsed": true, "color": "red"}),
        ),
        (
            vec!["tab", "group", "agents", "add", "--tabs", TAB, "--index", "0"],
            "tab_group.add_tabs",
            json!({"tab_group": "agents", "tabs": [TAB], "index": 0}),
        ),
        (
            vec!["tab", "group", "remove", "--tabs", TAB],
            "tab_group.remove_tabs",
            json!({"tabs": [TAB]}),
        ),
        (
            vec!["tab", "group", "agents", "move", "--pane", PANE, "--index", "2"],
            "tab_group.move",
            json!({"tab_group": "agents", "pane_id": PANE, "index": 2}),
        ),
        (
            vec!["tab", "group", "agents", "ungroup"],
            "tab_group.ungroup",
            json!({"tab_group": "agents"}),
        ),
        (
            vec!["tab", "group", "agents", "close"],
            "tab_group.close",
            json!({"tab_group": "agents"}),
        ),
    ];
    for (args, operation, params) in cases {
        let resolved = plan(&args);
        assert_eq!(sent(&args), (operation.to_string(), params), "{args:?}");
        let lookups = resolved.resolve;
        if args[2] == "agents" {
            assert_eq!(lookups, vec![state_name("tab_group", Op::TabGroupList)], "{args:?}");
        } else {
            assert!(lookups.is_empty(), "{args:?}");
        }
    }
    // Nested under a pane, a group operation still sends no topology selector.
    let nested = sent(&["pane", PANE, "tab", "group", "agents", "close"]);
    assert_eq!(nested.1, json!({"tab_group": "agents"}));

    assert!(rejects(&["tab", "group", "create", "--tabs", "4"]).contains("tab_"));
    assert!(
        rejects(&["tab", "group", "create", "--tabs", TAB, "--color", "mauve"]).contains("--color")
    );
    assert!(rejects(&["tab", "group", "agents", "update"]).contains("--name"));
    assert!(rejects(&["tab", "group", "agents", "explode"]).contains("tab group"));
}

#[test]
fn saved_tab_groups_are_room_scoped() {
    let saved = plan(&["tab", "group", "agents", "save", "--room", "Work"]);
    assert_eq!(saved.operation.name().unwrap(), "saved_tab_group.save");
    assert_eq!(saved.params["tab_group"], "agents");
    assert_eq!(saved.params["room"], "Work");
    assert_eq!(
        saved.resolve,
        vec![state_name("tab_group", Op::TabGroupList), state_name("room", Op::RoomList)]
    );
    assert_eq!(
        sent(&["tab", "group", "saved", "list", "--room", "Work"]),
        ("saved_tab_group.list".into(), json!({"room": "Work"}))
    );
    assert_eq!(
        sent(&["tab", "group", "saved", "s1", "reopen"]),
        ("saved_tab_group.reopen".into(), json!({"saved_tab_group": "s1"}))
    );
    assert_eq!(
        sent(&["tab", "group", "saved", "s1", "reopen", "--pane", PANE]).1,
        json!({"saved_tab_group": "s1", "pane_id": PANE})
    );
    assert_eq!(
        sent(&["tab", "group", "saved", "s1", "delete"]),
        ("saved_tab_group.delete".into(), json!({"saved_tab_group": "s1"}))
    );
}

#[test]
fn tab_group_moves_without_a_v2_operation_stay_private() {
    let args =
        ["tab", "group", "g1", "split", "--pane", PANE, "--edge", "right"].map(str::to_string);
    let Ok(CommandPlan::RawCommand(raw)) = parse(&args, Surface::Cmux) else {
        panic!("split is not a private command");
    };
    assert_eq!(raw.request["cmd"], "move-tab-group-to-split");
    assert_eq!(raw.request["group"], "g1");
}

#[test]
fn workspace_groups_resolve_group_and_room_names() {
    let update = plan(&[
        "workspace",
        "group",
        "Backend",
        "update",
        "--room",
        "Work",
        "--clear-color",
        "--expand",
    ]);
    assert_eq!(update.operation.name().unwrap(), "workspace_group.update");
    assert_eq!(update.params["color"], Value::Null);
    assert_eq!(update.params["collapsed"], false);
    assert_eq!(
        update.resolve,
        vec![
            state_name("workspace_group", Op::WorkspaceGroupList),
            state_name("room", Op::RoomList)
        ]
    );
    let add = plan(&["workspace", "group", "Backend", "add", "--workspace", WS]);
    assert_eq!(add.operation.name().unwrap(), "workspace.place");
    assert_eq!(add.resolve, vec![state_name("group", Op::WorkspaceGroupList)]);
    assert_eq!(
        sent(&["workspace", "placement", "list"]),
        ("workspace.placement.list".into(), json!({}))
    );
}

#[test]
fn rooms_map_to_room_operations() {
    let cases: Vec<(Vec<&str>, &str, Value)> = vec![
        (vec!["room", "list"], "room.list", json!({})),
        (
            vec![
                "room",
                "create",
                "--name",
                "Work",
                "--color",
                "blue",
                "--icon",
                "briefcase",
                "--theme",
                "dark",
                "--index",
                "1",
            ],
            "room.create",
            json!({"name": "Work", "color": "blue", "icon": "briefcase", "theme": "dark", "index": 1}),
        ),
        (
            vec![
                "room",
                "Work",
                "update",
                "--name",
                "Job",
                "--clear-color",
                "--icon",
                "bag",
                "--clear-theme",
                "--browser-profile",
                "p1",
                "--clear-default-session",
            ],
            "room.update",
            json!({
                "room": "Work", "name": "Job", "color": null, "icon": "bag", "theme": null,
                "browser_profile_id": "p1", "default_session_id": null,
            }),
        ),
        (
            vec!["room", "Work", "delete", "--move-to", "Home"],
            "room.delete",
            json!({"room": "Work", "move_to": "Home"}),
        ),
        (
            vec!["room", "Work", "move", "--index", "0"],
            "room.move",
            json!({"room": "Work", "index": 0}),
        ),
        (
            vec!["room", "Work", "follow", "--sessions", "s1,s2"],
            "room.follow",
            json!({"room": "Work", "sessions": ["s1", "s2"]}),
        ),
        (
            vec!["room", "Work", "follow", "--sessions", ""],
            "room.follow",
            json!({"room": "Work", "sessions": []}),
        ),
        (
            vec!["room", "Work", "pin", "--workspace", WS],
            "room.pin",
            json!({"room": "Work", "workspace": WS}),
        ),
        (
            vec!["room", "unpin", "--workspace", "current"],
            "room.unpin",
            json!({"workspace": "current"}),
        ),
    ];
    for (args, operation, params) in cases {
        assert_eq!(sent(&args), (operation.to_string(), params), "{args:?}");
    }
    let deleted = plan(&["room", "Work", "delete", "--move-to", "Home"]);
    assert_eq!(
        deleted.resolve,
        vec![state_name("room", Op::RoomList), state_name("move_to", Op::RoomList)]
    );
    assert!(rejects(&["room", "Work", "update"]).contains("change flag"));
    assert!(rejects(&["room", "Work", "pin"]).contains("--workspace"));
}

#[test]
fn screen_metadata_and_groups() {
    let both = format!("{SCREEN},{SCREEN2}");
    let cases: Vec<(Vec<&str>, &str, Value)> = vec![
        (vec!["screen", SCREEN, "pin"], "screen.update", json!({"screen": SCREEN, "pinned": true})),
        (
            vec!["screen", SCREEN, "unpin"],
            "screen.update",
            json!({"screen": SCREEN, "pinned": false}),
        ),
        (
            vec!["screen", SCREEN, "update", "--color", "red", "--clear-icon"],
            "screen.update",
            json!({"screen": SCREEN, "color": "red", "icon": null}),
        ),
        (
            vec!["screen", SCREEN, "move", "--index", "3"],
            "screen.move",
            json!({"screen": SCREEN, "index": 3}),
        ),
        (vec!["screen", "group", "list"], "screen_group.list", json!({})),
        (
            vec!["workspace", WS, "screen", "group", "list"],
            "screen_group.list",
            json!({"workspace": WS}),
        ),
        (
            vec!["screen", "group", "create", "--screens", &both, "--name", "infra"],
            "screen_group.create",
            json!({"screens": [SCREEN, SCREEN2], "name": "infra"}),
        ),
        (
            vec!["screen", "group", "infra", "show"],
            "screen_group.get",
            json!({"screen_group": "infra"}),
        ),
        (
            vec!["screen", "group", "infra", "update", "--name", "ops"],
            "screen_group.update",
            json!({"screen_group": "infra", "name": "ops"}),
        ),
        (
            vec!["screen", "group", "infra", "add", "--screens", SCREEN],
            "screen_group.add_screens",
            json!({"screen_group": "infra", "screens": [SCREEN]}),
        ),
        (
            vec!["screen", "group", "remove", "--screens", SCREEN],
            "screen_group.remove_screens",
            json!({"screens": [SCREEN]}),
        ),
        (
            vec!["screen", "group", "infra", "ungroup"],
            "screen_group.ungroup",
            json!({"screen_group": "infra"}),
        ),
        // Nested under a workspace, a non-list group operation drops the selector.
        (
            vec!["workspace", WS, "screen", "group", "infra", "ungroup"],
            "screen_group.ungroup",
            json!({"screen_group": "infra"}),
        ),
    ];
    for (args, operation, params) in cases {
        assert_eq!(sent(&args), (operation.to_string(), params), "{args:?}");
    }
    assert!(rejects(&["screen", SCREEN, "move"]).contains("--index"));
    assert!(rejects(&["screen", SCREEN, "update"]).contains("change flag"));
}

#[test]
fn closed_history_lists_and_reopens() {
    assert_eq!(sent(&["closed", "list"]), ("closed.list".into(), json!({})));
    assert_eq!(sent(&["closed", "ls"]), ("closed.list".into(), json!({})));
    assert_eq!(
        sent(&["closed", "c1", "reopen"]),
        ("closed.reopen".into(), json!({"closed": "c1"}))
    );
    assert!(rejects(&["closed", "c1", "explode"]).contains("closed"));
}

/// `closed-history-v2`: window scope, list limit, Reopen Closed without an
/// id (Cmd-Shift-T) and partial reopen of chosen members.
#[test]
fn closed_history_scopes_to_a_window_and_reopens_groups() {
    assert_eq!(
        sent(&["closed", "list", "--window", "inst/win", "--limit", "5"]),
        ("closed.list".into(), json!({"window": "inst/win", "limit": 5}))
    );
    assert_eq!(
        sent(&["closed", "reopen", "--window", "inst/win"]),
        ("closed.reopen".into(), json!({"window": "inst/win"}))
    );
    assert_eq!(sent(&["closed", "reopen"]), ("closed.reopen".into(), json!({})));
    assert_eq!(
        sent(&["closed", "c1", "reopen", "--members", "0,2"]),
        ("closed.reopen".into(), json!({"closed": "c1", "members": [0, 2]}))
    );
    assert!(rejects(&["closed", "c1", "reopen", "--members", "x"]).contains("--members"));
    assert!(rejects(&["closed", "list", "--limit", "0"]).contains("--limit"));
}

#[test]
fn every_state_mutation_takes_an_explicit_idempotency_key() {
    let args = ["room", "Work", "move", "--index", "1", "--idempotency-key", "mutation_retry"]
        .map(str::to_string);
    let Ok(CommandPlan::Protocol(plan)) = parse(&args, Surface::Cmux) else {
        panic!("room move did not parse");
    };
    assert_eq!(plan.idempotency_key.as_deref(), Some("mutation_retry"));
}
