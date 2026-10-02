//! Terminals with no tab: a tabless terminal's close and restart, and a
//! detached terminal (`detached-terminals-v1`) adopted after its daemon died
//! before its resource row committed.

use super::*;

/// Regression for https://github.com/manaflow-ai/cmux/issues/11974.
///
/// The issue's Linux reproduction is intentionally kept verbatim here:
///
/// ```sh
/// cmux server start --session repro --state /tmp/repro-state &
///
/// cmux --session repro workspace create --name w1   # creates screen+pane+tab+terminal
/// cmux --session repro tab create terminal          # second tab, note its tab_id + terminal_id
///
/// # 1) detach the only view (documented behaviour: the terminal survives)
/// cmux --session repro tab <tab_id> close
/// cmux --session repro terminal list                # -> that terminal now has "tab_id": null
///
/// # 2) close the now view-less terminal -> session breaks
/// cmux --session repro terminal <terminal_id> close # reports success, revision advances
/// ```
///
/// Exercise the same lifecycle through the public resource API, then stop and
/// restart the durable owner. Every list must remain usable and the unrelated
/// first terminal must survive both the close and restart.
#[test]
fn tabless_terminal_close_tombstones_every_resource_row_and_restarts() {
    let mut harness = RecoveryHarness::start("tabless-terminal-close");
    let created = resource_request(
        &harness.socket,
        "tabless-workspace-create",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"w1",
            "initial_content":"terminal",
        }),
        Some("tabless-workspace-create"),
    );
    let surviving_terminal = created["value"]["terminal_id"].as_str().unwrap().to_string();
    let second = resource_request(
        &harness.socket,
        "tabless-tab-create",
        "tab.create_terminal",
        serde_json::json!({"machine":"current","session":"current"}),
        Some("tabless-tab-create"),
    );
    let tab = second["value"]["tab_id"].as_str().unwrap().to_string();
    let closing_terminal = second["value"]["terminal_id"].as_str().unwrap().to_string();

    resource_request(
        &harness.socket,
        "tabless-tab-close",
        "tab.close",
        serde_json::json!({"machine":"current","session":"current","tab":tab}),
        Some("tabless-tab-close"),
    );
    let terminals = resource_request(
        &harness.socket,
        "tabless-terminal-list-before-close",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let detached = terminals
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == closing_terminal)
        .expect("detached terminal disappeared before explicit close");
    assert!(
        detached["tab_ids"].as_array().is_none_or(Vec::is_empty),
        "terminal still had a tab view after tab.close: {detached}"
    );

    resource_request(
        &harness.socket,
        "tabless-terminal-close",
        "terminal.close",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "terminal":closing_terminal,
        }),
        Some("tabless-terminal-close"),
    );

    for (index, operation) in [
        "workspace.list",
        "screen.list",
        "pane.list",
        "tab.list",
        "terminal.list",
        "notification.list",
    ]
    .into_iter()
    .enumerate()
    {
        let listed = resource_request(
            &harness.socket,
            &format!("tabless-list-{index}"),
            operation,
            serde_json::json!({"machine":"current","session":"current"}),
            None,
        );
        assert!(listed.is_array(), "{operation} failed after tab-less close: {listed}");
    }
    let terminals = resource_request(
        &harness.socket,
        "tabless-survivor-before-restart",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(
        terminals.as_array().unwrap().iter().any(|terminal| terminal["id"] == surviving_terminal),
        "surviving terminal disappeared after tab-less close: {terminals}"
    );
    assert!(
        !terminals.as_array().unwrap().iter().any(|terminal| terminal["id"] == closing_terminal)
    );

    let stop = Command::new(bin())
        .args(["--json", "--session", &harness.session, "server", "stop", "--socket"])
        .arg(&harness.socket)
        .output()
        .unwrap();
    assert!(stop.status.success(), "server stop failed: {}", String::from_utf8_lossy(&stop.stderr));
    let mut child = harness.child.take().unwrap();
    child.wait().unwrap();
    harness.restart();

    let restarted = resource_request(
        &harness.socket,
        "tabless-survivor-after-restart",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    assert!(
        restarted.as_array().unwrap().iter().any(|terminal| terminal["id"] == surviving_terminal),
        "surviving terminal did not recover after restart: {restarted}"
    );
    assert!(
        !restarted.as_array().unwrap().iter().any(|terminal| terminal["id"] == closing_terminal)
    );
}

/// `create-terminal {detached:true}` spawns the host before it commits the
/// terminal's resource row. A daemon that dies between the two leaves a live,
/// kept host whose registry row names the "detached" sentinel and no public
/// resource row. The next daemon must adopt it as a kept terminal with no tab
/// and give it a public id, not retry a placement in a workspace that cannot
/// exist forever.
#[test]
fn detached_terminal_without_a_resource_row_is_adopted_kept_and_tabless() {
    const DETACHED: &str = "4d6f8a0b2c3e4f5a8b7c9d0e1f2a3b4c";
    let mut harness = RecoveryHarness::start("detached-adopt");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "create-terminal",
            "detached": true,
            "keep": true,
            "terminal_id": DETACHED,
            "origin": "recovery-test",
            "mutation_id": "detached-adopt-1",
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
    let deadline = Instant::now() + Duration::from_secs(15);
    let resolved = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": DETACHED}),
        );
        if resolved["lifecycle"] == "running" {
            break resolved;
        }
        assert!(Instant::now() < deadline, "detached host was never adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(50));
    };
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
