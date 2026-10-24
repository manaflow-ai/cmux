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
