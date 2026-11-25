//! A tab created with no pane in a workspace whose focused pane is the left
//! agent chat dock goes to the right side, never into the dock (cx-ebm.59.5,
//! hq-6d S7: `cmux tab create terminal --workspace <home>` put the terminal
//! into the Home Chief dock). Through a real headless daemon and the CLI.
#![cfg(unix)]

use serde_json::{Value, json};

use super::*;

fn raw(server: &HeadlessServer, request: Value) -> Value {
    try_json_socket_request(&server.socket, request.clone())
        .unwrap_or_else(|| panic!("{request} failed; daemon stderr:\n{}", server.stderr_tail()))
}

/// The raw tree's first screen of the workspace named `name`.
fn screen(server: &HeadlessServer, name: &str) -> Value {
    let tree = raw(server, json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == name)
        .unwrap_or_else(|| panic!("no workspace {name}: {tree}"))["screens"][0]
        .clone()
}

fn pane<'a>(screen: &'a Value, id: &Value) -> &'a Value {
    screen["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] == *id)
        .unwrap_or_else(|| panic!("no pane {id}: {screen}"))
}

fn tabs(screen: &Value, id: &Value) -> usize {
    pane(screen, id)["tabs"].as_array().unwrap().len()
}

/// A workspace `name` with a left dock `dock` holding one chat terminal and
/// two right-side panes: its public id, the dock pane id and the right-side
/// pane ids in layout order.
fn docked_workspace(
    server: &HeadlessServer,
    name: &str,
    dock: Value,
) -> (String, Value, Vec<Value>) {
    raw(server, json!({"cmd": "new-workspace", "name": name, "cols": 160, "rows": 40}));
    let first = screen(server, name);
    let left = first["panes"][0]["id"].clone();
    raw(server, json!({"cmd": "new-pane-right", "pane": left, "width": 0.5}));
    let right = screen(server, name)["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != left)
        .unwrap();
    raw(server, json!({"cmd": "new-tab", "pane": right}));
    let chat =
        pane(&screen(server, name), &right)["tabs"].as_array().unwrap().last().unwrap()["surface"]
            .clone();
    raw(server, json!({"cmd": "move-tab-to-column", "surface": chat, "pane": right, "dock": dock}));
    let docked = screen(server, name);
    assert_eq!(docked["columns"][0]["dock"], dock, "{docked}");
    let dock_pane = docked["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["tabs"].as_array().unwrap().iter().any(|tab| tab["surface"] == chat))
        .unwrap()["id"]
        .clone();
    let right_side = docked["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .filter(|id| *id != dock_pane)
        .collect::<Vec<_>>();
    assert_eq!(right_side.len(), 2, "{docked}");
    let workspace = raw(server, json!({"cmd": "list-workspaces"}))["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == name)
        .unwrap()["resource_id"]
        .as_str()
        .unwrap()
        .to_string();
    (workspace, dock_pane, right_side)
}

/// One `cmux.protocol/2` request with `key`; the whole reply.
fn v2(server: &HeadlessServer, operation: &str, params: Value, key: &str) -> Value {
    let mut fields = json!({"machine": "current", "session": "current"});
    fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "dock-tab",
                         "operation": operation, "idempotency_key": key, "params": fields});
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("{operation}: no JSON reply: {line}"))
}

/// `pane.focus` of the raw pane `id` in `name` (each call its own key).
fn focus(server: &HeadlessServer, name: &str, id: &Value) {
    let resource = pane(&screen(server, name), id)["resource_id"].clone();
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let reply =
        v2(server, "pane.focus", json!({"pane": resource}), &format!("dock-tab-focus-{nanos}"));
    assert_eq!(reply["ok"], true, "{reply}");
}

fn assert_created_on_the_right(server: &HeadlessServer, name: &str, dock: Value) {
    let (workspace, dock_pane, right) = docked_workspace(server, name, dock);
    // The person used the second right-side pane, then went back to the chat.
    focus(server, name, &right[1]);
    focus(server, name, &dock_pane);
    let before = screen(server, name);
    assert_eq!(before["active_pane"], dock_pane, "{before}");

    let output = json_cli(server, &["tab", "create", "terminal", "--workspace", &workspace]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));

    let after = screen(server, name);
    assert_eq!(
        tabs(&after, &dock_pane),
        tabs(&before, &dock_pane),
        "a new tab went into the chat dock: {after}"
    );
    // The right-side pane the person used last gets it (the workspace.open_url rule).
    assert_eq!(
        tabs(&after, &right[1]),
        tabs(&before, &right[1]) + 1,
        "the new tab is not in the right-side pane used last: {after}"
    );
    assert_eq!(tabs(&after, &right[0]), tabs(&before, &right[0]), "{after}");
}

