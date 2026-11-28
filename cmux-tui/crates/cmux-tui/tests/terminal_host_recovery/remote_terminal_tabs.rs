//! Remote-terminal tabs (`remote-terminal-tabs-v1`) and detached terminals
//! (`detached-terminals-v1`) over the daemon socket (plans/cmux-next/
//! data-model.md 1.2b and section 8 stage 2). "Open Terminal on Machine Here"
//! in the cmux app creates a detached terminal on one session and shows it as
//! a remote-terminal tab in another session's layout; these tests drive both
//! halves the way the app does.

use super::super::*;

const SESSION: &str = "0b7f2c1e-4d3a-4f6b-9c8d-1a2b3c4d5e6f";
const REMOTE_TERMINAL: &str = "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f";

fn has_capability(socket: &Path, capability: &str) -> bool {
    let identify = request(socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    identify["capabilities"].as_array().unwrap().iter().any(|value| value == capability)
}

fn tabs(socket: &Path) -> Vec<serde_json::Value> {
    let tree = request(socket, serde_json::json!({"id": 900, "cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|w| w["screens"].as_array().cloned().unwrap_or_default())
        .flat_map(|s| s["panes"].as_array().cloned().unwrap_or_default())
        .flat_map(|p| p["tabs"].as_array().cloned().unwrap_or_default())
        .collect()
}

fn tab_with_resource(socket: &Path, tab_resource_id: &str) -> serde_json::Value {
    tabs(socket)
        .into_iter()
        .find(|tab| tab["tab_resource_id"] == tab_resource_id)
        .unwrap_or_else(|| panic!("tab {tab_resource_id} is not in the tree"))
}

/// The home session stores a reference to a terminal on another session: a
/// `kind:"remote-terminal"` tab with its `remote` object and title, which
/// survives a daemon restart with its title and stored snapshot. Nothing is
/// attached or spawned for it.
#[test]
fn cmux_next_remote_terminal_tab_over_the_socket() {
    let mut harness = RecoveryHarness::start("remote-terminal-tab");
    assert!(has_capability(&harness.socket, "remote-terminal-tabs-v1"));
    run_cat_workspace(&harness.socket, 2, "home");
    let pane = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-workspaces"}))
        ["workspaces"][0]["screens"][0]["panes"][0]["id"]
        .as_u64()
        .unwrap();
    wait_for_host_records(&harness.host_root(), 1);

    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 4, "cmd": "new-remote-terminal-tab", "pane": pane,
            "session_id": SESSION, "terminal_id": REMOTE_TERMINAL, "session_name": "build-box",
        }),
    );
    assert_eq!(created["pane"], serde_json::json!(pane), "{created}");
    let surface = created["surface"].as_u64().unwrap();
    let tab_id = created["tab_resource_id"].as_str().unwrap().to_string();
    assert!(tab_id.starts_with("tab_"), "{created}");

    let tab = tab_with_resource(&harness.socket, &tab_id);
    assert_eq!(tab["kind"], "remote-terminal", "{tab}");
    assert_eq!(tab["remote"]["session_id"], SESSION, "{tab}");
    assert_eq!(tab["remote"]["terminal_id"], REMOTE_TERMINAL, "{tab}");
    assert_eq!(tab["remote"]["session_name"], "build-box", "{tab}");
    assert_eq!(tab["title"], "Terminal on build-box", "{tab}");
    assert!(tab.get("terminal_id").is_none() && tab.get("terminal_resource_id").is_none(), "{tab}");
    assert!(tab["url"].is_null() && tab["browser_renderer"].is_null(), "{tab}");
    // The daemon spawned nothing for it.
    wait_for_host_records(&harness.host_root(), 1);
    let attach = request_response(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "attach-surface", "surface": surface}),
    );
    assert_eq!(attach["ok"], false, "a remote-terminal tab has no daemon stream: {attach}");

    let renamed = request(
        &harness.socket,
        serde_json::json!({"id": 6, "cmd": "update-remote-terminal-tab", "surface": surface, "title": "cargo build"}),
    );
    assert_eq!(renamed, serde_json::json!({"surface": surface, "changed": true}));
    let unchanged = request(
        &harness.socket,
        serde_json::json!({"id": 7, "cmd": "update-remote-terminal-tab", "surface": surface, "title": "cargo build"}),
    );
    assert_eq!(unchanged["changed"], false, "{unchanged}");
    let snapshot = "$ cargo build\n   Compiling cmux v0.1.0\n";
    let stored = request(
        &harness.socket,
        serde_json::json!({"id": 8, "cmd": "update-remote-terminal-tab", "surface": surface, "snapshot": snapshot}),
    );
    assert_eq!(stored["changed"], true, "{stored}");
    let tab = tab_with_resource(&harness.socket, &tab_id);
    assert_eq!(tab["title"], "cargo build", "{tab}");
    assert!(tab.get("snapshot").is_none() && tab["remote"].get("snapshot").is_none(), "{tab}");
    let read = request(
        &harness.socket,
        serde_json::json!({"id": 9, "cmd": "remote-terminal-snapshot", "surface": surface}),
    );
    assert_eq!(read["snapshot"], snapshot, "{read}");

    // Bad references are refused before anything is created.
    let before = tabs(&harness.socket).len();
    for (n, (field, value)) in
        [("session_id", "not-a-uuid"), ("terminal_id", "XYZ")].into_iter().enumerate()
    {
        let mut command = serde_json::json!({
            "id": 10 + n, "cmd": "new-remote-terminal-tab", "pane": pane,
            "session_id": SESSION, "terminal_id": REMOTE_TERMINAL, "session_name": "build-box",
        });
        command[field] = serde_json::json!(value);
        let refused = request_response(&harness.socket, command);
        assert_eq!(refused["ok"], false, "{field}: {refused}");
    }
    assert_eq!(tabs(&harness.socket).len(), before);

    harness.sigkill();
    harness.restart();
    let tab = tab_with_resource(&harness.socket, &tab_id);
    assert_eq!(tab["kind"], "remote-terminal", "restored: {tab}");
    assert_eq!(tab["title"], "cargo build", "restored: {tab}");
    assert_eq!(tab["remote"]["terminal_id"], REMOTE_TERMINAL, "restored: {tab}");
    let surface = tab["surface"].as_u64().unwrap();
    let read = request(
        &harness.socket,
        serde_json::json!({"id": 20, "cmd": "remote-terminal-snapshot", "surface": surface}),
    );
    assert_eq!(read["snapshot"], snapshot, "restored: {read}");

    // Closing the tab deletes its reference; Reopen Closed Tab brings it
    // back as a remote-terminal tab, not as a blank browser.
    request(
        &harness.socket,
        serde_json::json!({"id": 21, "cmd": "close-surface", "surface": surface}),
    );
    let current = serde_json::json!({"machine": "current", "session": "current"});
    let closed = resource_request(
        &harness.socket,
        "remote-closed-list",
        "closed.list",
        current.clone(),
        None,
    );
    let closed_id = closed
        .as_array()
        .and_then(|items| items.iter().find(|item| item["kind"] == "tab"))
        .and_then(|item| item["id"].as_str())
        .unwrap_or_else(|| panic!("the closed tab is in closed history: {closed}"))
        .to_string();
    let mut reopen = current;
    reopen["closed"] = serde_json::json!(closed_id);
    resource_request(
        &harness.socket,
        "remote-reopen",
        "closed.reopen",
        reopen,
        Some("remote-reopen-1"),
    );
    let reopened = tabs(&harness.socket)
        .into_iter()
        .find(|tab| tab["kind"] == "remote-terminal")
        .unwrap_or_else(|| {
            panic!("reopened as a remote-terminal tab: {:?}", tabs(&harness.socket))
        });
    assert_eq!(reopened["title"], "cargo build", "{reopened}");
    assert_eq!(reopened["remote"]["terminal_id"], REMOTE_TERMINAL, "{reopened}");
    assert_eq!(reopened["remote"]["session_name"], "build-box", "{reopened}");
    let read = request(
        &harness.socket,
        serde_json::json!({"id": 22, "cmd": "remote-terminal-snapshot", "surface": reopened["surface"]}),
    );
    assert!(read["snapshot"].is_null(), "the closed tab's snapshot was deleted: {read}");
}

