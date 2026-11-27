//! `closed.delete` through the CLI and a real daemon, and the screen that
//! `closed.reopen` publishes on `session.events` (cx-gzh.24).
#![cfg(unix)]

use super::*;

/// Delete Permanently and Clear Recently Closed (`closed.delete`) through
/// the CLI and a real daemon: chosen members of a group, one group, every
/// group closed at or after `--since-ms`, and every group. A deleted group
/// cannot be reopened.
#[test]
fn state_cli_closed_delete_and_clear_through_a_real_daemon() {
    let server = HeadlessServer::start("state-cli-closed-delete");
    for name in ["alpha", "beta"] {
        state_cli(&server, None, &["workspace", "create", "--name", name, "--empty"]);
    }
    // A closed group of two tabs: one pane, three terminal tabs, two of
    // them grouped so the pane stays open.
    state_cli(&server, None, &["workspace", "create", "--name", "gamma"]);
    let gamma = workspace_id_named(&server, "gamma");
    let snapshot = state_cli_topology(&server);
    let gamma_tab = |snapshot: &serde_json::Value| -> Vec<serde_json::Value> {
        snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|terminal| {
                workspace_of_terminal(snapshot, terminal["id"].as_str().unwrap()) == gamma
            })
            .map(|terminal| terminal["tab_id"].clone())
            .collect()
    };
    let first_tab = gamma_tab(&snapshot)[0].as_str().unwrap().to_string();
    let pane = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == first_tab.as_str())
        .and_then(|tab| tab["pane_id"].as_str())
        .unwrap()
        .to_string();
    for _ in 0..2 {
        state_cli(&server, None, &["tab", "create", "terminal", "--pane", &pane]);
    }
    let tabs = gamma_tab(&state_cli_topology(&server));
    assert_eq!(tabs.len(), 3, "gamma has three terminal tabs: {tabs:?}");
    let tabs = tabs[1..].iter().map(|tab| tab.as_str().unwrap()).collect::<Vec<_>>().join(",");
    state_cli(&server, None, &["tab", "group", "create", "--tabs", &tabs, "--name", "pair"]);
    state_cli(&server, None, &["tab", "group", "pair", "close"]);
    for name in ["alpha", "beta"] {
        let workspace = workspace_id_named(&server, name);
        state_cli(&server, None, &["workspace", &workspace, "close"]);
    }
    let closed = state_cli(&server, None, &["closed", "list"]);
    let closed_id = |predicate: &dyn Fn(&serde_json::Value) -> bool| {
        closed
            .as_array()
            .unwrap()
            .iter()
            .find(|item| predicate(item))
            .and_then(|item| item["id"].as_str())
            .unwrap_or_else(|| panic!("closed history has no such group: {closed}"))
            .to_string()
    };
    let alpha = closed_id(&|item| item["kind"] == "workspace" && item["name"] == "alpha");
    let beta = closed_id(&|item| item["kind"] == "workspace" && item["name"] == "beta");
    let pair = closed_id(&|item| item["member_count"] == 2);
    let member_count = |id: &str| {
        let closed = state_cli(&server, None, &["closed", "list"]);
        closed
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == id)
            .map(|item| item["member_count"].clone())
    };

    let partial = state_cli(&server, None, &["closed", &pair, "delete", "--members", "0"]);
    assert_eq!(partial["value"]["deleted"], serde_json::json!([]), "{partial}");
    assert_eq!(partial["value"]["updated"], serde_json::json!([pair]), "{partial}");
    assert_eq!(member_count(&pair), Some(serde_json::json!(1)));

    let whole = state_cli(&server, None, &["closed", &alpha, "delete"]);
    assert_eq!(whole["value"]["deleted"], serde_json::json!([alpha]), "{whole}");
    let reopen = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["closed", &alpha, "reopen"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert!(!reopen.status.success(), "a deleted group reopened");
    assert_eq!(json_error(&reopen)["code"], "resource.not_found");

    let future = state_cli(&server, None, &["closed", "clear", "--since-ms", "99999999999999"]);
    assert_eq!(future["value"]["deleted"], serde_json::json!([]), "{future}");
    let cleared = state_cli(&server, None, &["closed", "clear"]);
    let mut deleted = cleared["value"]["deleted"].as_array().cloned().unwrap_or_default();
    deleted.sort_by_key(|id| id.to_string());
    let mut expected = vec![serde_json::json!(beta), serde_json::json!(pair)];
    expected.sort_by_key(|id| id.to_string());
    assert_eq!(deleted, expected, "{cleared}");
    assert_eq!(state_cli(&server, None, &["closed", "list"]), serde_json::json!([]));

    let bad = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["closed", "clear", "--since-ms", "soon"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert!(!bad.status.success());
    assert!(String::from_utf8_lossy(&bad.stderr).contains("--since-ms"));
}

/// A `session.events` subscription; its lines arrive on the receiver. The
/// returned writer keeps the stream's connection open.
fn session_events(server: &HeadlessServer) -> (impl Sized + use<>, mpsc::Receiver<String>) {
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stream).lines() {
            let Ok(line) = line else { break };
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "reopen-screen-events",
        "operation": "session.events",
        "params": {
            "machine": "current",
            "session": "current",
            "stream_id": "stream_44444444444444448444444444444444",
        },
    });
    writeln!(writer, "{request}").unwrap();
    writer.flush().unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let remaining =
            deadline.checked_duration_since(Instant::now()).expect("no session.events reply");
        let line = rx.recv_timeout(remaining).expect("no session.events reply");
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == "reopen-screen-events" {
            assert_eq!(message["ok"], true, "session.events failed: {message}");
            return (writer, rx);
        }
    }
}

