//! `shutdown-daemon` with `end_terminals` and `keep_layout`
//! (`end-terminals-keep-layout-v1`): placed terminals keep their tabs across
//! the handoff.

use super::*;

/// `shutdown-daemon` with `end_terminals` and `keep_layout` ends every host
/// but keeps each placed terminal's tab: the next owner shows the same
/// screens, splits, ratios and tab identities, each tab dead so a frontend
/// can start a new shell in it. A terminal without a tab still ends
/// outright.
#[test]
fn shutdown_daemon_end_terminals_keep_layout_keeps_tabs_across_restart() {
    let mut harness = RecoveryHarness::start("shutdown-keep-layout");
    request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": "kept",
        }),
    );
    let kept_workspace = |tree: &serde_json::Value| {
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["name"] == "kept")
            .cloned()
            .expect("the kept workspace is missing")
    };
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let pane = kept_workspace(&tree)["screens"][0]["panes"][0]["id"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 3, "cmd": "split", "pane": pane, "dir": "right"}),
    );
    let (detached, _) = run_cat_workspace(&harness.socket, 4, "detached");
    request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "set-terminal-keep", "terminal_id": detached, "keep": true}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 6, "cmd": "list-workspaces"}));
    let detached_surface = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "detached")
        .and_then(first_tab)
        .and_then(|tab| tab["surface"].as_u64())
        .unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 7, "cmd": "close-surface", "surface": detached_surface}),
    );
    wait_for_host_records(&harness.host_root(), 3);
    let tree = request(&harness.socket, serde_json::json!({"id": 8, "cmd": "list-workspaces"}));
    let before = kept_workspace(&tree);
    // Numeric pane and split handles are per owner; compare durable ids and
    // the split shape (direction and ratio).
    let layout = |workspace: &serde_json::Value| {
        workspace["screens"]
            .as_array()
            .unwrap()
            .iter()
            .map(|screen| {
                let shape = serde_json::json!({
                    "type": screen["layout"]["type"],
                    "dir": screen["layout"]["dir"],
                    "ratio": screen["layout"]["ratio"],
                });
                let tabs = screen["panes"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|pane| {
                        (
                            pane["resource_id"].clone(),
                            pane["tabs"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .map(|tab| tab["tab_resource_id"].clone())
                                .collect::<Vec<_>>(),
                        )
                    })
                    .collect::<Vec<_>>();
                (screen["resource_id"].clone(), shape, tabs)
            })
            .collect::<Vec<_>>()
    };
    let expected = layout(&before);
    assert_eq!(expected[0].2.len(), 2, "the split did not make a second pane: {before}");

    let identify = request(&harness.socket, serde_json::json!({"id": 9, "cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "end-terminals-keep-layout-v1"),
        "{identify}"
    );
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 10,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "end_terminals": true,
            "keep_layout": true,
        }),
    );
    assert_eq!(accepted["accepted"], true);
    assert_eq!(accepted["ended_terminals"], 3);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after shutdown");
        std::thread::sleep(Duration::from_millis(10));
    }
    wait_for_no_host_records(&harness.host_root());

    harness.restart();
    let tree = request(&harness.socket, serde_json::json!({"id": 11, "cmd": "list-workspaces"}));
    let after = kept_workspace(&tree);
    assert_eq!(after["resource_id"], before["resource_id"]);
    assert_eq!(layout(&after), expected, "the layout changed across the restart: {after}");
    for screen in after["screens"].as_array().unwrap() {
        for pane in screen["panes"].as_array().unwrap() {
            for tab in pane["tabs"].as_array().unwrap() {
                assert_eq!(tab["dead"], true, "a kept tab came back live: {tab}");
                // The workspace store's keep-layout record, with the shell's
                // directory recorded by the session host before it ended.
                assert!(
                    tab["relaunch"]["cwd"].is_string(),
                    "a kept tab has no relaunch record: {tab}"
                );
            }
        }
    }
    // A frontend restarts a kept tab by opening a new tab next to it and
    // closing the dead one, which has no runtime surface after the restart.
    let kept_surface = after["screens"][0]["panes"][1]["tabs"][0]["surface"].as_u64().unwrap();
    let pane = after["screens"][0]["panes"][1]["id"].as_u64().unwrap();
    request(&harness.socket, serde_json::json!({"id": 13, "cmd": "new-tab", "pane": pane}));
    request(
        &harness.socket,
        serde_json::json!({"id": 14, "cmd": "close-surface", "surface": kept_surface}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 15, "cmd": "list-workspaces"}));
    let tabs = kept_workspace(&tree)["screens"][0]["panes"][1]["tabs"].clone();
    assert_eq!(tabs.as_array().unwrap().len(), 1, "{tabs}");
    assert_eq!(tabs[0]["dead"], false, "{tabs}");
    assert!(tabs[0]["relaunch"].is_null(), "a new tab carries a relaunch record: {tabs}");
    let resolved = request_response(
        &harness.socket,
        serde_json::json!({"id": 12, "cmd": "resolve-terminal", "terminal_id": detached}),
    );
    assert_ne!(
        resolved["data"]["lifecycle"], "running",
        "the unplaced terminal survived: {resolved}"
    );
}

