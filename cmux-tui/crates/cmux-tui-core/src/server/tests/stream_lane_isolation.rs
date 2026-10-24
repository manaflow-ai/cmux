//! D5 on the request side: on one shared connection, a view's request never
//! waits behind a blocked request of the control lane
//! (plans/cmux-next/app-daemon-connection-DESIGN.md section 3.3). Plain JSON
//! lines only, so this guard runs against a daemon without stream lanes too.

use super::*;
use std::net::Shutdown;
use std::time::Instant;

#[test]
fn a_view_request_never_waits_behind_a_blocked_control_request_on_the_shared_connection() {
    let mux = test_mux();
    let view = mux.new_workspace(None, Some((80, 24))).unwrap();
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    let socket = TestSocket::new("stream-lane-isolation");
    let listener = transport::listen(&socket.path).unwrap();
    let mut client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));
    let mut reader = BufReader::new(client.try_clone_box().unwrap());
    reader.get_ref().set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut send = |value: Value| {
        writeln!(client, "{value}").unwrap();
        client.flush().unwrap();
    };
    let mut reply = |id: u64, seen: &mut Vec<Value>| loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("a reply in time");
        let value: Value = serde_json::from_str(&line).expect("a JSON line");
        if value["id"] == id {
            return value;
        }
        seen.push(value);
    };

    send(json!({"id": 1, "cmd": "set-client-info", "name": "lane-test", "kind": "frontend",
                "capabilities": ["attach-streams-v1"]}));
    assert_eq!(reply(1, &mut Vec::new())["ok"], true);
    send(json!({"id": 2, "cmd": "attach-surface", "attach_stream": 1, "surface": view.id}));
    assert_eq!(reply(2, &mut Vec::new())["ok"], true);
    // A control request that blocks its lane for 10 s (the pattern never prints)...
    send(json!({"id": 3, "cmd": "wait-for", "surface": other.id, "pattern": "never printed",
                "timeout_ms": 10_000}));
    // ...then a key for the attached view, on its stream.
    let sent_at = Instant::now();
    send(json!({"id": 4, "cmd": "send", "attach_stream": 1, "surface": view.id, "text": "k"}));
    let mut seen = Vec::new();
    let key = reply(4, &mut seen);
    let waited = sent_at.elapsed();

    let _ = client.shutdown(Shutdown::Both);
    handler.join().unwrap();
    mux.shutdown();
    assert_eq!(key["ok"], true, "{key}");
    assert!(
        !seen.iter().any(|value| value["id"] == 3),
        "the key's reply waited for the blocked wait-for ({waited:?})"
    );
    assert!(waited < Duration::from_secs(5), "the key waited {waited:?} behind the control lane");
}

/// D5 on the same surface: a view's input after a blocked `wait-for` of its
/// own surface runs once the wait is registered (accepted), not after the
/// wait's reply. On one serial connection, and with an order by completion,
/// the key waited the whole 10 s.
#[test]
fn a_view_request_never_waits_behind_its_own_surfaces_blocked_wait_for() {
    let mux = test_mux();
    let view = mux.new_workspace(None, Some((80, 24))).unwrap();
    let socket = TestSocket::new("stream-lane-same");
    let listener = transport::listen(&socket.path).unwrap();
    let mut client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));
    let mut reader = BufReader::new(client.try_clone_box().unwrap());
    reader.get_ref().set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut send = |value: Value| {
        writeln!(client, "{value}").unwrap();
        client.flush().unwrap();
    };
    let mut replies = Vec::new();
    let mut reply = |id: u64, replies: &mut Vec<(u64, Instant)>| loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("a reply in time");
        let value: Value = serde_json::from_str(&line).expect("a JSON line");
        if let Some(seen) = value["id"].as_u64() {
            replies.push((seen, Instant::now()));
        }
        if value["id"] == id {
            return value;
        }
    };
    send(json!({"id": 1, "cmd": "set-client-info", "name": "same-surface", "kind": "frontend",
                "capabilities": ["attach-streams-v1"]}));
    reply(1, &mut replies);
    send(json!({"id": 2, "cmd": "attach-surface", "attach_stream": 1, "surface": view.id}));
    reply(2, &mut replies);
    // A wait-for on the view's own surface that blocks for 10 s...
    send(json!({"id": 3, "cmd": "wait-for", "surface": view.id, "pattern": "never printed",
                "timeout_ms": 10_000}));
    // ...then the view's key on its stream.
    let sent_at = Instant::now();
    send(json!({"id": 4, "cmd": "send", "attach_stream": 1, "surface": view.id, "text": "k"}));
    let key = reply(4, &mut replies);
    let waited = sent_at.elapsed();
    let wait_for = reply(3, &mut replies);

    let _ = client.shutdown(Shutdown::Both);
    handler.join().unwrap();
    mux.shutdown();
    assert_eq!(key["ok"], true, "{key}");
    assert_eq!(
        wait_for["ok"], false,
        "the wait-for still timed out at its own deadline: {wait_for}"
    );
    let ids: Vec<u64> = replies.iter().map(|(id, _)| *id).collect();
    assert_eq!(ids, [1, 2, 4, 3], "the key replied after the blocked wait-for (waited {waited:?})");
    eprintln!("same-surface key reply after a blocked wait-for: {waited:?}");
}