/// The tab ids of the session snapshot.
fn tab_ids(server: &HeadlessServer) -> Vec<String> {
    state_cli_topology(server)["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tab| tab["id"].as_str().unwrap().to_string())
        .collect()
}

/// The one tab that `after` has and `before` lacks.
fn new_tab(before: &[String], after: &[String]) -> String {
    let fresh = after.iter().filter(|tab| !before.contains(tab)).collect::<Vec<_>>();
    assert_eq!(fresh.len(), 1, "expected one new tab: before={before:?} after={after:?}");
    fresh[0].clone()
}

/// Read delta items until one upserts `tab`; return the changes of that
/// item and every delta item before it since the last call.
fn changes_through_tab_upsert(rx: &mpsc::Receiver<String>, tab: &str) -> Vec<serde_json::Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = rx.recv_timeout(remaining) else { break };
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        let item = &message["item"];
        if message["type"] != "stream_item" || item["kind"] != "delta" {
            continue;
        }
        let changes = item["changes"].as_array().cloned().unwrap_or_default();
        let has_tab = changes.iter().any(|change| {
            change["kind"] == "upsert" && change["resource"] == "tab" && change["id"] == tab
        });
        seen.push(changes);
        if has_tab {
            return seen.pop().unwrap();
        }
    }
    panic!("no delta upserted tab {tab}; deltas={seen:?}");
}

/// The content id of `tab`'s upsert in `changes`.
fn tab_content(changes: &[serde_json::Value], tab: &str) -> serde_json::Value {
    changes
        .iter()
        .find(|change| change["resource"] == "tab" && change["id"] == tab)
        .map(|change| change["value"]["content_id"].clone())
        .unwrap_or_else(|| panic!("no upsert of tab {tab}: {changes:?}"))
}

/// Whether `changes` upsert a screen whose layout holds `tab`.
fn screen_holds_tab(changes: &[serde_json::Value], tab: &str) -> bool {
    changes.iter().any(|change| {
        change["kind"] == "upsert"
            && change["resource"] == "screen"
            && change["value"]["layout"].to_string().contains(&format!("\"{tab}\""))
    })
}

/// A client that builds pane tabs from the screen layout sees a reopened
/// tab at once: the delta that upserts the reopened tab also upserts its
/// screen with the tab in the layout, as for a normal `tab create`.
#[test]
fn closed_reopen_publishes_the_reopened_tab_in_its_screen_like_a_tab_create() {
    let server = HeadlessServer::start("closed-reopen-screen");
    state_cli(&server, None, &["workspace", "create", "--name", "alpha"]);
    let snapshot = state_cli_topology(&server);
    let pane = snapshot["tabs"].as_array().unwrap()[0]["pane_id"].as_str().unwrap().to_string();
    let (_stream, rx) = session_events(&server);

    let before = tab_ids(&server);
    state_cli(&server, None, &["tab", "create", "terminal", "--pane", &pane]);
    let created = new_tab(&before, &tab_ids(&server));
    let changes = changes_through_tab_upsert(&rx, &created);
    let terminal = tab_content(&changes, &created);
    assert!(
        screen_holds_tab(&changes, &created),
        "a tab create published no screen with tab {created}: {changes:?}"
    );

    state_cli(&server, None, &["tab", &created, "close"]);
    let before = tab_ids(&server);
    assert!(!before.contains(&created), "the closed tab is still open: {before:?}");
    let reopen = state_cli(&server, None, &["closed", "reopen"]);
    let reopened = new_tab(&before, &tab_ids(&server));
    assert_eq!(reopen["value"]["tab_ids"], serde_json::json!([reopened]), "{reopen}");
    let changes = changes_through_tab_upsert(&rx, &reopened);
    // The reopen gave the still-running terminal a new view
    // (`terminal.project`), not a new shell.
    assert_eq!(tab_content(&changes, &reopened), terminal, "{changes:?}");
    assert!(
        screen_holds_tab(&changes, &reopened),
        "closed.reopen published tab {reopened} with no screen that holds it: {changes:?}"
    );
}

