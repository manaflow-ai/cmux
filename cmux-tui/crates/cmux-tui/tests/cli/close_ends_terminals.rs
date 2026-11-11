//! Close ends what it closed (bench round 6, friction 4; owner W7-C). A
//! `tab`, `pane`, `screen` or `workspace` close left the terminals it closed
//! running with no tab (an eval agent ended 7 of them by hand with
//! `terminal close --if-unplaced`), and `agent list` kept `idle` rows for
//! terminals that had ended (`selector.not_found` on their ids).
//!
//! The rule: a close ends each terminal it leaves with no tab. A terminal
//! that must keep running (marked `keep`, the caller's own shell, or a close
//! with `--keep-terminals`) is left running, and the close names it and says
//! how to see it. An agent row ends with its terminal. This daemon runs with
//! no reaper (`--headless` without `--terminal-reap-grace-seconds`), so a
//! terminal a close leaves running stays until the session ends.
#![cfg(unix)]

use serde_json::Value;

use super::*;

/// How long an ended terminal may take to stop being listed as running.
const SETTLE: Duration = Duration::from_secs(10);

fn cli_output(server: &HeadlessServer, json: bool, args: &[&str]) -> Output {
    let mut command = Command::new(bin());
    if json {
        command.arg("--json");
    }
    command
        .arg("--socket")
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_TUI_SESSION_ID")
        .output()
        .unwrap()
}

/// `cmux --json <args>` against `server`; the JSON result of a success.
fn run(server: &HeadlessServer, args: &[&str]) -> Value {
    let output = cli_output(server, true, args);
    assert_success(&output);
    json_output(&output)
}

/// `cmux <args>` against `server` as a person runs it; its stdout.
fn run_human(server: &HeadlessServer, args: &[&str]) -> String {
    let output = cli_output(server, false, args);
    assert_success(&output);
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn field(result: &Value, name: &str) -> String {
    result
        .pointer(&format!("/value/{name}"))
        .or_else(|| result.get(name))
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("no {name} in {result}"))
        .to_owned()
}

/// The ids a close result lists under `name` (`ended_terminal_ids` or
/// `running_terminal_ids`).
fn listed(result: &Value, name: &str) -> Vec<String> {
    result
        .pointer(&format!("/value/{name}"))
        .or_else(|| result.get(name))
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("the close result has no {name}: {result}"))
        .iter()
        .map(|id| id.as_str().unwrap_or_else(|| panic!("{name} holds {id}")).to_owned())
        .collect()
}

/// The record of `terminal` in `terminal list`, if it is still listed.
fn record(server: &HeadlessServer, terminal: &str) -> Option<Value> {
    let terminals = run(server, &["terminal", "list"]);
    terminals.as_array().into_iter().flatten().find(|record| record["id"] == terminal).cloned()
}

fn runs(record: &Option<Value>) -> bool {
    record.as_ref().is_some_and(|record| record["lifecycle"] != "exited")
}

/// The running terminals `terminal list` shows with no tab.
fn tabless(server: &HeadlessServer) -> Vec<Value> {
    let terminals = run(server, &["terminal", "list"]);
    terminals
        .as_array()
        .unwrap_or_else(|| panic!("terminal list is not an array: {terminals}"))
        .iter()
        .filter(|terminal| terminal["tab_ids"].as_array().is_none_or(Vec::is_empty))
        .filter(|terminal| terminal["lifecycle"] != "exited")
        .cloned()
        .collect()
}

