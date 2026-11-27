//! Parity with HomeLoneDockTests, HomeDockAllowTabsTests and HomeDock's connect steps, through the
//! `dock.*` op table.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: &Value) -> Value {
    call(&format!("dock.{name}"), request).unwrap_or_else(|err| panic!("dock.{name}: {err}"))
}

fn shell(surface: u64, cwd: Option<&str>, title: &str) -> Value {
    json!({"id": format!("t{surface}"), "surface": surface, "kind": "pty", "cwd": cwd, "title": title})
}

fn page() -> Value {
    json!({"id": "t1", "surface": 1, "kind": "conversation", "page": "home-dock", "title": "Home"})
}

/// HomeLoneDockTests.home: Home's page in a pinned left dock (pane 1), tabs `right` in pane 2.
fn home(right: Option<Vec<Value>>, in_dock: Vec<Value>) -> Value {
    let dock = json!({"edge": "left", "role": "agentChat", "isPinned": true, "allowsTabs": !in_dock.is_empty()});
    let mut columns = vec![json!({"paneIDs": [1], "dock": dock})];
    let mut tabs = vec![page()];
    tabs.extend(in_dock);
    let mut panes = vec![json!({"handle": 1, "tabs": tabs})];
    if let Some(right) = right {
        columns.push(json!({"paneIDs": [2]}));
        panes.push(json!({"handle": 2, "tabs": right}));
    }
    json!({"kind": "home", "screens": [{"columns": columns, "panes": panes}]})
}

fn placeholder(right: Option<Vec<Value>>) -> Value {
    let workspace = home(right, Vec::new());
    op("placeholder_shell", &json!({"screen": workspace["screens"][0], "home": "/Users/me"}))
}

#[test]
fn the_restored_placeholder_shell_is_the_only_right_tab_that_closes() {
    assert_eq!(placeholder(Some(vec![shell(2, Some("/Users/me"), "~")])), json!(2));
    assert_eq!(placeholder(Some(vec![shell(2, Some("/Users/me/"), "")])), json!(2));
    assert_eq!(placeholder(Some(vec![shell(2, None, "~")])), Value::Null, "unknown folder");
    assert_eq!(
        placeholder(Some(vec![shell(2, Some("/Users/me/src/cmux"), "cmux")])),
        Value::Null,
        "moved on"
    );
    assert_eq!(
        placeholder(Some(vec![shell(2, Some("/Users/me"), "~"), shell(3, Some("/Users/me"), "~")])),
        Value::Null,
        "two tabs are the person's"
    );
    let browser = json!({"id": "t2", "surface": 2, "kind": "browser", "title": "~"});
    assert_eq!(placeholder(Some(vec![browser])), Value::Null);
    let mut named = shell(2, Some("/Users/me"), "~");
    named["name"] = json!("server");
    assert_eq!(placeholder(Some(vec![named])), Value::Null);
    let mut dead = shell(2, Some("/Users/me"), "~");
    dead["dead"] = json!(true);
    assert_eq!(placeholder(Some(vec![dead])), Value::Null);
    assert_eq!(placeholder(None), Value::Null, "a lone dock has nothing to close");
}

#[test]
fn a_title_padded_with_spaces_and_tabs_is_still_the_folder() {
    let tab = shell(2, Some("/Users/me"), " \t~ ");
    assert_eq!(op("is_placeholder_shell", &json!({"tab": tab, "home": "/Users/me"})), json!(true));
    let tab = shell(2, Some("/Users/me"), "~\n");
    assert_eq!(op("is_placeholder_shell", &json!({"tab": tab, "home": "/Users/me"})), json!(false));
}

#[test]
fn only_homes_own_tab_stays_in_home() {
    let chief = json!({"id": "t4", "surface": 4, "kind": "conversation", "conversation": "c1", "title": "Chief"});
    let browser = json!({"id": "t3", "surface": 3, "kind": "browser", "title": "Docs"});
    let workspace = home(Some(vec![shell(2, Some("/Users/me"), "~"), browser, chief]), Vec::new());
    let keeps = |id: &str| op("keeps_tab", &json!({"id": id, "workspace": workspace}));
    assert_eq!(keeps("t1"), json!(true));
    assert_eq!(keeps("t3"), json!(false));
    assert_eq!(keeps("t4"), json!(true), "a Chief tab is Home's wherever it is");
}

#[test]
fn a_tab_dragged_into_homes_dock_drags_out_again() {
    let workspace = home(None, vec![shell(5, Some("/Users/me"), "~")]);
    assert_eq!(op("keeps_tab", &json!({"id": "t1", "workspace": workspace})), json!(true));
    assert_eq!(op("keeps_tab", &json!({"id": "t5", "workspace": workspace})), json!(false));
}

#[test]
fn a_classic_home_keeps_every_tab() {
    let workspace = json!({"kind": "home", "screens": [{"columns": [{"paneIDs": [1]}],
        "panes": [{"handle": 1, "tabs": [shell(2, None, "x")]}]}]});
    assert_eq!(op("keeps_tab", &json!({"id": "t2", "workspace": workspace})), json!(true));
}

/// HomeDockAllowTabsTests.tree.
fn allow_tree(identified: bool) -> Value {
    let page = json!({"id": "t2", "surface": 2, "kind": "conversation", "page": "home-dock"});
    let dock = json!({"edge": "left", "role": "agentChat", "isPinned": true, "allowsTabs": false});
    let mut screen = json!({"columns": [{"paneIDs": [1], "dock": dock}], "panes": [{"handle": 1, "tabs": [page]}]});
    if identified {
        screen["resourceID"] = json!("scr_home");
        screen["panes"][0]["resourceID"] = json!("pane_home");
    }
    json!({"screens": [screen]})
}