/// Ordering is per surface (spec/transports.md): a caller that needs another
/// surface's earlier request done waits for its reply. Here terminal A's
/// program does not read its input for 2 s, so a large send to A blocks on
/// A's stream. A key to B on its own stream replies before it; the close of A
/// waits for A's input; and a `list-workspaces` sent after the close's reply
/// no longer shows A.
#[test]
fn a_list_after_the_close_reply_never_shows_the_closed_terminal_even_when_its_input_blocked() {
    let mux = test_mux();
    let program = "stty raw -echo; printf 'rea''dy'; sleep 2; exec cat >/dev/null";
    let mut spawn = crate::TerminalSpawnOptions::new(None, Vec::new());
    spawn.argv = Some(vec!["/bin/sh".into(), "-c".into(), program.into()]);
    let blocked = mux
        .new_workspace_with_spawn_as(
            &crate::Actor::Daemon,
            Some("blocked".into()),
            spawn,
            Some((80, 24)),
        )
        .unwrap();
    let other = mux.new_workspace(None, Some((80, 24))).unwrap();
    let socket = TestSocket::new("close-then-list");
    let listener = transport::listen(&socket.path).unwrap();
    let mut client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let server_mux = mux.clone();
    let handler = std::thread::spawn(move || handle_connection(server_mux, server));
    let mut reader = BufReader::new(client.try_clone_box().unwrap());
    reader.get_ref().set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut send = |value: Value| {
        writeln!(client, "{value}").unwrap();
        client.flush().unwrap();
    };
    let mut replies: Vec<(u64, Instant)> = Vec::new();
    let mut reply = |id: u64, replies: &mut Vec<(u64, Instant)>| loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("a reply in time");
        let value: Value = serde_json::from_str(&line).expect("a JSON line");
        if let Some(seen) = value["id"].as_u64() {
            replies.push((seen, Instant::now()));
        }
        if value["id"] == id {
            return value;
        }
    };

    send(json!({"id": 1, "cmd": "set-client-info", "name": "close-then-list",
                "kind": "frontend", "capabilities": ["attach-streams-v1"]}));
    reply(1, &mut replies);
    send(json!({"id": 2, "cmd": "attach-surface", "attach_stream": 1, "surface": blocked.id}));
    assert_eq!(reply(2, &mut replies)["ok"], true);
    send(json!({"id": 3, "cmd": "attach-surface", "attach_stream": 2, "surface": other.id}));
    assert_eq!(reply(3, &mut replies)["ok"], true);
    // The program is in raw mode and not reading.
    send(json!({"id": 4, "cmd": "wait-for", "surface": blocked.id, "pattern": "ready",
                "timeout_ms": 10_000}));
    assert_eq!(reply(4, &mut replies)["ok"], true);

    let sent_at = Instant::now();
    // More than any PTY input queue holds: the write blocks until `cat` reads.
    let flood = "x".repeat(256 * 1024);
    send(json!({"id": 5, "cmd": "send", "attach_stream": 1, "surface": blocked.id,
                "text": flood}));
    send(json!({"id": 6, "cmd": "send", "attach_stream": 2, "surface": other.id, "text": "k"}));
    send(json!({"id": 7, "cmd": "close-surface", "surface": blocked.id}));
    let close = reply(7, &mut replies);
    // Only after the close's reply: the caller needs A gone.
    send(json!({"id": 8, "cmd": "list-workspaces"}));
    let list = reply(8, &mut replies);

    let _ = client.shutdown(Shutdown::Both);
    handler.join().unwrap();
    mux.shutdown();
    let at =
        |id: u64| replies.iter().find(|(seen, _)| *seen == id).map(|(_, at)| *at).expect("a reply");
    assert!(
        at(5).duration_since(sent_at) >= Duration::from_millis(1500),
        "the send to A did not block, so this test proves nothing ({:?})",
        at(5).duration_since(sent_at)
    );
    assert!(at(6) < at(5), "the key to B waited for A's blocked input");
    assert!(at(7) >= at(5), "the close of A ran before A's earlier input");
    assert_eq!(close["ok"], true, "{close}");
    assert_eq!(list["ok"], true, "{list}");
    assert!(
        !names_surface(&list["data"], blocked.id),
        "list-workspaces after the close reply still shows A: {list}"
    );
    assert!(names_surface(&list["data"], other.id), "B is missing: {list}");
}

/// Whether a tab of the workspace tree names `surface`.
fn names_surface(value: &Value, surface: SurfaceId) -> bool {
    match value {
        Value::Object(map) => map.iter().any(|(key, value)| {
            (key == "surface" && value.as_u64() == Some(surface)) || names_surface(value, surface)
        }),
        Value::Array(items) => items.iter().any(|item| names_surface(item, surface)),
        _ => false,
    }
}