/// Without `end_terminals`, `keep_layout` is refused: it only describes how
/// terminals end.
#[test]
fn shutdown_daemon_keep_layout_requires_end_terminals() {
    let harness = RecoveryHarness::start("shutdown-keep-layout-alone");
    let identify = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    let response = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "keep_layout": true,
        }),
    );
    assert_eq!(response["ok"], false, "{response}");
    let ping = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "ping"}));
    assert_eq!(ping["ok"], true);
}

/// A kept tab keeps its last known name and title across the handoff: the
/// restarted owner has no surface behind it, so the tree reports the tab
/// resource's name and the title its terminal had when it ended, not an
/// empty tab a frontend can only show blank.
#[test]
fn shutdown_daemon_keep_layout_keeps_the_dead_tab_name_and_title_across_restart() {
    let mut harness = RecoveryHarness::start("shutdown-keep-layout-title");
    request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true, "name": "named",
        }),
    );
    request(
        &harness.socket,
        serde_json::json!({
            "id": 2, "cmd": "run", "new_workspace": true, "name": "titled",
            "argv": ["/bin/sh", "-c", "printf '\\033]2;kept title\\007'; exec cat"],
        }),
    );
    let tab_of = |tree: &serde_json::Value, name: &str| {
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .find(|workspace| workspace["name"] == name)
            .and_then(first_tab)
            .cloned()
            .unwrap_or_else(|| panic!("workspace {name} has no tab: {tree}"))
    };
    let tree = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
    let named_surface = tab_of(&tree, "named")["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "rename-surface", "surface": named_surface, "name": "kept name"}),
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = request(&harness.socket, serde_json::json!({"id": 5, "cmd": "list-workspaces"}));
        if tab_of(&tree, "titled")["title"] == "kept title"
            && tab_of(&tree, "named")["name"] == "kept name"
        {
            break;
        }
        assert!(Instant::now() < deadline, "the live tabs never showed their name and title: {tree}");
        std::thread::sleep(Duration::from_millis(20));
    }

    let identify = request(&harness.socket, serde_json::json!({"id": 6, "cmd": "identify"}));
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 7,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "end_terminals": true,
            "keep_layout": true,
        }),
    );
    assert_eq!(accepted["accepted"], true);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after shutdown");
        std::thread::sleep(Duration::from_millis(10));
    }
    wait_for_no_host_records(&harness.host_root());

    harness.restart();
    let tree = request(&harness.socket, serde_json::json!({"id": 8, "cmd": "list-workspaces"}));
    let named = tab_of(&tree, "named");
    let titled = tab_of(&tree, "titled");
    for tab in [&named, &titled] {
        assert_eq!(tab["dead"], true, "a kept tab came back live: {tab}");
        assert!(tab["relaunch"]["cwd"].is_string(), "a kept tab has no relaunch record: {tab}");
    }
    assert_eq!(named["name"], "kept name", "the restored dead tab lost its name: {named}");
    assert_eq!(titled["title"], "kept title", "the restored dead tab lost its title: {titled}");
}