#[test]
fn the_dock_takes_tabs_once_the_tree_reports_its_ids() {
    let caps = json!({"pinnedDock": true});
    let plan = |tree: Value| {
        op("allow_tabs_plan", &json!({"workspace": tree, "capabilities": caps, "fresh": true}))
    };
    assert_eq!(plan(allow_tree(false)), json!({"action": "waitForIds"}));
    assert_eq!(op("ids_ready", &json!({"workspace": allow_tree(false)})), Value::Null);
    assert_eq!(op("ids_ready", &json!({"workspace": allow_tree(true)})), json!(true));
    assert_eq!(
        plan(allow_tree(true)),
        json!({"action": "allow", "screen": "scr_home", "pane": "pane_home"})
    );
}

#[test]
fn the_wait_ends_when_homes_page_is_gone() {
    assert_eq!(op("ids_ready", &json!({"workspace": {"screens": []}})), json!(false));
    assert_eq!(op("ids_ready", &json!({})), json!(false));
}

#[test]
fn allow_tabs_runs_once_per_install_unless_fresh_and_needs_the_capability() {
    let tree = allow_tree(true);
    let no_caps = op("allow_tabs_plan", &json!({"workspace": tree, "fresh": true}));
    assert_eq!(no_caps, json!({"action": "none"}));
    let recorded = op(
        "allow_tabs_plan",
        &json!({"workspace": tree, "capabilities": {"pinnedDock": true}, "dockTakesTabs": true}),
    );
    assert_eq!(recorded, json!({"action": "none"}));
    let mut takes = tree;
    takes["screens"][0]["columns"][0]["dock"]["allowsTabs"] = json!(true);
    let plan = op(
        "allow_tabs_plan",
        &json!({"workspace": takes, "capabilities": {"pinnedDock": true}, "fresh": true}),
    );
    assert_eq!(plan, json!({"action": "record"}));
}

#[test]
fn ensure_creates_the_page_then_places_it_and_closes_chief_tabs() {
    assert_eq!(op("ensure_plan", &json!({})), json!({"step": "gone"}));
    assert_eq!(
        op("ensure_plan", &json!({"workspace": {"screens": []}})),
        json!({"step": "createPage"})
    );
    let chief = json!({"id": "t4", "surface": 4, "kind": "conversation", "conversation": "c1"});
    let workspace = home(Some(vec![shell(2, Some("/Users/me"), "~"), chief]), Vec::new());
    let plan = op(
        "ensure_plan",
        &json!({"workspace": workspace, "capabilities": {"pinnedDock": true, "pinnedDockAlone": true}}),
    );
    assert_eq!(
        plan,
        json!({"step": "place", "closeTabs": [4], "docked": true, "alone": true, "respawnTerminal": false, "surface": 1, "pane": 1})
    );
    // A lone dock with only Chief tabs beside it on an older daemon: nothing closes, a terminal stays.
    let workspace = home(
        Some(vec![json!({"id": "t4", "surface": 4, "kind": "conversation", "conversation": "c1"})]),
        Vec::new(),
    );
    let plan = op("ensure_plan", &json!({"workspace": workspace}));
    assert_eq!(plan["closeTabs"], json!([]));
    assert_eq!(plan["respawnTerminal"], json!(true));
}

#[test]
fn pin_moves_the_page_first_then_pins_its_column() {
    let mut workspace = home(None, vec![]);
    workspace["screens"][0]["columns"][0]["dock"]["isPinned"] = json!(false);
    workspace["screens"][0]["panes"][0]["tabs"] = json!([shell(5, None, "x"), page()]);
    let caps = json!({"pinnedDock": true});
    let plan = op("pin_plan", &json!({"workspace": workspace, "capabilities": caps}));
    assert_eq!(
        plan,
        json!({"moveFirst": true, "surface": 1, "pane": 1, "edge": "left", "role": "agentChat"})
    );
    assert_eq!(
        op("pin_plan", &json!({"workspace": home(None, vec![]), "capabilities": caps})),
        Value::Null
    );
    assert_eq!(op("pin_plan", &json!({"workspace": workspace})), Value::Null, "an older daemon");
}

#[test]
fn the_placeholder_check_runs_once() {
    let workspace = home(Some(vec![shell(2, Some("/Users/me"), "~")]), Vec::new());
    let plan = |checked: bool, ever: bool| {
        op(
            "placeholder_plan",
            &json!({"workspace": workspace, "checked": checked, "checkedEver": ever, "home": "/Users/me"}),
        )
    };
    assert_eq!(plan(false, false), json!({"markChecked": true, "close": 2}));
    assert_eq!(plan(true, false), json!({"markChecked": false, "close": null}));
    assert_eq!(plan(false, true), json!({"markChecked": false, "close": null}));
}

#[test]
fn home_reveals_when_docked_and_opens_only_web_links() {
    let workspace = home(None, Vec::new());
    assert_eq!(op("page_is_docked", &json!({"workspace": workspace})), json!(true));
    assert_eq!(op("reveal_when_docked", &json!({"workspace": workspace})), json!(true));
    assert_eq!(
        op("reveal_when_docked", &json!({"workspace": workspace, "classic": true})),
        json!(false)
    );
    assert_eq!(
        op("reveal_when_docked", &json!({"workspace": workspace, "ready": true})),
        json!(false)
    );
    let tab = op("page_tab", &json!({"workspace": workspace}));
    assert_eq!(tab["tab"]["surface"], json!(1));
    assert_eq!(tab["docked"], json!(true));
    for (scheme, opens) in [("https", true), ("HTTP", true), ("file", false), ("cmux", false)] {
        assert_eq!(op("opens_link", &json!({"scheme": scheme})), json!(opens), "{scheme}");
    }
    assert_eq!(op("opens_link", &json!({})), json!(false));
}
