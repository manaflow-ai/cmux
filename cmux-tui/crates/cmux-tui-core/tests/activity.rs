#![cfg(unix)]
//! VM activity sender, daemon side (plans/cmux-next/cloud-automation.md 27): `subscribe-activity`
//! streams times and counts only, pushed on change, never polled.

use cmux_tui_core::Actor;
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

fn connect(path: &Path) -> BufReader<UnixStream> {
    let stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
    BufReader::new(stream)
}

fn send(stream: &mut BufReader<UnixStream>, value: Value) {
    writeln!(stream.get_mut(), "{value}").unwrap();
}

fn read(stream: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    assert_ne!(stream.read_line(&mut line).unwrap(), 0);
    serde_json::from_str(&line).unwrap()
}

/// Reads lines until the reply with `id` (skipping stream events such as vt-state).
fn reply(stream: &mut BufReader<UnixStream>, id: u64) -> Value {
    loop {
        let value = read(stream);
        if value["id"] == id {
            return value;
        }
    }
}

fn rpc(stream: &mut BufReader<UnixStream>, id: u64, mut value: Value) -> Value {
    value["id"] = json!(id);
    send(stream, value);
    reply(stream, id)
}

/// Reads activity-changed events until `pred` holds for the activity body.
fn activity_until(watcher: &mut BufReader<UnixStream>, pred: impl Fn(&Value) -> bool) -> Value {
    loop {
        let event = read(watcher);
        assert_eq!(
            event["event"], "activity-changed",
            "only activity events on this stream: {event}"
        );
        let activity = event["activity"].clone();
        for key in ["attached_clients", "live_agents"] {
            assert!(activity[key].is_u64(), "{key} is a count: {activity}");
        }
        if pred(&activity) {
            return activity;
        }
    }
}

#[test]
fn subscribe_activity_streams_input_agent_actions_and_people() {
    let mux = Mux::new("activity-integration", SurfaceOptions::default());
    let surface =
        mux.new_workspace_as(&Actor::Daemon, Some("work".into()), Some((80, 24))).unwrap();
    let socket =
        std::env::temp_dir().join(format!("cmux-activity-{}", std::process::id())).join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();

    let mut probe = connect(&socket);
    let identify = rpc(&mut probe, 1, json!({"cmd": "identify"}));
    let caps = identify["data"]["capabilities"].as_array().unwrap();
    assert!(caps.iter().any(|c| c == "vm-activity-v1"), "identify advertises vm-activity-v1");

    // Snapshot first: nothing has happened yet.
    let mut watcher = connect(&socket);
    let first = rpc(&mut watcher, 1, json!({"cmd": "subscribe-activity"}));
    assert_eq!(first["ok"], true, "{first}");
    let start = &first["data"]["activity"];
    assert_eq!(start["attached_clients"], 0);
    assert_eq!(start["live_agents"], 0);
    assert!(start["last_user_input_at_ms"].is_null());
    assert!(start["last_agent_action_at_ms"].is_null());

    // A person's client attaches: one attached client.
    let mut person = connect(&socket);
    rpc(&mut person, 1, json!({"cmd": "set-client-info", "name": "phone", "kind": "tui"}));
    rpc(&mut person, 2, json!({"cmd": "attach-surface", "surface": surface.id}));
    activity_until(&mut watcher, |a| a["attached_clients"] == 1);

    // Their input sets the user input time.
    rpc(&mut person, 3, json!({"cmd": "send", "surface": surface.id, "text": "ls\r"}));
    let typed =
        activity_until(&mut watcher, |a| a["last_user_input_at_ms"].as_u64().unwrap_or(0) > 0);
    let typed_at = typed["last_user_input_at_ms"].as_u64().unwrap();

    // An agent working is a live agent and an agent action; done is not live.
    rpc(
        &mut probe,
        2,
        json!({"cmd": "report-agent", "surface": surface.id, "state": "working", "source": "socket", "session": "s1"}),
    );
    let working = activity_until(&mut watcher, |a| a["live_agents"] == 1);
    assert!(working["last_agent_action_at_ms"].as_u64().unwrap_or(0) > 0);
    rpc(
        &mut probe,
        3,
        json!({"cmd": "report-agent", "surface": surface.id, "state": "done", "source": "socket", "session": "s1"}),
    );
    activity_until(&mut watcher, |a| a["live_agents"] == 0);

    // The person leaves.
    drop(person);
    activity_until(&mut watcher, |a| a["attached_clients"] == 0);

    // A one-shot send from an unattached connection (automation) is not user input.
    rpc(&mut probe, 4, json!({"cmd": "send", "surface": surface.id, "text": "echo bot\r"}));
    rpc(
        &mut probe,
        5,
        json!({"cmd": "report-agent", "surface": surface.id, "state": "working", "source": "socket", "session": "s2"}),
    );
    let after = activity_until(&mut watcher, |a| a["live_agents"] == 1);
    assert_eq!(
        after["last_user_input_at_ms"].as_u64(),
        Some(typed_at),
        "automation input does not count"
    );

    mux.shutdown();
    server::cleanup(&socket);
}

/// A cmux.protocol/2 request on `stream`; reads lines until the response with `id`.
fn v2(stream: &mut BufReader<UnixStream>, id: &str, operation: &str, params: Value) -> Value {
    send(
        stream,
        json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
            "idempotency_key": format!("activity-{id}"),
        }),
    );
    loop {
        let value = read(stream);
        if value["id"] == id {
            return value;
        }
    }
}

#[test]
fn v2_terminal_input_counts_only_from_a_persons_attached_client() {
    let mux = Mux::new("activity-v2-input", SurfaceOptions::default());
    let surface =
        mux.new_workspace_as(&Actor::Daemon, Some("work".into()), Some((80, 24))).unwrap();
    let terminal = surface.terminal_public_id().unwrap().to_string();
    let socket = std::env::temp_dir()
        .join(format!("cmux-activity-v2-{}", std::process::id()))
        .join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut watcher = connect(&socket);
    let first = rpc(&mut watcher, 1, json!({"cmd": "subscribe-activity"}));
    assert!(first["data"]["activity"]["last_user_input_at_ms"].is_null());
    let input = |text: &str| json!({"machine": "current", "session": "current", "terminal": terminal, "text": text});

    // An agent's (automation) v2 input never counts: no client info, not attached.
    let mut agent = connect(&socket);
    let reply = v2(&mut agent, "a1", "terminal.input.write", input("echo agent\r"));
    assert_eq!(reply["ok"], true, "{reply}");
    // Force an activity event and check the user input time stayed empty.
    rpc(
        &mut agent,
        2,
        json!({"cmd": "report-agent", "surface": surface.id, "state": "working", "source": "socket", "session": "s1"}),
    );
    let after_agent = activity_until(&mut watcher, |a| a["live_agents"] == 1);
    assert!(
        after_agent["last_user_input_at_ms"].is_null(),
        "agent v2 input must not count: {after_agent}"
    );

    // A person's attached client's v2 input counts.
    let mut person = connect(&socket);
    rpc(&mut person, 1, json!({"cmd": "set-client-info", "name": "phone", "kind": "tui"}));
    rpc(&mut person, 2, json!({"cmd": "attach-surface", "surface": surface.id}));
    let reply = v2(&mut person, "p1", "terminal.input.write", input("ls\r"));
    assert_eq!(reply["ok"], true, "{reply}");
    activity_until(&mut watcher, |a| a["last_user_input_at_ms"].as_u64().unwrap_or(0) > 0);

    mux.shutdown();
    server::cleanup(&socket);
}
