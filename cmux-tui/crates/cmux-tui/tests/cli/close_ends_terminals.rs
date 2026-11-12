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

/// Whether `client list` shows a client attached to `terminal` alone.
fn attached(server: &HeadlessServer, terminal: &str) -> bool {
    run(server, &["client", "list"]).as_array().is_some_and(|clients| {
        clients.iter().any(|client| {
            client["attached_terminal_ids"]
                .as_array()
                .is_some_and(|ids| ids.len() == 1 && ids[0].as_str() == Some(terminal))
        })
    })
}

/// A close does not end a terminal a viewer is attached to (`terminal
/// attach`), as the reaper and `terminal close --if-unplaced` do not: it
/// leaves it running and names it.
#[test]
fn w7c_a_close_leaves_a_terminal_with_an_attached_viewer_running() {
    let server = HeadlessServer::start("w7c-viewer");
    let made = run(&server, &["workspace", "create", "--name", "w7c-viewer"]);
    let pane = field(&made, "pane_id");
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, viewed) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let marker = "w7c_viewer_marker";
    run(&server, &["terminal", &viewed, "write", "--text", &format!("printf '{marker}\\n'\n")]);
    wait_for_screen(&server, &viewed, marker);

    let socket = server.socket.to_str().unwrap();
    let viewer = CapturingPtyChild::start(&["attach", "--socket", socket, "--terminal", &viewed]);
    viewer.wait_for_output(marker, Duration::from_secs(10));
    let deadline = Instant::now() + SETTLE;
    while !attached(&server, &viewed) {
        assert!(Instant::now() < deadline, "the viewer did not attach to {viewed}");
        std::thread::sleep(Duration::from_millis(50));
    }

    let closed = run(&server, &["tab", &tab, "close"]);
    assert_eq!(listed(&closed, "running_terminal_ids"), [viewed.as_str()], "{closed}");
    assert_eq!(listed(&closed, "ended_terminal_ids"), Vec::<String>::new(), "{closed}");
    assert_runs_tabless(&server, &viewed, "tab close of a terminal with a viewer");
    drop(viewer);
}

/// A bulk close (`--others`, `--all`) names the terminals it leaves
/// running, as a plain close does; and a `layout.bulk` caller that does not
/// say `end_terminals` (an SDK, MCP or app caller) gets the CLI's default:
/// the terminals end.
#[test]
fn w7c_a_bulk_close_names_the_terminals_it_leaves_running() {
    let server = HeadlessServer::start("w7c-bulk");
    let made = run(&server, &["workspace", "create", "--name", "w7c-bulk"]);
    let (workspace, pane, first) =
        (field(&made, "workspace_id"), field(&made, "pane_id"), field(&made, "terminal_id"));
    let tab = |server: &HeadlessServer| {
        let made = run(server, &["tab", "create", "terminal", "--pane", &pane]);
        (field(&made, "tab_id"), field(&made, "terminal_id"))
    };
    let (anchor_tab, _) = tab(&server);
    let (_, kept) = tab(&server);
    run(&server, &["terminal", &kept, "keep", "on"]);
    let (_, ends) = tab(&server);

    let closed = run(&server, &["tab", &anchor_tab, "close", "--others"]);
    assert_eq!(listed(&closed, "running_terminal_ids"), [kept.as_str()], "{closed}");
    let mut ended = listed(&closed, "ended_terminal_ids");
    ended.sort();
    let mut expected = vec![first, ends.clone()];
    expected.sort();
    assert_eq!(ended, expected, "{closed}");
    assert_ended(&server, &ends, "tab close --others");
    assert_runs_tabless(&server, &kept, "tab close --others of a kept terminal");

    let (_, kept_too) = tab(&server);
    run(&server, &["terminal", &kept_too, "keep", "on"]);
    let shown = run_human(&server, &["tab", &anchor_tab, "close", "--others"]);
    assert!(
        shown.contains(&kept_too) && shown.contains("terminal list"),
        "the bulk close did not name the kept terminal {kept_too} and `terminal list`:\n{shown}"
    );

    // A `layout.bulk` that does not say `end_terminals` ends them too.
    let (_, unsaid) = tab(&server);
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "w7c-bulk",
        "operation": "layout.bulk",
        "idempotency_key": "w7c-bulk-default",
        "params": {
            "machine": "current",
            "session": "current",
            "workspace": workspace,
            "verb": "close",
            "level": "tab",
            "selector": "others",
            "anchor": anchor_tab,
        },
    });
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    assert_ended(&server, &unsaid, "layout.bulk with no end_terminals");
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
        "id": "w7c-events",
        "operation": "session.events",
        "params": {
            "machine": "current",
            "session": "current",
            "stream_id": "stream_77777777777777778777777777777777",
        },
    });
    writeln!(writer, "{request}").unwrap();
    writer.flush().unwrap();
    let deadline = Instant::now() + SETTLE;
    loop {
        let remaining =
            deadline.checked_duration_since(Instant::now()).expect("no session.events reply");
        let line = rx.recv_timeout(remaining).expect("no session.events reply");
        let message: Value = serde_json::from_str(&line).unwrap();
        if message["id"] == "w7c-events" {
            assert_eq!(message["ok"], true, "session.events failed: {message}");
            return (writer, rx);
        }
    }
}