#[test]
fn a_tab_created_in_a_workspace_with_the_chat_dock_focused_goes_right() {
    let server = HeadlessServer::start("dock-tab-chat");
    assert_created_on_the_right(
        &server,
        "dock-tab-chat",
        json!({"edge": "left", "mode": "docked", "role": "agent_chat"}),
    );
}

#[test]
fn a_tab_created_in_a_workspace_with_a_left_dock_focused_goes_right() {
    let server = HeadlessServer::start("dock-tab-left");
    assert_created_on_the_right(
        &server,
        "dock-tab-left",
        json!({"edge": "left", "mode": "docked"}),
    );
}

/// Without a dock, a tab still goes to the focused pane.
#[test]
fn without_a_dock_a_tab_goes_to_the_focused_pane() {
    let server = HeadlessServer::start("dock-tab-none");
    raw(&server, json!({"cmd": "new-workspace", "name": "plain", "cols": 160, "rows": 40}));
    let left = screen(&server, "plain")["panes"][0]["id"].clone();
    raw(&server, json!({"cmd": "new-pane-right", "pane": left, "width": 0.5}));
    focus(&server, "plain", &left);
    let before = screen(&server, "plain");
    let workspace = raw(&server, json!({"cmd": "list-workspaces"}))["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "plain")
        .unwrap()["resource_id"]
        .as_str()
        .unwrap()
        .to_string();
    let output = json_cli(&server, &["tab", "create", "terminal", "--workspace", &workspace]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let after = screen(&server, "plain");
    assert_eq!(tabs(&after, &left), tabs(&before, &left) + 1, "{after}");
}

/// A retry with the same key after the focus left the dock replays the first
/// tab (the idempotency fingerprint is the request as sent, not the pane the
/// daemon chose).
#[test]
fn a_retry_after_the_focus_moved_replays_the_same_tab() {
    let server = HeadlessServer::start("dock-tab-retry");
    let name = "dock-tab-retry";
    let (workspace, dock_pane, right) = docked_workspace(
        &server,
        name,
        json!({"edge": "left", "mode": "docked", "role": "agent_chat"}),
    );
    focus(&server, name, &dock_pane);
    let first =
        v2(&server, "tab.create_terminal", json!({"workspace": workspace}), "dock-tab-retry-1");
    assert_eq!(first["ok"], true, "{first}");
    let after = screen(&server, name);
    assert_eq!(tabs(&after, &dock_pane), 1, "a new tab went into the chat dock: {after}");
    focus(&server, name, &right[0]);
    let again =
        v2(&server, "tab.create_terminal", json!({"workspace": workspace}), "dock-tab-retry-1");
    assert_eq!(again["ok"], true, "the retry did not replay: {again}");
    assert_eq!(again["result"]["value"]["tab_id"], first["result"]["value"]["tab_id"], "{again}");
    let last = screen(&server, name);
    let count = |screen: &Value| -> usize {
        screen["panes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|pane| pane["tabs"].as_array().unwrap().len())
            .sum()
    };
    assert_eq!(count(&last), count(&after), "the retry made a second tab: {last}");
}

/// A workspace `name` as the app opens an agent chat: one pane, not docked,
/// that holds an agent tab bound to `session` (a chat that runs) or to none
/// (the New Tab page). Its public id and that pane's raw id.
fn chat_workspace(server: &HeadlessServer, name: &str, session: Option<&str>) -> (String, Value) {
    raw(server, json!({"cmd": "new-workspace", "name": name, "cols": 160, "rows": 40}));
    let chat_pane = screen(server, name)["panes"][0]["id"].clone();
    let chat = raw(
        server,
        json!({"cmd": "new-conversation-tab", "pane": chat_pane,
               "agent_session": {"host": "install:dock-tab-test", "session": session,
                                 "harness": "claude"}}),
    );
    assert!(chat["tab_resource_id"].is_string(), "no agent tab: {chat}");
    let workspace = raw(server, json!({"cmd": "list-workspaces"}))["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == name)
        .unwrap()["resource_id"]
        .as_str()
        .unwrap()
        .to_string();
    (workspace, chat_pane)
}

/// One `cmux.protocol/2` read (no key); the whole reply.
fn read(server: &HeadlessServer, operation: &str, params: Value) -> Value {
    let mut fields = json!({"machine": "current", "session": "current"});
    fields.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
    let request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "dock-tab-read",
                         "operation": operation, "params": fields});
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("{operation}: no JSON reply: {line}"))
}

fn pane_count(screen: &Value) -> usize {
    screen["panes"].as_array().unwrap().len()
}

/// The app opens an agent chat as one plain pane. A terminal made with only
/// the workspace named (`cmux tab create terminal --workspace`, the Chief's
/// "show the work in the subagent's workspace") had no pane to go to but
/// the chat's own. It opens in a new column on the chat's right, the next
/// one goes to that column, and the focus stays in the chat (Lawrence
/// 2026-11-19: "agent chat that is on left, will open stuff to the right").
#[test]
fn a_terminal_made_in_a_workspace_that_holds_only_a_chat_opens_right_of_it() {
    let server = HeadlessServer::start("dock-tab-lone-chat");
    let name = "dock-tab-lone-chat";
    let (workspace, chat_pane) = chat_workspace(&server, name, Some("dock-tab-chat-1"));
    let before = screen(&server, name);
    assert_eq!(pane_count(&before), 1, "{before}");
    assert_eq!(before["active_pane"], chat_pane, "{before}");

    let output = json_cli(&server, &["tab", "create", "terminal", "--workspace", &workspace]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let after = screen(&server, name);
    assert_eq!(
        tabs(&after, &chat_pane),
        tabs(&before, &chat_pane),
        "a terminal went among the chat's own tabs: {after}"
    );
    assert_eq!(pane_count(&after), 2, "no column was made right of the chat: {after}");
    assert_eq!(after["active_pane"], chat_pane, "the new column took the focus: {after}");
    let right = after["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != chat_pane)
        .unwrap();
    assert_eq!(tabs(&after, &right), 1, "{after}");

    // The next one: a tab in that column, never a third column.
    let output = json_cli(&server, &["tab", "create", "terminal", "--workspace", &workspace]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let last = screen(&server, name);
    assert_eq!(pane_count(&last), 2, "a second terminal made a third column: {last}");
    assert_eq!(tabs(&last, &chat_pane), tabs(&before, &chat_pane), "{last}");
    assert_eq!(tabs(&last, &right), 2, "{last}");
}

/// The new column's terminal keeps what the creation asked for (its name),
/// and a retry with the same key replays it: no second terminal, also now
/// that the chat is no longer alone.
#[test]
fn a_retry_of_a_terminal_opened_right_of_a_lone_chat_replays_it() {
    let server = HeadlessServer::start("dock-tab-lone-retry");
    let name = "dock-tab-lone-retry";
    let (workspace, chat_pane) = chat_workspace(&server, name, Some("dock-tab-chat-2"));
    let before = screen(&server, name);
    let create = || {
        v2(
            &server,
            "tab.create_terminal",
            json!({"workspace": workspace, "name": "build log"}),
            "dock-tab-lone-retry-1",
        )
    };
    let first = create();
    assert_eq!(first["ok"], true, "{first}");
    let after = screen(&server, name);
    assert_eq!(pane_count(&after), 2, "no column was made right of the chat: {after}");
    assert_eq!(tabs(&after, &chat_pane), tabs(&before, &chat_pane), "{after}");
    let made = after["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] != chat_pane)
        .unwrap()
        .to_string();
    assert!(made.contains("\"build log\""), "the new tab lost its name: {made}");

    // The creation's record is under the caller's own key: a caller that
    // lost the reply learns the terminal was made, and does not make another.
    let tab = first["result"]["value"]["tab_id"].as_str().unwrap();
    let resolved = read(
        &server,
        "session.creation.resolve",
        json!({"correlation_key": "dock-tab-lone-retry-1"}),
    )
    .to_string();
    assert!(
        resolved.contains("\"created\"") && resolved.contains(tab),
        "the creation is not resolved by the caller's key: {resolved}"
    );

    let again = create();
    assert_eq!(again["ok"], true, "the retry did not replay: {again}");
    assert_eq!(again["result"]["value"]["tab_id"], first["result"]["value"]["tab_id"], "{again}");
    // The same key with another name is other input: refused, not answered.
    let other = v2(
        &server,
        "tab.create_terminal",
        json!({"workspace": workspace, "name": "another name"}),
        "dock-tab-lone-retry-1",
    );
    assert_eq!(other["ok"], false, "the same key with another name was answered: {other}");
    assert_eq!(other["error"]["code"], "idempotency.conflict", "{other}");
    let last = screen(&server, name);
    assert_eq!(pane_count(&last), 2, "the retry made another column: {last}");
    let right = last["panes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|pane| pane["id"].clone())
        .find(|id| *id != chat_pane)
        .unwrap();
    assert_eq!(tabs(&last, &right), 1, "the retry made a second terminal: {last}");
    assert_eq!(tabs(&last, &chat_pane), tabs(&before, &chat_pane), "{last}");
}

/// An agent tab that runs no session is the New Tab page, not a chat: a
/// terminal made in its workspace stays a tab of that pane.
#[test]
fn a_terminal_made_in_a_workspace_whose_agent_tab_runs_no_session_stays_in_its_pane() {
    let server = HeadlessServer::start("dock-tab-new-tab-page");
    let name = "dock-tab-new-tab-page";
    let (workspace, pane) = chat_workspace(&server, name, None);
    let before = screen(&server, name);
    let output = json_cli(&server, &["tab", "create", "terminal", "--workspace", &workspace]);
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let after = screen(&server, name);
    assert_eq!(pane_count(&after), 1, "{after}");
    assert_eq!(tabs(&after, &pane), tabs(&before, &pane) + 1, "{after}");
}

/// A creation that names the chat's pane keeps it: the caller chose it.
#[test]
fn a_terminal_made_in_the_chats_pane_by_name_stays_there() {
    let server = HeadlessServer::start("dock-tab-named-chat-pane");
    let name = "dock-tab-named-chat-pane";
    let (workspace, chat_pane) = chat_workspace(&server, name, Some("dock-tab-chat-3"));
    let before = screen(&server, name);
    let resource = pane(&before, &chat_pane)["resource_id"].as_str().unwrap().to_string();
    let output = json_cli(
        &server,
        &["tab", "create", "terminal", "--workspace", &workspace, "--pane", &resource],
    );
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let after = screen(&server, name);
    assert_eq!(pane_count(&after), 1, "{after}");
    assert_eq!(tabs(&after, &chat_pane), tabs(&before, &chat_pane) + 1, "{after}");
}

/// A creation the daemon's own path answered (the chat had a pane on its
/// right then) is replayed by that path, also when a retry finds the chat
/// alone: the retry makes no column and no second terminal.
#[test]
fn a_retry_of_a_tab_made_beside_the_chat_replays_it_when_the_chat_is_alone_again() {
    let server = HeadlessServer::start("dock-tab-path-retry");
    let name = "dock-tab-path-retry";
    let (workspace, chat_pane) = chat_workspace(&server, name, Some("dock-tab-chat-4"));
    // A column right of the chat, then a tab the daemon's own path puts there.
    let column =
        v2(&server, "tab.create_terminal", json!({"workspace": workspace}), "dock-tab-path-col");
    assert_eq!(column["ok"], true, "{column}");
    let create = || {
        v2(&server, "tab.create_terminal", json!({"workspace": workspace}), "dock-tab-path-retry-1")
    };
    let first = create();
    assert_eq!(first["ok"], true, "{first}");
    let with_column = screen(&server, name);
    assert_eq!(pane_count(&with_column), 2, "{with_column}");
    // The column closes: the chat is alone again.
    let right = with_column["panes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|pane| pane["id"] != chat_pane)
        .unwrap()["resource_id"]
        .clone();
    let closed = v2(&server, "pane.close", json!({"pane": right}), "dock-tab-path-close");
    assert_eq!(closed["ok"], true, "{closed}");
    let alone = screen(&server, name);
    assert_eq!(pane_count(&alone), 1, "{alone}");

    let again = create();
    assert_eq!(again["ok"], true, "the retry did not replay: {again}");
    assert_eq!(again["result"]["value"]["tab_id"], first["result"]["value"]["tab_id"], "{again}");
    let last = screen(&server, name);
    assert_eq!(pane_count(&last), 1, "the retry made a column: {last}");
    assert_eq!(tabs(&last, &chat_pane), tabs(&alone, &chat_pane), "{last}");
}
