use serde_json::{Value, json};

use crate::app_ops::call;

const HOME: &str = "/Users/you";

fn run(op: &str, request: Value) -> Value {
    call(op, &request).expect("op answers")
}

fn paths(reply: &Value) -> Vec<String> {
    reply["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["path"].as_str().unwrap().to_string())
        .collect()
}

fn groups(root: Value) -> Value {
    run("layout.workspace_groups", json!({"root": root}))
}

fn find(config: &Value, directory: Option<&str>) -> Value {
    run(
        "layout.workspace_group_entry",
        json!({"config": config, "directory": directory, "home": HOME}),
    )
}

#[test]
fn an_entry_holds_the_groups_settings() {
    let reply = groups(json!({"workspaceGroups": {"newWorkspacePlacement": "top", "byCwd": {
        "~/manaflow/cmux": {"color": "#7a4fd8", "icon": "ladybug.fill", "newWorkspacePlacement": "end",
            "contextMenu": [{"action": "newWorktree", "title": "New Worktree"}, {"action": "newWorkspace"}]}}}}));
    assert_eq!(reply["config"]["newWorkspacePlacement"], "top");
    let found = find(&reply["config"], Some("/Users/you/manaflow/cmux"));
    assert_eq!(found["key"], "~/manaflow/cmux");
    assert_eq!(found["entry"]["color"], "#7A4FD8");
    assert_eq!(found["entry"]["icon"], "ladybug.fill");
    assert_eq!(found["entry"]["newWorkspacePlacement"], "end");
    assert_eq!(
        found["entry"]["contextMenu"],
        json!([{"action": "newWorktree", "title": "New Worktree"}, {"action": "newWorkspace", "title": null}])
    );
    assert!(paths(&reply).is_empty());
}

#[test]
fn a_folder_key_matches_its_subfolders_and_the_longest_key_wins() {
    let config = groups(json!({"workspaceGroups": {"byCwd": {
        "~/projects": {"icon": "a"}, "~/projects/cmux": {"icon": "b"}, "~/projects/c*": {"icon": "c"}}}}))["config"].clone();
    let key = |dir: Option<&str>| find(&config, dir)["key"].clone();
    assert_eq!(key(Some("/Users/you/projects/cmux/web")), "~/projects/cmux");
    assert_eq!(key(Some("/Users/you/projects/cli")), "~/projects/c*");
    assert_eq!(key(Some("/Users/you/projects/other")), "~/projects");
    assert_eq!(
        key(Some("/Users/you/projectsX")),
        Value::Null,
        "a folder key is not a string prefix"
    );
    assert_eq!(key(None), Value::Null);
}

#[test]
fn placement_falls_back_to_the_global_then_the_end() {
    let config = groups(json!({"workspaceGroups": {"byCwd": {"/work/a": {"newWorkspacePlacement": "top"}, "/work/b": {}}}}))["config"].clone();
    assert_eq!(find(&config, Some("/work/a"))["placement"], "top");
    assert_eq!(find(&config, Some("/work/b"))["placement"], "end");
    assert_eq!(find(&config, Some("/work/b"))["configuredPlacement"], Value::Null);
    let mut global = config;
    global["newWorkspacePlacement"] = json!("afterCurrent");
    assert_eq!(find(&global, Some("/work/b"))["placement"], "afterCurrent");
}

#[test]
fn bad_values_are_dropped_with_a_diagnostic() {
    let reply = groups(json!({"workspaceGroups": {"newWorkspacePlacement": "middle", "byCwd": {
        "/w": {"color": "plaid", "icon": "x", "contextMenu": [{"title": "no action"}]}}}}));
    let entry = &reply["config"]["byCwd"]["/w"];
    assert_eq!(entry["color"], Value::Null);
    assert_eq!(entry["icon"], "x", "the rest of the entry stays");
    assert_eq!(entry["contextMenu"], json!([]));
    let paths = paths(&reply);
    for want in [
        "workspaceGroups.newWorkspacePlacement",
        "workspaceGroups.byCwd./w.color",
        "workspaceGroups.byCwd./w.contextMenu.0",
    ] {
        assert!(paths.iter().any(|p| p == want), "{want} in {paths:?}");
    }
    assert_eq!(reply["diagnostics"][0]["message"], "expected one of afterCurrent, top, end");
}

#[test]
fn colors_take_tokens_none_and_hex() {
    let color = |wire: &str| {
        groups(json!({"workspaceGroups": {"byCwd": {"/w": {"color": wire}}}}))["config"]["byCwd"]["/w"]["color"].clone()
    };
    assert_eq!(color("blue"), "blue");
    assert_eq!(color("none"), "none");
    assert_eq!(color("#abc"), "#AABBCC");
    assert_eq!(color("#11223344"), "#112233");
    assert_eq!(color("7A4FD8"), Value::Null, "a custom color needs the #");
}

#[test]
fn a_new_entrys_key_writes_the_home_folder_as_tilde() {
    let key = |dir: &str| {
        run("layout.workspace_group_key", json!({"directory": dir, "home": HOME}))["key"].clone()
    };
    assert_eq!(key("/Users/you/manaflow/cmux/"), "~/manaflow/cmux");
    assert_eq!(key("/Users/you"), "~");
    assert_eq!(key("/opt/work"), "/opt/work");
}

#[test]
fn a_glob_is_fnmatch() {
    let config =
        groups(json!({"workspaceGroups": {"byCwd": {"/w/[ab]?/*x": {"icon": "g"}}}}))["config"]
            .clone();
    assert_eq!(find(&config, Some("/w/a1/deep/x"))["key"], "/w/[ab]?/*x");
    assert_eq!(find(&config, Some("/w/c1/x"))["key"], Value::Null);
}

fn chrome(layout: Value) -> Value {
    run("layout.pane_chrome", json!({"root": {"layout": layout}}))
}

#[test]
fn pane_chrome_reads_each_member_and_clamps() {
    let reply = chrome(
        json!({"panePadding": 40, "paneCornerRadius": 6, "cornerPadding": 3, "paneBorder": "none",
        "paneSeparation": "cards", "paneBorderWidth": 0.1, "paneBorderColor": "#FF000080"}),
    );
    let o = &reply["overrides"];
    assert_eq!(o["padding"], 16.0);
    assert_eq!(o["cornerRadius"], 6.0);
    assert_eq!(o["cornerPadding"], 3.0);
    assert_eq!(o["border"], "none");
    assert_eq!(o["separation"], "cards");
    assert_eq!(o["borderWidth"], 0.5);
    assert_eq!(o["borderColor"]["red"], 1.0);
    assert!((o["borderColor"]["alpha"].as_f64().unwrap() - 128.0 / 255.0).abs() < 1e-12);
    assert_eq!(reply["diagnostics"][0]["message"], "clamped to 0...16 points");
    assert_eq!(reply["diagnostics"][1]["message"], "clamped to 0...4 points");
}

#[test]
fn pane_chrome_bad_values_are_skipped() {
    let reply = chrome(
        json!({"panePadding": "wide", "paneBorder": "thick", "paneSeparation": "x", "paneBorderColor": "red"}),
    );
    assert_eq!(reply["overrides"], json!({}));
    let messages: Vec<&str> = reply["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["message"].as_str().unwrap())
        .collect();
    assert_eq!(
        messages,
        [
            "expected a number of points",
            "expected \"subtle\" or \"none\"",
            "expected one of \"none\", \"dividers\", \"borders\", \"cards\"",
            "expected \"#RRGGBB\" or \"#RRGGBBAA\"",
        ]
    );
    let reply = run("layout.pane_chrome", json!({"root": {"layout": 3}}));
    assert_eq!(paths(&reply), ["layout"]);
}

fn tab_bar(root: Value) -> Value {
    run("layout.surface_tab_bar", json!({"root": root, "configDirectory": "/cfg", "home": HOME}))
}

#[test]
fn tab_bar_buttons_resolve_actions_built_ins_and_inline_commands() {
    let reply = tab_bar(json!({
    "actions": {"build": {"command": " make ", "tooltip": "Build", "icon": {"type": "image", "path": "../i/b.png"}},
                "claude": {"agent": "claudeCode", "args": "--x", "target": "currentTerminal"}},
    "ui": {"surfaceTabBar": {"buttons": [
        "build", "splitRight", "cmux.cloudvm", "someRegistryId",
        {"builtin": "newBrowser", "id": "web", "title": "Web"},
        {"command": "ls", "id": "ls"},
        {"agent": "opencode", "icon": "bolt"}
    ]}}}));
    let buttons = reply["tabBar"]["buttons"].as_array().unwrap();
    assert_eq!(reply["tabBar"]["usesDefaults"], false);
    assert_eq!(
        buttons[0],
        json!({"id": "build", "actionID": "cmuxConfig.build", "title": "Build", "tooltip": "Build",
        "icon": {"image": "/i/b.png"}})
    );
    assert_eq!(
        buttons[1],
        json!({"id": "cmux.splitRight", "actionID": "splitRight", "title": null, "tooltip": null,
        "icon": {"symbol": "square.split.2x1"}})
    );
    assert_eq!(buttons[2]["actionID"], "someRegistryId");
    assert_eq!(buttons[3]["id"], "web");
    assert_eq!(buttons[3]["title"], "Web");
    assert_eq!(buttons[3]["actionID"], "openBrowser");
    assert_eq!(buttons[4]["icon"], json!({"symbol": "terminal"}));
    assert_eq!(buttons[5]["id"], "agent.opencode");
    assert_eq!(buttons[5]["icon"], json!({"symbol": "bolt"}));
    let names: Vec<&str> =
        reply["actions"].as_array().unwrap().iter().map(|a| a["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["agent.opencode", "build", "claude", "ls"]);
    let claude = &reply["actions"][2];
    assert_eq!(claude["command"], "claude --x");
    assert_eq!(claude["target"], "currentTerminal");
    let kinds: Vec<&str> = reply["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["removed_setting", "unknown_action"]);
    assert_eq!(reply["diagnostics"][0]["message"], "ignored: the tab bar buttons were removed");
}

#[test]
fn tab_bar_refusals() {
    let reply = tab_bar(json!({"surfaceTabBarButtons": [
        " ", 3, {"action": "a", "builtin": "b"}, {"type": "workspace"}, {"builtin": "nope"}, {"title": "x"},
        {"command": "x", "id": "d"}, {"command": "y", "id": "d"}, {"agent": "a b"}]}));
    assert_eq!(reply["tabBar"]["buttons"].as_array().unwrap().len(), 1);
    let messages: Vec<&str> = reply["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["message"].as_str().unwrap())
        .collect();
    assert_eq!(
        messages,
        [
            "ignored: the tab bar buttons were removed",
            "blank button",
            "expected a string or an object",
            "define only one of action, builtin",
            "workspace buttons are not supported in cmux-next yet",
            "unknown built-in",
            "button needs action, builtin, command, or agent",
            "duplicate button id 'd'",
            "agent must be one command name; put flags in args",
        ]
    );
    assert_eq!(reply["diagnostics"][1]["path"], "surfaceTabBarButtons.0");
}

#[test]
fn no_buttons_key_is_the_defaults() {
    let reply = tab_bar(json!({"actions": {"bad": 1, "t": {"type": "tmux"}}}));
    assert_eq!(reply["tabBar"], json!({"buttons": [], "usesDefaults": true}));
    assert_eq!(paths(&reply), ["actions.bad", "actions.t.type"]);
}