/// Waits for the `session.events` `delete` of agent `agent` (#41123: a
/// terminal that ends has no agent, so its subscriber deletes it too); panics
/// after `SETTLE` with what came.
fn assert_agent_end_event(rx: &mpsc::Receiver<String>, agent: &str, step: &str) {
    let deadline = Instant::now() + SETTLE;
    let mut seen = Vec::new();
    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let Ok(line) = rx.recv_timeout(remaining) else { break };
        let message: Value = serde_json::from_str(&line).unwrap();
        let item = &message["item"];
        if message["type"] != "stream_item" || item["kind"] != "delta" {
            continue;
        }
        for change in item["changes"].as_array().into_iter().flatten() {
            if change["resource"] != "agent" {
                continue;
            }
            if change["id"] == agent && change["kind"] == "delete" {
                return;
            }
            seen.push(change.clone());
        }
    }
    panic!("{step}: no session.events change ended agent {agent}; agent changes seen: {seen:?}");
}

/// An open `session.events` subscriber sees an agent's `delete` when its
/// terminal ends, at that moment, by `terminal close` or by the close of its
/// tab, as `agent.list` and the snapshot then have no agent.
#[test]
fn w7c_a_subscriber_sees_the_agent_end_with_its_terminal() {
    let server = HeadlessServer::start("w7c-agent-events");
    let made = run(&server, &["workspace", "create", "--name", "w7c-agent-events"]);
    let pane = field(&made, "pane_id");
    let by_terminal_close =
        field(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");
    let split = run(&server, &["pane", &pane, "split", "--down"]);
    let (tab, by_tab_close) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let mut agents = Vec::new();
    for terminal in [&by_terminal_close, &by_tab_close] {
        run(
            &server,
            &["agent", "report", "--terminal", terminal, "--state", "idle", "--source", "socket"],
        );
        let rows = agent_rows(&server, terminal);
        assert_eq!(rows.len(), 1, "agent report made no row for {terminal}: {rows:?}");
        agents.push(rows[0]["id"].as_str().expect("an agent id").to_owned());
    }

    let (_stream, rx) = session_events(&server);
    run(&server, &["terminal", &by_terminal_close, "close"]);
    assert_agent_end_event(&rx, &agents[0], "terminal close");
    run(&server, &["tab", &tab, "close"]);
    assert_agent_end_event(&rx, &agents[1], "tab close");
}

/// Milliseconds since the Unix epoch, now.
fn now_ms() -> u64 {
    u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap()
}

/// The `ends_at_ms` a close result names (a decimal string or a number).
fn ends_at_ms(result: &Value) -> u64 {
    let value = result
        .pointer("/value/ends_at_ms")
        .or_else(|| result.get("ends_at_ms"))
        .unwrap_or_else(|| panic!("the close result has no ends_at_ms: {result}"));
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        .unwrap_or_else(|| panic!("ends_at_ms is not a time: {result}"))
}

/// With a reaper (its grace 30 s), a close leaves the terminals it closed
/// running with no tab and names when they end; `closed reopen` in that
/// window shows the SAME process again; `--now` ends them at once; a bulk
/// close follows the same rule; the text names the grace and the reopen.
#[test]
fn w7c_a_close_leaves_its_terminals_for_the_grace_and_reopen_keeps_them() {
    let server = HeadlessServer::start_with_reap_grace("w7c-grace", 30);
    let made = run(&server, &["workspace", "create", "--name", "w7c-grace"]);
    let pane = field(&made, "pane_id");
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, held) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    run(&server, &["terminal", &held, "write", "--text", "W7C_SAME=w7c_same_shell\r"]);

    let before = now_ms();
    let closed = run(&server, &["tab", &tab, "close"]);
    assert_eq!(listed(&closed, "ending_terminal_ids"), [held.as_str()], "{closed}");
    assert_eq!(listed(&closed, "ended_terminal_ids"), Vec::<String>::new(), "{closed}");
    let ends = ends_at_ms(&closed);
    assert!(
        ends >= before + 25_000 && ends <= now_ms() + 35_000,
        "a close with a 30 s grace ends its terminals at {ends}, not about 30 s after {before}"
    );
    assert_runs_tabless(&server, &held, "a close in the grace");

    run(&server, &["closed", "reopen"]);
    let found = record(&server, &held);
    assert!(
        found.as_ref().is_some_and(|record| {
            runs(&found) && record["tab_ids"].as_array().is_some_and(|tabs| !tabs.is_empty())
        }),
        "closed reopen in the grace did not show terminal {held} again: {}",
        found.unwrap_or_default()
    );
    run(&server, &["terminal", &held, "write", "--text", "echo got_$W7C_SAME\r"]);
    let screen = wait_for_screen(&server, &held, "got_w7c_same_shell");
    assert!(screen.contains("got_w7c_same_shell"), "the reopened tab is a new shell:\n{screen}");

    // `--now` ends them at once.
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, now) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let closed = run(&server, &["tab", &tab, "close", "--now"]);
    assert_eq!(listed(&closed, "ended_terminal_ids"), [now.as_str()], "{closed}");
    assert_ended(&server, &now, "tab close --now");

    // A bulk close leaves them for the grace too.
    let anchor = field(&run(&server, &["tab", "create", "terminal", "--pane", &pane]), "tab_id");
    let sibling =
        field(&run(&server, &["tab", "create", "terminal", "--pane", &pane]), "terminal_id");
    let closed = run(&server, &["tab", &anchor, "close", "--others"]);
    assert!(
        listed(&closed, "ending_terminal_ids").contains(&sibling),
        "a bulk close did not leave {sibling} for the grace: {closed}"
    );
    assert_runs_tabless(&server, &sibling, "a bulk close in the grace");

    // The text names the grace and the way to keep them.
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, shown_terminal) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let shown = run_human(&server, &["tab", &tab, "close"]);
    assert!(
        shown.contains(&shown_terminal) && shown.contains("30") && shown.contains("closed reopen"),
        "the close did not say {shown_terminal} ends in 30 s and how to keep it:\n{shown}"
    );
}

