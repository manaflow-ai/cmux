//! Hidden running shells (bench round 4, friction 1). `agent start`, `pane
//! move` into a new pane or screen, and `workspace close --remove-worktree`
//! each left a running shell with no tab: not in the TUI, not in `pane
//! list`, only in `terminal list` with `tab_ids: []`. A command that opens a
//! shell tab only to hold a new pane must end that shell before it returns,
//! and the worktree close must end the terminals that worked in the folder it
//! removed. This daemon runs with no reaper (`--headless` without
//! `--terminal-reap-grace-seconds`), so a terminal these commands leave stays
//! until the session ends: the count right after each command is the leak.
#![cfg(unix)]

use serde_json::Value;

use super::*;

/// How long a closed terminal may take to stop being listed as running.
const SETTLE: Duration = Duration::from_secs(10);

fn git(dir: &std::path::Path, args: &[&str]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// `cmux --json <args>` against `server`; the JSON result of a success.
fn run(server: &HeadlessServer, args: &[&str]) -> Value {
    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_TUI_SESSION_ID")
        .output()
        .unwrap();
    assert_success(&output);
    json_output(&output)
}

/// The running terminals `terminal list` shows with no tab.
fn tabless(server: &HeadlessServer) -> Vec<Value> {
    let listed = run(server, &["terminal", "list"]);
    listed
        .as_array()
        .unwrap_or_else(|| panic!("terminal list is not an array: {listed}"))
        .iter()
        .filter(|terminal| terminal["tab_ids"].as_array().is_none_or(Vec::is_empty))
        .filter(|terminal| terminal["lifecycle"] != "exited")
        .cloned()
        .collect()
}

/// No running terminal is left without a tab after `step` (an ended one may
/// take a moment to stop being listed as running).
fn assert_no_tabless(server: &HeadlessServer, step: &str) {
    let deadline = Instant::now() + SETTLE;
    loop {
        let left = tabless(server);
        if left.is_empty() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{step} left {} running terminal(s) with no tab: {}",
            left.len(),
            Value::Array(left)
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn text(value: &Value, pointer: &str) -> String {
    value
        .pointer(pointer)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("no {pointer} in {value}"))
        .to_owned()
}

#[test]
fn w5o_placeholder_shells_end_with_the_command_that_opened_them() {
    let root = unique_temp_dir("tabless");
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let server = HeadlessServer::start_with_options(
        "tabless",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );
    assert_no_tabless(&server, "the new daemon");

    // A session with no pane yet: the agent's workspace opens with a shell tab.
    let alpha = run(&server, &["agent", "start", "alpha", "--cmd", "sleep 600", "--no-wait"]);
    assert_no_tabless(&server, "agent start alpha (first agent of the session)");
    let alpha_pane = text(&alpha, "/pane_id");

    // A split opens a shell tab in the new pane before the agent's tab.
    let beta = run(
        &server,
        &[
            "agent",
            "start",
            "beta",
            "--cmd",
            "sleep 600",
            "--no-wait",
            "--pane",
            &alpha_pane,
            "--split",
            "down",
        ],
    );
    assert_no_tabless(&server, "agent start beta --split down");
    let beta_pane = text(&beta, "/pane_id");

    // A move into a split: the split opens with a shell tab.
    let moved =
        run(&server, &["pane", &beta_pane, "move", "--to-pane", &alpha_pane, "--split", "right"]);
    assert_no_tabless(&server, "pane move --to-pane --split right");
    let moved_pane = text(&moved, "/destination/pane");

    // A move to a new screen: the screen opens with a shell tab.
    run(&server, &["pane", &moved_pane, "move", "--new-screen", "--name", "moved"]);
    assert_no_tabless(&server, "pane move --new-screen");

    // The workspace's terminal works in the worktree the close removes.
    let created = run(
        &server,
        &["workspace", "create", "--worktree", "wt", "--repo", repo.to_str().unwrap()],
    );
    let workspace = created
        .pointer("/value/workspace_id")
        .or_else(|| created.pointer("/workspace_id"))
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("no workspace id in {created}"))
        .to_owned();
    assert_no_tabless(&server, "workspace create --worktree");
    run(&server, &["workspace", &workspace, "close", "--remove-worktree"]);
    assert_no_tabless(&server, "workspace close --remove-worktree");

    drop(server);
    let _ = fs::remove_dir_all(root);
}

/// `cmux --json <args>` run from inside terminal `caller` of `server`.
fn run_in(server: &HeadlessServer, caller: &str, args: &[&str]) -> Value {
    let output = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_SESSION_ID")
        .env("CMUX_TUI_TERMINAL_ID", caller)
        .output()
        .unwrap();
    assert_success(&output);
    json_output(&output)
}

/// The record of `terminal` in `terminal list`.
fn terminal(server: &HeadlessServer, terminal: &str) -> Value {
    let listed = run(server, &["terminal", "list"]);
    listed
        .as_array()
        .into_iter()
        .flatten()
        .find(|record| record["id"] == terminal)
        .cloned()
        .unwrap_or_else(|| panic!("terminal list has no {terminal}: {listed}"))
}

fn created(result: &Value, field: &str) -> String {
    result
        .pointer(&format!("/value/{field}"))
        .or_else(|| result.get(field))
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("no {field} in {result}"))
        .to_owned()
}