/// A topology mutation remains replayable after the daemon restarts: the
/// workspace and its surviving terminal keep their identities while the
/// closed split tab is restored through the public CLI.
#[test]
fn split_close_and_restore_survive_a_daemon_restart() {
    split_close_and_restore_after_a_restart("split-close-restore-restart", &[]);
}

/// The restarted daemon answers before it adopted its surviving terminals
/// (81577dcd4b3, #23561): a reopen that comes while the kept terminal still
/// adopts takes that terminal once it is adopted, never a new shell.
#[test]
fn a_closed_split_reopened_while_its_kept_terminal_adopts_takes_that_terminal() {
    split_close_and_restore_after_a_restart(
        "split-close-restore-adopting",
        &[("CMUX_TUI_TEST_ADOPTION_DELAY_MS", "3000")],
    );
}

/// A start's adoptions take turns, visible workspace first (perf100,
/// startup_adoption_gate.rs, #24307). A reopen that waits on its kept
/// terminal (`wait_for_terminal_adoption`) must not wait behind the other
/// hosts' turns: that terminal adopts at once. A debug seam holds each turn
/// 5 s, and the visible workspace's ten terminals take every first turn, so
/// a reopen that waits for its terminal's turn takes 5 s or more.
#[cfg(debug_assertions)]
#[test]
fn a_reopen_during_a_restart_does_not_wait_behind_other_adoptions() {
    let mut server = HeadlessServer::start("reopen-skips-adoption-turns");
    let panes_of = |snapshot: &serde_json::Value, workspace: &str| -> Vec<String> {
        let screens: Vec<&str> = snapshot["screens"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|screen| screen["workspace_id"] == workspace)
            .filter_map(|screen| screen["id"].as_str())
            .collect();
        snapshot["panes"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|pane| screens.iter().any(|screen| pane["screen_id"] == *screen))
            .map(|pane| pane["id"].as_str().unwrap().to_string())
            .collect()
    };
    let terminal_of_pane = |snapshot: &serde_json::Value, pane: &str| -> String {
        let tab = snapshot["tabs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|tab| tab["pane_id"] == pane)
            .and_then(|tab| tab["id"].as_str())
            .unwrap()
            .to_string();
        snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["tab_id"] == tab.as_str())
            .and_then(|terminal| terminal["id"].as_str())
            .unwrap()
            .to_string()
    };

    // A closed split whose terminal is kept.
    state_cli(&server, None, &["workspace", "create", "--name", "survivor"]);
    let survivor = workspace_id_named(&server, "survivor");
    let source_pane = panes_of(&state_cli_topology(&server), &survivor)[0].clone();
    state_cli(&server, None, &["pane", &source_pane, "split", "--right"]);
    let split = state_cli_topology(&server);
    let split_pane = panes_of(&split, &survivor)
        .into_iter()
        .find(|pane| *pane != source_pane)
        .expect("split did not create a pane");
    let split_terminal = terminal_of_pane(&split, &split_pane);
    state_cli(&server, None, &["terminal", &split_terminal, "keep", "on"]);
    state_cli(&server, None, &["pane", &split_pane, "close"]);
    let closed = state_cli(&server, None, &["closed", "list"]);
    let closed_id = closed[0]["id"].as_str().unwrap().to_string();

    // The user looks at another workspace with ten terminals: they adopt
    // first and take every turn the gate has (8).
    state_cli(&server, None, &["workspace", "create", "--name", "busy"]);
    let busy = workspace_id_named(&server, "busy");
    let busy_pane = panes_of(&state_cli_topology(&server), &busy)[0].clone();
    for _ in 0..9 {
        state_cli(&server, None, &["tab", "create", "terminal", "--pane", &busy_pane]);
    }
    let tree =
        json_socket_request(&server.socket, serde_json::json!({"id": 1, "cmd": "list-workspaces"}));
    let busy_index = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .position(|workspace| workspace["name"] == "busy")
        .expect("busy workspace listed");
    json_socket_request(
        &server.socket,
        serde_json::json!({"id": 2, "cmd": "select-workspace", "index": busy_index}),
    );

    server.child.kill().unwrap();
    server.child.wait().unwrap();
    server.child = Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(&server.socket)
        .arg("--state")
        .arg(&server.state)
        .env("CMUX_TUI_CONFIG", server.dir.join("config.json"))
        .env("CMUX_TUI_TEST_ADOPT_TURN_DELAY_MS", "5000")
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    server.wait_for_socket();

    let before_reopen = tab_ids(&server);
    let started = Instant::now();
    let reopened = state_cli(&server, None, &["closed", &closed_id, "reopen"]);
    let took = started.elapsed();
    let restored_tab = new_tab(&before_reopen, &tab_ids(&server));
    assert_eq!(reopened["value"]["tab_ids"], serde_json::json!([restored_tab]), "{reopened}");
    let restored = state_cli_topology(&server);
    let tab = restored["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == restored_tab.as_str())
        .expect("reopened tab is present in the snapshot");
    assert_eq!(tab["content_id"], split_terminal.as_str(), "{restored}");
    assert!(
        took < Duration::from_millis(3_000),
        "the reopen waited {took:?} for its kept terminal behind the other adoptions' turns"
    );
    // The busy workspace's terminals still adopt in held turns (two waves of
    // 5 s); the fixture can close them only once they are running.
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let terminals = state_cli(&server, None, &["terminal", "list"]);
        let all_running =
            terminals.as_array().unwrap().iter().all(|terminal| terminal["lifecycle"] == "running");
        if all_running {
            break;
        }
        assert!(Instant::now() < deadline, "terminals never adopted: {terminals}");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Splits, keeps the split's terminal, closes its pane, restarts the daemon
/// (with `restart_env`) and reopens the closed group.
fn split_close_and_restore_after_a_restart(name: &str, restart_env: &[(&str, &str)]) {
    let mut server = HeadlessServer::start(name);
    state_cli(&server, None, &["workspace", "create", "--name", "survivor"]);
    let before = state_cli_topology(&server);
    let workspace = workspace_id_named(&server, "survivor");
    let source_screen = before["screens"]
        .as_array()
        .unwrap()
        .iter()
        .find(|screen| screen["workspace_id"] == workspace.as_str())
        .and_then(|screen| screen["id"].as_str())
        .unwrap()
        .to_string();
    let source_pane = before["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["screen_id"] == source_screen.as_str())
        .and_then(|pane| pane["id"].as_str())
        .unwrap()
        .to_string();
    let source_tab = before["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["pane_id"] == source_pane.as_str())
        .and_then(|tab| tab["id"].as_str())
        .unwrap()
        .to_string();
    let source_terminal = before["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["tab_id"] == source_tab.as_str())
        .and_then(|terminal| terminal["id"].as_str())
        .unwrap()
        .to_string();

    let split_before = state_cli_topology(&server);
    state_cli(&server, None, &["pane", &source_pane, "split", "--right"]);
    let split_after = state_cli_topology(&server);
    let pane_ids = |snapshot: &serde_json::Value| {
        snapshot["panes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pane| pane["id"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    let split_pane = pane_ids(&split_after)
        .into_iter()
        .find(|pane| !pane_ids(&split_before).contains(pane))
        .expect("split did not create a pane");
    let split_tab = split_after["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["pane_id"] == split_pane.as_str())
        .and_then(|tab| tab["id"].as_str())
        .unwrap()
        .to_string();
    let split_terminal = split_after["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["tab_id"] == split_tab.as_str())
        .and_then(|terminal| terminal["id"].as_str())
        .unwrap()
        .to_string();

    // Reopening a retained terminal must reuse it regardless of the time
    // taken by the restart. Do not rely on the unplaced-terminal grace.
    state_cli(&server, None, &["terminal", &split_terminal, "keep", "on"]);
    state_cli(&server, None, &["pane", &split_pane, "close"]);
    let closed = state_cli(&server, None, &["closed", "list"]);
    let groups = closed.as_array().unwrap();
    assert_eq!(groups.len(), 1, "closing one pane must record one closed group: {closed}");
    assert_eq!(groups[0]["member_count"], 1, "{closed}");
    let closed_id = groups[0]["id"].as_str().unwrap().to_string();

    // Reopen the same daemon state through its real server entrypoint rather
    // than replacing the lifecycle with a mock.
    server.child.kill().unwrap();
    server.child.wait().unwrap();
    server.child = Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(&server.socket)
        .arg("--state")
        .arg(&server.state)
        .env("CMUX_TUI_CONFIG", server.dir.join("config.json"))
        .envs(restart_env.iter().copied())
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    server.wait_for_socket();

    let after_restart = state_cli_topology(&server);
    assert_eq!(workspace_of_terminal(&after_restart, &source_terminal), workspace);
    let panes_after_restart = pane_ids(&after_restart);
    assert_eq!(panes_after_restart.len(), 1, "{after_restart}");
    assert_eq!(panes_after_restart[0], source_pane, "{after_restart}");
    let tabs_after_restart = tab_ids(&server);
    assert_eq!(tabs_after_restart.len(), 1, "{after_restart}");
    assert_eq!(tabs_after_restart[0], source_tab, "{after_restart}");
    let restored_groups = state_cli(&server, None, &["closed", "list"]);
    assert_eq!(restored_groups[0]["id"], closed_id.as_str(), "{restored_groups}");
    assert!(
        after_restart["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .any(|terminal| terminal["id"] == split_terminal.as_str()),
        "closed terminal was not retained for restore: {after_restart}"
    );

    let before_reopen = tab_ids(&server);
    let reopened = state_cli(&server, None, &["closed", &closed_id, "reopen"]);
    let restored_tab = new_tab(&before_reopen, &tab_ids(&server));
    assert_eq!(reopened["value"]["tab_ids"], serde_json::json!([restored_tab]), "{reopened}");
    let restored = state_cli_topology(&server);
    assert_eq!(workspace_of_terminal(&restored, &source_terminal), workspace);
    let tab = restored["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == restored_tab.as_str())
        .expect("reopened tab is present in the snapshot");
    assert_eq!(tab["content_id"], split_terminal.as_str(), "{restored}");
    // A closed pane reopens in its own split off the pane it was split from
    // (3abf55fce6b, #21009): a new pane on the source screen, not the
    // source pane.
    let reopened_pane = tab["pane_id"].as_str().expect("reopened tab has a pane").to_string();
    assert_ne!(reopened_pane, source_pane, "{restored}");
    let restored_panes = pane_ids(&restored);
    assert_eq!(restored_panes.len(), 2, "{restored}");
    assert!(restored_panes.contains(&source_pane), "{restored}");
    let screen_of = |pane: &str| {
        restored["panes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|candidate| candidate["id"] == pane)
            .and_then(|candidate| candidate["screen_id"].as_str())
            .map(str::to_string)
    };
    assert_eq!(screen_of(&reopened_pane), Some(source_screen), "{restored}");
    assert_eq!(workspace_of_terminal(&restored, &split_terminal), workspace);
    assert!(tab_ids(&server).contains(&source_tab), "{restored}");
    assert_eq!(restored["terminals"].as_array().unwrap().len(), 2, "{restored}");
    assert_eq!(state_cli(&server, None, &["closed", "list"]), serde_json::json!([]));
}

/// The tab ids of `pane`'s layout leaf in the screen upserts of `changes`.
fn leaf_tabs(changes: &[serde_json::Value], pane: &str) -> Option<serde_json::Value> {
    fn find(node: &serde_json::Value, pane: &str) -> Option<serde_json::Value> {
        if !node.is_object() {
            return None;
        }
        if node["kind"] == "leaf" && node["pane_id"] == pane {
            return Some(node["tab_ids"].clone());
        }
        ["first", "second"]
            .iter()
            .find_map(|side| find(&node[*side], pane))
            .or_else(|| node["columns"].as_array()?.iter().find_map(|column| find(column, pane)))
    }
    changes
        .iter()
        .filter(|change| change["kind"] == "upsert" && change["resource"] == "screen")
        .find_map(|change| find(&change["value"]["layout"]["root"], pane))
}

/// `terminal.move` to another pane restates the screen in the delta that
/// moves the tab, so a client that builds pane tabs from the screen layout
/// shows the tab in its new pane at once (cx-gzh.25).
#[test]
fn terminal_move_to_another_pane_publishes_the_changed_screen() {
    let server = HeadlessServer::start("terminal-move-screen");
    state_cli(&server, None, &["workspace", "create", "--name", "alpha"]);
    let snapshot = state_cli_topology(&server);
    let first = snapshot["tabs"].as_array().unwrap()[0].clone();
    let source = first["pane_id"].as_str().unwrap().to_string();
    let before = tab_ids(&server);
    state_cli(&server, None, &["tab", "create", "terminal", "--pane", &source]);
    let moved = new_tab(&before, &tab_ids(&server));
    let pane_ids = |snapshot: &serde_json::Value| -> Vec<String> {
        snapshot["panes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pane| pane["id"].as_str().unwrap().to_string())
            .collect()
    };
    let before = pane_ids(&state_cli_topology(&server));
    state_cli(&server, None, &["pane", &source, "split", "--right"]);
    let snapshot = state_cli_topology(&server);
    let target = pane_ids(&snapshot)
        .into_iter()
        .find(|pane| !before.contains(pane))
        .expect("the split made no pane");
    let find = |kind: &str, field: &str, value: &str| {
        snapshot[kind]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item[field] == value)
            .unwrap_or_else(|| panic!("no {kind} with {field} {value}: {snapshot}"))
            .clone()
    };
    let terminal = find("terminals", "tab_id", &moved)["id"].as_str().unwrap().to_string();
    let screen = find("panes", "id", &target)["screen_id"].as_str().unwrap().to_string();
    let workspace = find("screens", "id", &screen)["workspace_id"].as_str().unwrap().to_string();
    let (_stream, rx) = session_events(&server);

    state_cli(
        &server,
        None,
        &[
            "terminal",
            &terminal,
            "move",
            "--workspace",
            &workspace,
            "--screen",
            &screen,
            "--pane",
            &target,
            "--index",
            "0",
        ],
    );
    let changes = changes_through_tab_upsert(&rx, &moved);
    let Some(target_tabs) = leaf_tabs(&changes, &target) else {
        panic!("terminal.move published no screen with pane {target}: {changes:?}");
    };
    assert!(target_tabs.as_array().unwrap().contains(&serde_json::json!(moved)), "{changes:?}");
    let source_tabs = leaf_tabs(&changes, &source).expect("no source leaf");
    assert!(!source_tabs.as_array().unwrap().contains(&serde_json::json!(moved)), "{changes:?}");
}

/// The value of the `resource` upsert of `id` in `changes`.
fn upsert_of(changes: &[serde_json::Value], resource: &str, id: &str) -> serde_json::Value {
    changes
        .iter()
        .find(|change| {
            change["kind"] == "upsert" && change["resource"] == resource && change["id"] == id
        })
        .map(|change| change["value"].clone())
        .unwrap_or_else(|| panic!("no upsert of {resource} {id}: {changes:?}"))
}

/// Ids of `kind` in a session snapshot whose `field` is `value`.
fn ids_where(snapshot: &serde_json::Value, kind: &str, field: &str, value: &str) -> Vec<String> {
    snapshot[kind]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item[field] == value)
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect()
}

/// Move `tab`'s terminal into `pane` over the CLI.
fn move_terminal(server: &HeadlessServer, tab: &str, pane: &str) {
    let snapshot = state_cli_topology(server);
    let terminal = ids_where(&snapshot, "terminals", "tab_id", tab).remove(0);
    let screen = snapshot["panes"].as_array().unwrap().iter().find(|item| item["id"] == pane);
    let screen = screen.and_then(|item| item["screen_id"].as_str()).unwrap().to_string();
    let workspace =
        snapshot["screens"].as_array().unwrap().iter().find(|item| item["id"] == screen);
    let workspace = workspace.and_then(|item| item["workspace_id"].as_str()).unwrap().to_string();
    let args = ["--workspace", &workspace, "--screen", &screen, "--pane", pane, "--index", "0"];
    state_cli(server, None, &[&["terminal", &terminal, "move"][..], &args[..]].concat());
}

/// A `terminal.move` to another workspace sends the focus change of the
/// one focus path: the workspace upserts, the screen that had focus (here
/// in a third workspace) and the source and destination screens. A move
/// to another screen of the same workspace restates both screens
/// (cx-gzh.26).
#[test]
fn terminal_move_to_another_workspace_or_screen_publishes_the_focus_change() {
    let server = HeadlessServer::start("terminal-move-focus");
    for name in ["alpha", "beta", "gamma"] {
        state_cli(&server, None, &["workspace", "create", "--name", name]);
    }
    let [alpha, beta, gamma] =
        ["alpha", "beta", "gamma"].map(|name| workspace_id_named(&server, name));
    let snapshot = state_cli_topology(&server);
    let screen_of =
        |workspace: &str| ids_where(&snapshot, "screens", "workspace_id", workspace).remove(0);
    let pane_of = |screen: &str| ids_where(&snapshot, "panes", "screen_id", screen).remove(0);
    let [screen_a, screen_b, screen_g] = [&alpha, &beta, &gamma].map(|id| screen_of(id));
    let [pane_a, pane_b] = [&screen_a, &screen_b].map(|id| pane_of(id));
    let mut fresh = Vec::new();
    for _ in 0..2 {
        let before = tab_ids(&server);
        state_cli(&server, None, &["tab", "create", "terminal", "--pane", &pane_a]);
        fresh.push(new_tab(&before, &tab_ids(&server)));
    }
    state_cli(&server, None, &["workspace", &gamma, "focus"]);
    let (_stream, rx) = session_events(&server);

    move_terminal(&server, &fresh[0], &pane_b);
    let changes = changes_through_tab_upsert(&rx, &fresh[0]);
    assert_eq!(upsert_of(&changes, "workspace", &gamma)["focused"], false, "{changes:?}");
    assert_eq!(upsert_of(&changes, "workspace", &beta)["focused"], true, "{changes:?}");
    assert_eq!(upsert_of(&changes, "screen", &screen_g)["focused"], false, "{changes:?}");
    assert_eq!(upsert_of(&changes, "screen", &screen_b)["focused"], true, "{changes:?}");
    let tab = serde_json::json!(fresh[0]);
    assert!(leaf_tabs(&changes, &pane_b).unwrap().as_array().unwrap().contains(&tab));
    assert!(!leaf_tabs(&changes, &pane_a).unwrap().as_array().unwrap().contains(&tab));

    state_cli(&server, None, &["workspace", &alpha, "focus"]);
    state_cli(&server, None, &["screen", "create"]);
    let snapshot = state_cli_topology(&server);
    let screens = ids_where(&snapshot, "screens", "workspace_id", &alpha);
    let screen_a2 = screens.into_iter().find(|id| *id != screen_a).expect("no second screen");
    let pane_a2 = ids_where(&snapshot, "panes", "screen_id", &screen_a2).remove(0);
    state_cli(&server, None, &["screen", &screen_a, "focus"]);
    move_terminal(&server, &fresh[1], &pane_a2);
    let changes = changes_through_tab_upsert(&rx, &fresh[1]);
    let tab = serde_json::json!(fresh[1]);
    assert!(leaf_tabs(&changes, &pane_a2).unwrap().as_array().unwrap().contains(&tab));
    assert!(!leaf_tabs(&changes, &pane_a).unwrap().as_array().unwrap().contains(&tab));
    assert_eq!(upsert_of(&changes, "screen", &screen_a2)["focused"], true, "{changes:?}");
    assert_eq!(upsert_of(&changes, "screen", &screen_a)["focused"], false, "{changes:?}");

    // A move of a pane's only tab (the pane closes) sends the same focus
    // change: a split in gamma moves into beta while alpha has focus.
    let before = ids_where(&state_cli_topology(&server), "panes", "screen_id", &screen_g);
    state_cli(&server, None, &["pane", &before[0], "split", "--right"]);
    let snapshot = state_cli_topology(&server);
    let panes = ids_where(&snapshot, "panes", "screen_id", &screen_g);
    let pane_g2 = panes.into_iter().find(|pane| !before.contains(pane)).expect("no split pane");
    let lone = ids_where(&snapshot, "tabs", "pane_id", &pane_g2).remove(0);
    // The split's own delta upserts the new tab first.
    changes_through_tab_upsert(&rx, &lone);
    state_cli(&server, None, &["workspace", &alpha, "focus"]);
    move_terminal(&server, &lone, &pane_b);
    let changes = changes_through_tab_upsert(&rx, &lone);
    assert_eq!(upsert_of(&changes, "workspace", &alpha)["focused"], false, "{changes:?}");
    assert_eq!(upsert_of(&changes, "workspace", &beta)["focused"], true, "{changes:?}");
    assert_eq!(upsert_of(&changes, "screen", &screen_a2)["focused"], false, "{changes:?}");
    assert_eq!(upsert_of(&changes, "screen", &screen_b)["focused"], true, "{changes:?}");
    let tab = serde_json::json!(lone);
    assert!(leaf_tabs(&changes, &pane_b).unwrap().as_array().unwrap().contains(&tab));
    assert!(leaf_tabs(&changes, &pane_g2).is_none(), "{changes:?}");
}

/// A pane with three tabs and a split beside it: (pane, tabs, split pane).
fn three_tabs_and_a_split(server: &HeadlessServer) -> (String, Vec<String>, String) {
    state_cli(server, None, &["workspace", "create", "--name", "alpha"]);
    let snapshot = state_cli_topology(server);
    let first = snapshot["tabs"].as_array().unwrap()[0].clone();
    let pane = first["pane_id"].as_str().unwrap().to_string();
    let mut tabs = vec![first["id"].as_str().unwrap().to_string()];
    for _ in 0..2 {
        let before = tab_ids(server);
        state_cli(server, None, &["tab", "create", "terminal", "--pane", &pane]);
        tabs.push(new_tab(&before, &tab_ids(server)));
    }
    let screen = first_screen_of_pane(&snapshot, &pane);
    let before = ids_where(&state_cli_topology(server), "panes", "screen_id", &screen);
    state_cli(server, None, &["pane", &pane, "split", "--right"]);
    let after = ids_where(&state_cli_topology(server), "panes", "screen_id", &screen);
    let split = after.into_iter().find(|id| !before.contains(id)).expect("no split pane");
    (pane, tabs, split)
}

fn first_screen_of_pane(snapshot: &serde_json::Value, pane: &str) -> String {
    let pane = snapshot["panes"].as_array().unwrap().iter().find(|item| item["id"] == pane);
    pane.and_then(|item| item["screen_id"].as_str()).unwrap().to_string()
}

/// A move from a zoomed pane keeps the pane's zoom in the delta, as the
/// session snapshot stores it (cx-gzh.27).
#[test]
fn terminal_move_from_a_zoomed_pane_keeps_its_zoom() {
    let server = HeadlessServer::start("terminal-move-zoom");
    let (pane, tabs, split) = three_tabs_and_a_split(&server);
    state_cli(&server, None, &["pane", &pane, "zoom", "--enabled", "true"]);
    let (_stream, rx) = session_events(&server);
    move_terminal(&server, &tabs[2], &split);
    let changes = changes_through_tab_upsert(&rx, &tabs[2]);
    let stored = state_cli_topology(&server)["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == pane.as_str())
        .map(|item| item["zoomed"].clone())
        .unwrap();
    assert_eq!(stored, true, "the source pane lost its zoom");
    assert_eq!(upsert_of(&changes, "pane", &pane)["zoomed"], stored, "{changes:?}");
}

/// After a move out of a pane whose active tab is not its first tab, the
/// live tree and the stored state show the same active tab (cx-gzh.27).
#[test]
fn terminal_move_keeps_one_active_tab_in_the_source_pane() {
    let server = HeadlessServer::start("terminal-move-active-tab");
    let (pane, tabs, split) = three_tabs_and_a_split(&server);
    state_cli(&server, None, &["tab", &tabs[1], "focus"]);
    move_terminal(&server, &tabs[0], &split);
    let snapshot = state_cli_topology(&server);
    let screen = first_screen_of_pane(&snapshot, &pane);
    let screen = snapshot["screens"].as_array().unwrap().iter().find(|item| item["id"] == screen);
    let changes = vec![serde_json::json!({
        "kind": "upsert", "resource": "screen", "value": screen.unwrap().clone(),
    })];
    let stored = leaf_active(&changes, &pane);
    assert_eq!(stored, serde_json::json!(tabs[1]), "the stored active tab moved: {changes:?}");
    let tree =
        json_socket_request(&server.socket, serde_json::json!({"id": 1, "cmd": "list-workspaces"}));
    let live = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().cloned().unwrap_or_default())
        .flat_map(|screen| screen["panes"].as_array().cloned().unwrap_or_default())
        .find(|item| item["resource_id"] == pane.as_str())
        .expect("no live pane");
    let index = live["active_tab"].as_u64().unwrap() as usize;
    assert_eq!(live["tabs"][index]["tab_resource_id"], stored, "{live}");
}

/// The active tab of `pane`'s layout leaf in the screen upserts of `changes`.
fn leaf_active(changes: &[serde_json::Value], pane: &str) -> serde_json::Value {
    fn find(node: &serde_json::Value, pane: &str) -> Option<serde_json::Value> {
        if !node.is_object() {
            return None;
        }
        if node["kind"] == "leaf" && node["pane_id"] == pane {
            return Some(node["active_tab_id"].clone());
        }
        ["first", "second"].iter().find_map(|side| find(&node[*side], pane))
    }
    changes
        .iter()
        .find_map(|change| find(&change["value"]["layout"]["root"], pane))
        .unwrap_or_else(|| panic!("no leaf of pane {pane}: {changes:?}"))
}

/// Retention for `history.closed.maxAgeDays` and `history.closed.maxGroups`
/// (reopen-closed.md 2; the app applies the settings, like
/// `history.commandRetentionDays`): `closed clear --before-ms T` deletes the
/// groups closed before T, and `closed clear --keep-newest N` every group but
/// the newest N. Both are hard deletes and cannot be reopened.
#[test]
fn state_cli_closed_clear_before_and_keep_newest_through_a_real_daemon() {
    let server = HeadlessServer::start("state-cli-closed-retention");
    let names = ["oldest", "middle", "newer", "newest"];
    for name in names {
        state_cli(&server, None, &["workspace", "create", "--name", name, "--empty"]);
    }
    for name in names {
        let workspace = workspace_id_named(&server, name);
        state_cli(&server, None, &["workspace", &workspace, "close"]);
        // Distinct close times, so before-ms can split them.
        std::thread::sleep(Duration::from_millis(20));
    }
    let closed_names = || -> Vec<String> {
        let mut names = state_cli(&server, None, &["closed", "list"])
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item["name"].as_str().unwrap_or_default().to_string())
            .collect::<Vec<_>>();
        names.sort();
        names
    };
    assert_eq!(closed_names(), ["middle", "newer", "newest", "oldest"]);
    let middle_closed_at = state_cli(&server, None, &["closed", "list"])
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["name"] == "middle")
        .and_then(|item| item["closed_at_ms"].as_str().map(str::to_string))
        .expect("middle has a close time");

    let aged = state_cli(&server, None, &["closed", "clear", "--before-ms", &middle_closed_at]);
    assert_eq!(aged["value"]["deleted"].as_array().map(Vec::len), Some(1), "{aged}");
    assert_eq!(closed_names(), ["middle", "newer", "newest"]);

    let trimmed = state_cli(&server, None, &["closed", "clear", "--keep-newest", "1"]);
    assert_eq!(trimmed["value"]["deleted"].as_array().map(Vec::len), Some(2), "{trimmed}");
    assert_eq!(closed_names(), ["newest"]);
    let none = state_cli(&server, None, &["closed", "clear", "--keep-newest", "1"]);
    assert_eq!(none["value"]["deleted"], serde_json::json!([]), "{none}");

    for (flags, needle) in [
        (vec!["closed", "clear", "--keep-newest", "-1"], "--keep-newest"),
        (vec!["closed", "clear", "--before-ms", "soon"], "--before-ms"),
    ] {
        let bad = Command::new(bin())
            .args(["--json", "--socket"])
            .arg(&server.socket)
            .args(&flags)
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .output()
            .unwrap();
        assert!(!bad.status.success(), "{flags:?} was accepted");
        assert!(String::from_utf8_lossy(&bad.stderr).contains(needle), "{flags:?}");
    }
}