/// The reaper ends a closed terminal when the grace ends.
#[test]
fn w7c_the_reaper_ends_a_closed_terminal_when_the_grace_ends() {
    let server = HeadlessServer::start_with_reap_grace("w7c-grace-end", 2);
    let made = run(&server, &["workspace", "create", "--name", "w7c-grace-end"]);
    let pane = field(&made, "pane_id");
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, closing) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let closed = run(&server, &["tab", &tab, "close"]);
    assert_eq!(listed(&closed, "ending_terminal_ids"), [closing.as_str()], "{closed}");
    assert_ended(&server, &closing, "the 2 s grace");
    assert_no_tabless(&server, "the 2 s grace");
}

/// `--keep-terminals` keeps a terminal from the reaper too (lead, W7-C): it
/// marks each terminal the close leaves as kept. A plain close in the same
/// window is the signal that the grace ran out: when the reaper has ended
/// its terminal, a kept one closed before it must still run.
#[test]
fn w7c_keep_terminals_keeps_them_past_the_reapers_grace() {
    let server = HeadlessServer::start_with_reap_grace("w7c-keep-grace", 2);
    let made = run(&server, &["workspace", "create", "--name", "w7c-keep-grace"]);
    let pane = field(&made, "pane_id");
    let split = |server: &HeadlessServer| {
        let split = run(server, &["pane", &pane, "split", "--right"]);
        (field(&split, "tab_id"), field(&split, "terminal_id"))
    };
    let (kept_tab, kept) = split(&server);
    let closed = run(&server, &["tab", &kept_tab, "close", "--keep-terminals"]);
    assert_eq!(listed(&closed, "running_terminal_ids"), [kept.as_str()], "{closed}");

    // A bulk close with --keep-terminals keeps its terminals the same way.
    let tab = |server: &HeadlessServer| {
        let made = run(server, &["tab", "create", "terminal", "--pane", &pane]);
        (field(&made, "tab_id"), field(&made, "terminal_id"))
    };
    let (anchor_tab, _) = tab(&server);
    let (_, bulk_kept) = tab(&server);
    let bulk = run(&server, &["tab", &anchor_tab, "close", "--others", "--keep-terminals"]);
    assert!(listed(&bulk, "running_terminal_ids").contains(&bulk_kept), "{bulk}");

    let (plain_tab, plain) = split(&server);
    run(&server, &["tab", &plain_tab, "close"]);
    assert_ended(&server, &plain, "the 2 s grace of a plain close");
    assert_runs_tabless(&server, &kept, "the reaper after a --keep-terminals close");
    assert_runs_tabless(&server, &bulk_kept, "the reaper after a bulk --keep-terminals close");
}