/// `terminal` stops running within `SETTLE` after `step`.
fn assert_ended(server: &HeadlessServer, terminal: &str, step: &str) {
    let deadline = Instant::now() + SETTLE;
    loop {
        let found = record(server, terminal);
        if !runs(&found) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{step} left terminal {terminal} running: {}",
            found.unwrap_or_default()
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// No running terminal is left without a tab after `step`.
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

/// `terminal` still runs, with no tab.
fn assert_runs_tabless(server: &HeadlessServer, terminal: &str, step: &str) {
    let found = record(server, terminal);
    assert!(runs(&found), "{step} ended terminal {terminal}: {}", found.unwrap_or_default());
    let found = found.unwrap();
    assert_eq!(found["tab_ids"], serde_json::json!([]), "{step}: {found}");
}

#[test]
fn w7c_tab_pane_screen_and_workspace_close_end_their_terminals() {
    let server = HeadlessServer::start("w7c-close");
    let made = run(&server, &["workspace", "create", "--name", "w7c"]);
    let (workspace, pane, first) =
        (field(&made, "workspace_id"), field(&made, "pane_id"), field(&made, "terminal_id"));

    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, terminal) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let closed = run(&server, &["tab", &tab, "close"]);
    assert_ended(&server, &terminal, "tab close");
    assert_eq!(listed(&closed, "ended_terminal_ids"), [terminal.as_str()], "{closed}");
    assert_eq!(listed(&closed, "running_terminal_ids"), Vec::<String>::new(), "{closed}");
    assert_no_tabless(&server, "tab close");

    let split = run(&server, &["pane", &pane, "split", "--down"]);
    let (split_pane, terminal) = (field(&split, "pane_id"), field(&split, "terminal_id"));
    let closed = run(&server, &["pane", &split_pane, "close"]);
    assert_ended(&server, &terminal, "pane close");
    assert_eq!(listed(&closed, "ended_terminal_ids"), [terminal.as_str()], "{closed}");
    assert_no_tabless(&server, "pane close");

    let screen = run(&server, &["screen", "create", "--workspace", &workspace]);
    let (screen, terminal) = (field(&screen, "screen_id"), field(&screen, "terminal_id"));
    let closed = run(&server, &["screen", &screen, "close"]);
    assert_ended(&server, &terminal, "screen close");
    assert_eq!(listed(&closed, "ended_terminal_ids"), [terminal.as_str()], "{closed}");
    assert_no_tabless(&server, "screen close");

    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let second = field(&split, "terminal_id");
    let closed = run(&server, &["workspace", &workspace, "close"]);
    assert_ended(&server, &first, "workspace close");
    assert_ended(&server, &second, "workspace close");
    let mut ended = listed(&closed, "ended_terminal_ids");
    ended.sort();
    let mut expected = vec![first, second];
    expected.sort();
    assert_eq!(ended, expected, "{closed}");
    assert_no_tabless(&server, "workspace close");
}

/// A terminal the close does not end is named, with the way to see it.
#[test]
fn w7c_a_close_names_the_terminals_it_leaves_running() {
    let server = HeadlessServer::start("w7c-kept");
    let made = run(&server, &["workspace", "create", "--name", "w7c-kept"]);
    let pane = field(&made, "pane_id");

    // A person's close: the kept terminal stays, and the output says so.
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, kept) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    run(&server, &["terminal", &kept, "keep", "on"]);
    let shown = run_human(&server, &["tab", &tab, "close"]);
    assert!(
        shown.contains(&kept) && shown.contains("terminal list"),
        "the close did not name the kept terminal {kept} and `terminal list`:\n{shown}"
    );
    assert_runs_tabless(&server, &kept, "tab close of a kept terminal");

    // The JSON result lists it as running, not as ended.
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, kept_too) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    run(&server, &["terminal", &kept_too, "keep", "on"]);
    let closed = run(&server, &["tab", &tab, "close"]);
    assert_eq!(listed(&closed, "running_terminal_ids"), [kept_too.as_str()], "{closed}");
    assert_eq!(listed(&closed, "ended_terminal_ids"), Vec::<String>::new(), "{closed}");
    assert_runs_tabless(&server, &kept_too, "tab close of a kept terminal");

    // `--keep-terminals` leaves an unkept terminal running, and says so.
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, left) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let closed = run(&server, &["tab", &tab, "close", "--keep-terminals"]);
    assert_eq!(listed(&closed, "running_terminal_ids"), [left.as_str()], "{closed}");
    assert_runs_tabless(&server, &left, "tab close --keep-terminals");
}