/// `create-terminal {detached:true}` makes a kept terminal with no
/// workspace, pane, screen or tab. The app attaches to it by its public id
/// and generation, its attached view sizes it, a retry with the same
/// mutation id replays the same terminal, and it survives a daemon restart
/// still kept and tabless.
#[test]
fn cmux_next_detached_terminal_over_the_socket() {
    const DETACHED: &str = "4d6f8a0b2c3e4f5a8b7c9d0e1f2a3b4c";
    let mut harness = RecoveryHarness::start_with_args(
        "detached-terminal",
        &["--terminal-reap-grace-seconds", "0"],
    );
    assert!(has_capability(&harness.socket, "detached-terminals-v1"));
    let create = serde_json::json!({
        "id": 2, "cmd": "create-terminal", "detached": true, "keep": true,
        "terminal_id": DETACHED, "argv": ["/bin/cat"],
        "origin": "detached-test", "mutation_id": "detached-1",
    });
    let created = request(&harness.socket, create.clone());
    assert_eq!(created["key"], "detached", "{created}");
    assert_eq!(created["terminal_id"], DETACHED, "{created}");
    for field in ["surface", "pane", "screen", "workspace"] {
        assert!(created[field].is_null(), "{field}: {created}");
    }
    let public = created["terminal_resource_id"].as_str().unwrap().to_string();
    assert!(public.starts_with("term_"), "{created}");
    assert!(tabs(&harness.socket).is_empty(), "a detached terminal has no tab");
    wait_for_host_records(&harness.host_root(), 1);

    // A lost-reply retry replays the same terminal and spawns nothing.
    let replayed = request(&harness.socket, create);
    assert_eq!(replayed["replayed"], true, "{replayed}");
    assert_eq!(replayed["terminal_id"], DETACHED, "{replayed}");
    assert_eq!(replayed["terminal_resource_id"], public.as_str(), "{replayed}");
    wait_for_host_records(&harness.host_root(), 1);
    // A detached terminal takes no workspace.
    let refused = request_response(
        &harness.socket,
        serde_json::json!({"id": 3, "cmd": "create-terminal", "detached": true, "key": "00000000-0000-4000-8000-000000000001"}),
    );
    assert_eq!(refused["ok"], false, "{refused}");

    // The app keeps the terminal by host id and reads its public id.
    let kept = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "set-terminal-keep", "terminal_id": DETACHED, "keep": true}),
    );
    assert_eq!(kept["terminal_resource_id"], public.as_str(), "{kept}");

    // It attaches by identity, with no surface, and its view sizes it.
    let generation =
        request(&harness.socket, serde_json::json!({"id": 5, "cmd": "identify"}))["generation"]
            .as_str()
            .unwrap()
            .to_string();
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    // The daemon names the attached surface in the vt-state it sends before
    // the attach reply (the app's `unplaced` target reads it there).
    let attach = serde_json::json!({
        "id": 6, "cmd": "attach-surface", "expected_terminal_id": public,
        "expected_generation": generation, "cols": 101, "rows": 31,
    });
    writeln!(writer, "{attach}").unwrap();
    let mut surface = None;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let message: serde_json::Value = serde_json::from_str(&line).unwrap();
        if message["id"] == 6 {
            assert_eq!(message["ok"], true, "attach by identity failed: {message}");
            break;
        }
        surface = surface.or(message["surface"].as_u64());
    }
    let surface = surface.expect("the attach named its surface before the reply");
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({"id": 7, "cmd": "set-client-sizing", "surface": surface, "enabled": true, "exclusive": true}),
    );
    wait_for_host_size(&harness.host_root(), 101, 31);
    drop(writer);
    drop(reader);

    // The reaper (grace 0) never ends it: it is kept from its creation.
    harness.sigkill();
    harness.restart();
    let resolved = wait_for_terminal_lifecycle(&harness.socket, DETACHED, "running");
    assert!(resolved["surface"].is_null(), "still tabless after a restart: {resolved}");
    assert!(tabs(&harness.socket).is_empty(), "adoption placed no tab");
    let kept = request(
        &harness.socket,
        serde_json::json!({"id": 8, "cmd": "set-terminal-keep", "terminal_id": DETACHED, "keep": true}),
    );
    assert_eq!(kept["terminal_resource_id"], public.as_str(), "same public id: {kept}");
}