/// Runs `cmux --json workspace <workspace> close` from inside `caller`, in a
/// new process session (so the daemon cannot match the caller's terminal by
/// its session) with `credential` as its launch credential (None: no
/// credential), with `flags` after `close`. The close's JSON result.
fn close_from_inside(
    server: &HeadlessServer,
    root: &std::path::Path,
    caller: &str,
    workspace: &str,
    credential: Option<&std::path::Path>,
    flags: &str,
) -> Value {
    let out = root.join("close.json");
    let code = root.join("close.code");
    let credential = match credential {
        Some(path) => format!("CMUX_LAUNCH_CREDENTIAL=\"$(cat '{}')\"", path.display()),
        None => "-u CMUX_LAUNCH_CREDENTIAL".to_owned(),
    };
    let script = format!(
        "env {credential} perl -MPOSIX -e 'if (my $p = fork) {{ waitpid($p, 0); exit($? >> 8) }} \
         POSIX::setsid() or die; exec @ARGV' -- sh -c \"'{bin}' --json --socket '{socket}' \
         workspace {workspace} close {flags} > '{out}' 2>&1; echo \\$? > '{code}'\"\r",
        bin = bin(),
        socket = server.socket.display(),
        out = out.display(),
        code = code.display(),
    );
    run(server, &["terminal", caller, "write", "--text", &script]);
    let deadline = Instant::now() + Duration::from_secs(30);
    while !fs::read_to_string(&code).is_ok_and(|code| code.ends_with('\n')) {
        assert!(Instant::now() < deadline, "the close run in {caller} did not finish");
        std::thread::sleep(Duration::from_millis(100));
    }
    let printed = fs::read_to_string(&out).unwrap();
    assert_eq!(fs::read_to_string(&code).unwrap().trim(), "0", "the close failed: {printed}");
    printed
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str(line).ok().filter(Value::is_object))
        .unwrap_or_else(|| panic!("the close printed no JSON: {printed}"))
}