/// A close run from inside a terminal of the workspace it closes ends the
/// other terminals but not the caller's own shell (that would cut off the
/// reply and the exit code), and names the caller's as still running.
#[test]
fn w7c_a_close_from_inside_spares_the_callers_own_terminal() {
    let root = unique_temp_dir("w7c-own");
    fs::create_dir_all(&root).unwrap();
    let server = HeadlessServer::start("w7c-own");
    let made = run(&server, &["workspace", "create", "--name", "w7c-own"]);
    let (workspace, pane, caller) =
        (field(&made, "workspace_id"), field(&made, "pane_id"), field(&made, "terminal_id"));
    let other = field(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");

    let out = root.join("close.json");
    let code = root.join("close.code");
    let script = format!(
        "'{bin}' --json --socket '{socket}' workspace {workspace} close > '{out}' 2>&1; echo $? > '{code}'\r",
        bin = bin(),
        socket = server.socket.display(),
        out = out.display(),
        code = code.display(),
    );
    run(&server, &["terminal", &caller, "write", "--text", &script]);
    let deadline = Instant::now() + Duration::from_secs(30);
    while !fs::read_to_string(&code).is_ok_and(|code| code.ends_with('\n')) {
        assert!(Instant::now() < deadline, "the close run in {caller} did not finish");
        std::thread::sleep(Duration::from_millis(100));
    }
    let printed = fs::read_to_string(&out).unwrap();
    assert_eq!(fs::read_to_string(&code).unwrap().trim(), "0", "the close failed: {printed}");
    // The result is the last JSON line (stderr went to the same file).
    let closed: Value = printed
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str(line).ok().filter(Value::is_object))
        .unwrap_or_else(|| panic!("the close printed no JSON: {printed}"));

    assert_ended(&server, &other, "workspace close from inside");
    assert_eq!(listed(&closed, "ended_terminal_ids"), [other.as_str()], "{closed}");
    assert_eq!(listed(&closed, "running_terminal_ids"), [caller.as_str()], "{closed}");
    assert_runs_tabless(&server, &caller, "workspace close from inside");

    drop(server);
    let _ = fs::remove_dir_all(root);
}

/// The agent rows of `terminal` in `agent list`.
fn agent_rows(server: &HeadlessServer, terminal: &str) -> Vec<Value> {
    let agents = run(server, &["agent", "list"]);
    agents
        .as_array()
        .unwrap_or_else(|| panic!("agent list is not an array: {agents}"))
        .iter()
        .filter(|agent| agent["terminal_id"] == terminal)
        .cloned()
        .collect()
}

/// An agent row goes away or shows ended once its terminal ended, whether
/// `terminal close` ended it or the close of its tab did.
#[test]
fn w7c_agent_rows_end_with_their_terminals() {
    let server = HeadlessServer::start("w7c-agents");
    let made = run(&server, &["workspace", "create", "--name", "w7c-agents"]);
    let pane = field(&made, "pane_id");
    let ended_by_terminal_close =
        field(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");
    let split = run(&server, &["pane", &pane, "split", "--down"]);
    let (tab, ended_by_tab_close) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    for terminal in [&ended_by_terminal_close, &ended_by_tab_close] {
        run(
            &server,
            &["agent", "report", "--terminal", terminal, "--state", "idle", "--source", "socket"],
        );
        let rows = agent_rows(&server, terminal);
        assert_eq!(rows.len(), 1, "agent report made no row for {terminal}: {rows:?}");
        assert_eq!(rows[0]["state"], "idle", "{rows:?}");
    }

    run(&server, &["terminal", &ended_by_terminal_close, "close"]);
    run(&server, &["tab", &tab, "close"]);
    for terminal in [&ended_by_terminal_close, &ended_by_tab_close] {
        assert_ended(&server, terminal, "the close");
        let rows = agent_rows(&server, terminal);
        assert!(
            rows.iter().all(|row| row["state"] == "done" || row["state"] == "ended"),
            "agent list keeps a live row for ended terminal {terminal}: {rows:?}"
        );
    }
}