/// `create-terminal {detached:true}` spawns the host before it commits the
/// terminal's resource row. A daemon that dies between the two leaves a live,
/// kept host whose registry row names the "detached" sentinel and no public
/// resource row. The next daemon adopts it as a kept terminal with no tab and
/// gives it a public id; it places it in no workspace.
#[test]
fn cmux_next_detached_terminal_without_a_resource_row_is_adopted_kept_and_tabless() {
    const DETACHED: &str = "4d6f8a0b2c3e4f5a8b7c9d0e1f2a3b4d";
    let mut harness = RecoveryHarness::start("detached-adopt");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1, "cmd": "create-terminal", "detached": true, "keep": true,
            "terminal_id": DETACHED, "origin": "recovery-test", "mutation_id": "detached-adopt-1",
        }),
    );
    assert_eq!(created["key"], "detached", "{created}");
    wait_for_host_records(&harness.host_root(), 1);
    harness.sigkill();

    // The durable state of the crash window: drop the resource row the
    // projection commit added after the host spawned.
    let registry = walk_files(&harness.state)
        .into_iter()
        .find(|path| path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3"))
        .expect("workspace registry");
    {
        let connection = rusqlite::Connection::open(&registry).unwrap();
        let public_id: String = connection
            .query_row(
                "SELECT public_id FROM resource_terminals WHERE terminal_id = ?1",
                [DETACHED],
                |row| row.get(0),
            )
            .unwrap();
        connection
            .execute("DELETE FROM resource_terminals WHERE terminal_id = ?1", [DETACHED])
            .unwrap();
        connection
            .execute("DELETE FROM resource_identities WHERE public_id = ?1", [&public_id])
            .unwrap();
    }

    harness.restart();
    let resolved = wait_for_terminal_lifecycle(&harness.socket, DETACHED, "running");
    assert!(resolved["surface"].is_null(), "an adopted detached terminal has no tab: {resolved}");
    let tree = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
    assert!(
        tree["workspaces"].as_array().unwrap().is_empty(),
        "adoption created no workspace for a detached terminal: {tree}"
    );
    let kept = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "set-terminal-keep", "terminal_id": DETACHED, "keep": true}),
    );
    assert!(
        kept["terminal_resource_id"].as_str().is_some_and(|id| id.starts_with("term_")),
        "the adopted terminal has a public id again: {kept}"
    );
}