/// A close run from inside a terminal, in a process the daemon cannot match
/// to that terminal by session or by credential (a `setsid` wrapper with no
/// launch credential), still spares the caller's terminal: the daemon finds
/// it from the socket peer's process and its ancestors.
#[test]
fn w7c_a_close_from_a_new_process_session_spares_the_callers_terminal() {
    let root = unique_temp_dir("w7c-peer");
    fs::create_dir_all(&root).unwrap();
    let server = HeadlessServer::start("w7c-peer");
    let made = run(&server, &["workspace", "create", "--name", "w7c-peer"]);
    let (workspace, pane, caller) =
        (field(&made, "workspace_id"), field(&made, "pane_id"), field(&made, "terminal_id"));
    let other = field(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");

    let closed = close_from_inside(&server, &root, &caller, &workspace, None, "");
    assert_ended(&server, &other, "workspace close from a new process session");
    assert_eq!(listed(&closed, "ended_terminal_ids"), [other.as_str()], "{closed}");
    assert_eq!(listed(&closed, "running_terminal_ids"), [caller.as_str()], "{closed}");
    assert_runs_tabless(&server, &caller, "workspace close from a new process session");

    drop(server);
    let _ = fs::remove_dir_all(root);
}

/// A close whose request carries ANOTHER terminal's launch credential (the
/// actor is that terminal) still does not end the terminal the request runs
/// in: no close ends a terminal whose process tree holds the socket peer.
#[test]
fn w7c_a_close_never_ends_the_terminal_its_peer_runs_in() {
    let root = unique_temp_dir("w7c-peer-tree");
    fs::create_dir_all(&root).unwrap();
    let server = HeadlessServer::start("w7c-peer-tree");
    let lender =
        field(&run(&server, &["workspace", "create", "--name", "w7c-lender"]), "terminal_id");
    let credential = root.join("lender.credential");
    let written = root.join("lender.done");
    run(
        &server,
        &[
            "terminal",
            &lender,
            "write",
            "--text",
            &format!(
                "printf %s \"$CMUX_LAUNCH_CREDENTIAL\" > '{}'; touch '{}'\r",
                credential.display(),
                written.display()
            ),
        ],
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    while !written.exists() {
        assert!(Instant::now() < deadline, "terminal {lender} did not write its credential");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        fs::read_to_string(&credential).is_ok_and(|credential| !credential.is_empty()),
        "terminal {lender} has no launch credential"
    );

    let made = run(&server, &["workspace", "create", "--name", "w7c-peer-tree"]);
    let (workspace, pane, caller) =
        (field(&made, "workspace_id"), field(&made, "pane_id"), field(&made, "terminal_id"));
    let other = field(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");

    let closed = close_from_inside(&server, &root, &caller, &workspace, Some(&credential), "");
    assert_ended(&server, &other, "workspace close with another terminal's credential");
    assert_eq!(listed(&closed, "ended_terminal_ids"), [other.as_str()], "{closed}");
    assert_eq!(listed(&closed, "running_terminal_ids"), [caller.as_str()], "{closed}");
    assert_runs_tabless(&server, &caller, "workspace close with another terminal's credential");
    assert!(runs(&record(&server, &lender)), "the close ended the lender {lender}");

    drop(server);
    let _ = fs::remove_dir_all(root);
}

/// `--keep-terminals` keeps every terminal the close leaves, the caller's
/// own too (lead, W7-C review): a close run from inside the closed workspace
/// with `--keep-terminals` leaves the caller's terminal running past the
/// reaper's grace, as it leaves the others.
#[test]
fn w7c_keep_terminals_keeps_the_callers_own_terminal_too() {
    let root = unique_temp_dir("w7c-keep-own");
    fs::create_dir_all(&root).unwrap();
    let server = HeadlessServer::start_with_reap_grace("w7c-keep-own", 2);
    let made = run(&server, &["workspace", "create", "--name", "w7c-keep-own"]);
    let (workspace, pane, caller) =
        (field(&made, "workspace_id"), field(&made, "pane_id"), field(&made, "terminal_id"));
    let other = field(&run(&server, &["pane", &pane, "split", "--right"]), "terminal_id");

    let closed = close_from_inside(&server, &root, &caller, &workspace, None, "--keep-terminals");
    let mut running = listed(&closed, "running_terminal_ids");
    running.sort();
    let mut expected = vec![caller.clone(), other.clone()];
    expected.sort();
    assert_eq!(running, expected, "{closed}");
    assert!(listed(&closed, "ending_terminal_ids").is_empty(), "{closed}");

    // A plain close in another workspace: when the reaper has ended its
    // terminal, the grace is over.
    let plain_pane =
        field(&run(&server, &["workspace", "create", "--name", "w7c-keep-own-2"]), "pane_id");
    let split = run(&server, &["pane", &plain_pane, "split", "--right"]);
    let (plain_tab, plain) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    run(&server, &["tab", &plain_tab, "close"]);
    assert_ended(&server, &plain, "the 2 s grace of a plain close");
    assert_runs_tabless(&server, &caller, "the reaper after --keep-terminals from inside");
    assert_runs_tabless(&server, &other, "the reaper after --keep-terminals from inside");

    drop(server);
    let _ = fs::remove_dir_all(root);
}

/// `closed reopen` takes back the `keep` mark a `--keep-terminals` close set
/// (lead, W7-C review): a later plain close of the reopened tab gets the
/// grace again, and the reaper ends the terminal when it runs out.
#[test]
fn w7c_closed_reopen_takes_back_the_keep_of_a_keep_close() {
    let server = HeadlessServer::start_with_reap_grace("w7c-keep-reopen", 2);
    let made = run(&server, &["workspace", "create", "--name", "w7c-keep-reopen"]);
    let pane = field(&made, "pane_id");
    let split = run(&server, &["pane", &pane, "split", "--right"]);
    let (tab, kept) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    let closed = run(&server, &["tab", &tab, "close", "--keep-terminals"]);
    assert_eq!(listed(&closed, "running_terminal_ids"), [kept.as_str()], "{closed}");

    run(&server, &["closed", "reopen"]);
    let reopened = record(&server, &kept).unwrap_or_default();
    let tab = reopened["tab_ids"]
        .as_array()
        .and_then(|tabs| tabs.first())
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("closed reopen gave {kept} no tab: {reopened}"))
        .to_owned();

    let closed = run(&server, &["tab", &tab, "close"]);
    assert_eq!(listed(&closed, "ending_terminal_ids"), [kept.as_str()], "{closed}");
    assert_ended(&server, &kept, "the grace of a plain close after a reopen");
}

/// One `layout.bulk` request with `params`; the reply.
fn bulk_request(server: &HeadlessServer, key: &str, params: Value) -> Value {
    let request = serde_json::json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": "layout.bulk",
        "idempotency_key": key,
        "params": params,
    });
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// `layout.bulk` takes the single close's `terminals` (lead, W7-C review:
/// one enum): `keep` keeps them past the grace, and the legacy
/// `end_terminals` is refused when it disagrees with `terminals`.
#[test]
fn w7c_layout_bulk_takes_the_terminals_of_a_single_close() {
    let server = HeadlessServer::start_with_reap_grace("w7c-bulk-enum", 2);
    let made = run(&server, &["workspace", "create", "--name", "w7c-bulk-enum"]);
    let (workspace, pane) = (field(&made, "workspace_id"), field(&made, "pane_id"));
    let tab = |server: &HeadlessServer| {
        let made = run(server, &["tab", "create", "terminal", "--pane", &pane]);
        (field(&made, "tab_id"), field(&made, "terminal_id"))
    };
    let params = |anchor: &str, extra: Value| {
        let mut params = serde_json::json!({
            "machine": "current",
            "session": "current",
            "workspace": workspace,
            "verb": "close",
            "level": "tab",
            "selector": "others",
            "anchor": anchor,
        });
        for (key, value) in extra.as_object().into_iter().flatten() {
            params[key] = value.clone();
        }
        params
    };

    let (anchor, _) = tab(&server);
    let (_, kept) = tab(&server);
    let refused = bulk_request(
        &server,
        "w7c-bulk-disagree",
        params(&anchor, serde_json::json!({"terminals": "keep", "end_terminals": true})),
    );
    assert_eq!(refused["ok"], false, "end_terminals that disagrees with terminals: {refused}");
    assert_runs_placed(&server, &kept, "a refused layout.bulk");

    let closed = bulk_request(
        &server,
        "w7c-bulk-keep",
        params(&anchor, serde_json::json!({"terminals": "keep"})),
    );
    assert_eq!(closed["ok"], true, "{closed}");
    assert!(listed(&closed["result"], "running_terminal_ids").contains(&kept), "{closed}");

    let plain_pane =
        field(&run(&server, &["workspace", "create", "--name", "w7c-bulk-enum-2"]), "pane_id");
    let split = run(&server, &["pane", &plain_pane, "split", "--right"]);
    let (plain_tab, plain) = (field(&split, "tab_id"), field(&split, "terminal_id"));
    run(&server, &["tab", &plain_tab, "close"]);
    assert_ended(&server, &plain, "the 2 s grace of a plain close");
    assert_runs_tabless(&server, &kept, "the reaper after layout.bulk terminals: keep");
}

/// `terminal` still runs, with a tab.
fn assert_runs_placed(server: &HeadlessServer, terminal: &str, step: &str) {
    let found = record(server, terminal);
    assert!(runs(&found), "{step} ended terminal {terminal}: {}", found.unwrap_or_default());
    let found = found.unwrap();
    assert_ne!(found["tab_ids"], serde_json::json!([]), "{step}: {found}");
}