/// W5-O review, findings 1 and 2: `workspace <ws> close --remove-worktree`
/// ended every terminal whose tabs were all in the workspace. That ended the
/// caller's own terminal (an agent closing its own workspace lost the reply
/// and the exit code) and a terminal marked `keep`. The close ends only the
/// other unkept terminals; the caller's and the kept one are left running
/// with no tab (the reaper skips a kept terminal and ends the caller's after
/// its grace).
#[test]
fn w5o_worktree_close_spares_the_callers_terminal_and_kept_terminals() {
    let root = unique_temp_dir("tabless-own");
    let home = root.join("home");
    let repo = root.join("project");
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.name", "cmux test"]);
    git(&repo, &["config", "user.email", "cmux@example.invalid"]);
    git(&repo, &["config", "commit.gpgsign", "false"]);
    fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let server = HeadlessServer::start_with_options(
        "tabless-own",
        None,
        None,
        &[("HOME", home.to_str().unwrap())],
    );

    let made = run(
        &server,
        &["workspace", "create", "--worktree", "own", "--repo", repo.to_str().unwrap()],
    );
    let workspace = created(&made, "workspace_id");
    let (pane, caller) = (created(&made, "pane_id"), created(&made, "terminal_id"));
    let kept = created(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");
    run(&server, &["terminal", &kept, "keep", "on"]);
    let plain = created(&run(&server, &["pane", &pane, "split", "--down"]), "terminal_id");

    let closed = run_in(&server, &caller, &["workspace", &workspace, "close", "--remove-worktree"]);
    let ended = closed
        .pointer("/ended_terminals")
        .or_else(|| closed.pointer("/value/ended_terminals"))
        .cloned()
        .unwrap_or_else(|| panic!("no ended_terminals in {closed}"));
    assert!(
        !ended.as_array().into_iter().flatten().any(|id| *id == caller.as_str()),
        "the close ended the caller's own terminal {caller}: {closed}"
    );
    assert!(
        !ended.as_array().into_iter().flatten().any(|id| *id == kept.as_str()),
        "the close ended the kept terminal {kept}: {closed}"
    );
    assert_eq!(ended, serde_json::json!([plain]), "{closed}");

    // The caller's shell and the kept one still run, with no tab.
    for id in [&caller, &kept] {
        let record = terminal(&server, id);
        assert_eq!(record["lifecycle"], "running", "{record}");
        assert_eq!(record["tab_ids"], serde_json::json!([]), "{record}");
    }

    drop(server);
    let _ = fs::remove_dir_all(root);
}
