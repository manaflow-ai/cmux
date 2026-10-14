//! The person's own list state on the local conversation owner
//! (`conversation-inbox-state-v1`), over a real headless daemon's WebSocket
//! (the Channels page path) and a Chief's bound Unix connection: the page
//! pins conversations in its own order and marks one unread; its
//! `conversation-list` and its stream show it; the Chief, a participant of the
//! same conversations, never sees the person's pins and keeps its own; no pin
//! moves a conversation's `rev`; the state survives a daemon restart.

use serde_json::{Value, json};

use super::conversation_tree::{TOKEN, Ws};
use super::*;

/// A JSON-lines client of the daemon's Unix socket that keeps the events it
/// reads while waiting for a reply.
struct Unix {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    next: u64,
    events: VecDeque<Value>,
}

impl Unix {
    fn open(socket: &std::path::Path) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { reader: BufReader::new(stream), writer, next: 1, events: VecDeque::new() }
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the connection");
        serde_json::from_str(&line).unwrap()
    }

    fn reply(&mut self, cmd: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = params.as_object().cloned().unwrap_or_default();
        body.insert("id".into(), json!(id));
        body.insert("cmd".into(), json!(cmd));
        writeln!(self.writer, "{}", Value::Object(body)).unwrap();
        loop {
            let value = self.read();
            if value.get("event").is_some() {
                self.events.push_back(value);
            } else if value["id"] == id {
                return value;
            }
        }
    }

    fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed: {value}");
        value["data"].clone()
    }

    /// Every event before the `conversation-changed` message event whose
    /// `client_msg_id` is `marker`.
    fn events_before(&mut self, marker: &str) -> Vec<Value> {
        let mut seen = Vec::new();
        loop {
            let event = self.events.pop_front().unwrap_or_else(|| self.read());
            if event["event"] == "conversation-changed"
                && event["change"]["message"]["client_msg_id"] == marker
            {
                return seen;
            }
            seen.push(event);
        }
    }
}

fn pin(conversation: &str, pinned: bool, position: Option<u64>) -> Value {
    let mut op = json!({"kind": "inbox.pin", "pinned": pinned});
    if let Some(position) = position {
        op["position"] = json!(position);
    }
    json!({"conversation": conversation, "op": op})
}

fn mark_unread(conversation: &str, unread: bool) -> Value {
    json!({"conversation": conversation, "op": {"kind": "inbox.mark_unread", "unread": unread}})
}

/// The caller's `conversation-list` item of `id`.
fn listed(list: &Value, id: &str) -> Value {
    list["conversations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|summary| summary["id"] == id)
        .unwrap_or_else(|| panic!("{id} is not listed: {list}"))
        .clone()
}

/// The next `conversation-inbox-changed` event on the page's stream.
fn inbox_event(page: &mut Ws) -> Value {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-inbox-changed" {
            return event;
        }
    }
}

fn rejected(reply: &Value, code: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains(code), "expected {code}: {reply}");
}

/// The newest WebSocket address in the daemon's log (a restart binds anew).
fn last_ws_addr(server: &HeadlessServer) -> String {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let tail = server.stderr_tail();
        if let Some(rest) = tail
            .rsplit("WebSocket control at ws://")
            .next()
            .filter(|_| tail.contains("WebSocket control at ws://"))
        {
            return rest.split_whitespace().next().unwrap().to_owned();
        }
        assert!(Instant::now() < deadline, "no WebSocket listener in the log: {tail}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

/// Stops the daemon (SIGKILL: no shutdown path runs) and starts a new one on
/// the same socket, state directory and config; returns the new WebSocket
/// address.
fn restart(server: &mut HeadlessServer) -> String {
    let before = server.stderr_tail().matches("WebSocket control at ws://").count();
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = fs::remove_file(&server.socket);
    let mut child = Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(&server.socket)
        .arg("--state")
        .arg(&server.state)
        .env("CMUX_TUI_CONFIG", server.dir.join("config.json"))
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(mut pipe) = child.stderr.take() {
        let sink = server.stderr.clone();
        std::thread::spawn(move || {
            let mut chunk = [0_u8; 4096];
            while let Ok(read) = Read::read(&mut pipe, &mut chunk) {
                if read == 0 {
                    break;
                }
                sink.lock().unwrap().extend_from_slice(&chunk[..read]);
            }
        });
    }
    server.child = child;
    server.wait_for_socket();
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let tail = server.stderr_tail();
        if tail.matches("WebSocket control at ws://").count() > before {
            return last_ws_addr(server);
        }
        assert!(Instant::now() < deadline, "the restarted daemon opened no WebSocket: {tail}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn a_person_pins_and_marks_conversations_unread_privately_and_the_state_survives_a_restart() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let mut server = HeadlessServer::start_with_config("conversation-inbox-state", Some(&config));
    let mut page = Ws::open(&last_ws_addr(&server));
    let identity = page.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "conversation-inbox-state-v1"), "{identity}");
    page.request("subscribe", json!({}));
    let release = page.create_channel("inbox-release", "release");
    let design = page.create_channel("inbox-design", "design");
    // A room the Chief is not in.
    let private = page.request(
        "conversation-create",
        json!({"idempotency_key": "inbox-private", "title": "builder", "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Tester"},
            {"id": "agent_builder", "kind": "agent", "display_name": "Builder"}]}),
    )["conversation"]["id"]
        .as_str()
        .unwrap()
        .to_owned();

    // The Chief (agent_mux) on its own bound connection, with its own stream.
    let mut home = Unix::open(&server.socket);
    let token =
        home.request("conversation-agent-token", json!({"participant": "agent_mux"}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut chief = Unix::open(&server.socket);
    chief.request("conversation-bind", json!({"participant": "agent_mux", "token": token}));
    chief.request("subscribe", json!({}));

    // Nothing is pinned or marked yet.
    let fresh = page.request("conversation-list", json!({}));
    let release_rev = listed(&fresh, &release)["rev"].clone();
    for id in [&release, &design] {
        let summary = listed(&fresh, id);
        assert_eq!(summary["pinned"], false, "{summary}");
        assert_eq!(summary["marked_unread"], false, "{summary}");
        assert!(summary.get("pin_position").is_none(), "{summary}");
    }

    // The page pins design at a position it chose, then release with no
    // position: release goes after the last pin.
    let pinned = page.request("conversation-inbox-op", pin(&design, true, Some(1_000)));
    assert_eq!(
        pinned,
        json!({"conversation": design, "participant": "user_local", "pinned": true,
               "pin_position": 1_000, "marked_unread": false}),
        "{pinned}"
    );
    let event = inbox_event(&mut page);
    assert_eq!(event["conversation"], json!(design), "{event}");
    assert_eq!(event["participant"], "user_local", "{event}");
    assert_eq!(event["pinned"], true, "{event}");
    assert_eq!(event["pin_position"], 1_000, "{event}");
    assert!(event.get("rev").is_none(), "a pin is not a conversation change: {event}");
    let after = page.request("conversation-inbox-op", pin(&release, true, None));
    assert_eq!(after["pin_position"], 1_001, "{after}");
    assert_eq!(inbox_event(&mut page)["conversation"], json!(release));

    let list = page.request("conversation-list", json!({}));
    assert_eq!(listed(&list, &design)["pin_position"], 1_000, "{list}");
    let release_summary = listed(&list, &release);
    assert_eq!(release_summary["pinned"], true, "{release_summary}");
    assert_eq!(release_summary["pin_position"], 1_001, "{release_summary}");
    // Not a conversation op: the conversation keeps its rev.
    assert_eq!(release_summary["rev"], release_rev, "{release_summary}");

    // The Chief takes part in both rooms but never sees the person's pins:
    // not in its list, not on its stream (a message sent after the pins is
    // the first conversation event it reads).
    let chief_list = chief.request("conversation-list", json!({}));
    for id in [&release, &design] {
        let summary = listed(&chief_list, id);
        assert_eq!(summary["pinned"], false, "{summary}");
        assert!(summary.get("pin_position").is_none(), "{summary}");
    }
    page.sent(&release, "after-pins", None, None);
    let leaked: Vec<Value> = chief
        .events_before("after-pins")
        .into_iter()
        .filter(|event| event["event"] == "conversation-inbox-changed")
        .collect();
    assert!(leaked.is_empty(), "the Chief saw the person's pins: {leaked:?}");

    // The Chief keeps its own pin; the page's state and stream do not change.
    let chief_pin = chief.request("conversation-inbox-op", pin(&release, true, None));
    assert_eq!(chief_pin["participant"], "agent_mux", "{chief_pin}");
    assert_eq!(chief_pin["pin_position"], 0, "{chief_pin}");
    assert_eq!(listed(&chief.request("conversation-list", json!({})), &release)["pin_position"], 0);
    // Sent with a plain request (not `sent`, which drops the events it reads),
    // so every event before this message stays in the page's queue.
    page.request(
        "conversation-op",
        json!({"conversation": release, "idempotency_key": "after-chief-pin",
               "op": {"kind": "message.send", "client_msg_id": "after-chief-pin",
                      "parts": [{"type": "text", "text": "after-chief-pin"}]}}),
    );
    let mut page_events = Vec::new();
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-changed"
            && event["change"]["message"]["client_msg_id"] == "after-chief-pin"
        {
            break;
        }
        page_events.push(event);
    }
    assert!(
        page_events.iter().all(|event| event["event"] != "conversation-inbox-changed"),
        "the page saw the Chief's pin: {page_events:?}"
    );
    assert_eq!(
        listed(&page.request("conversation-list", json!({})), &release)["pin_position"],
        1_001
    );

    // Marked unread, and a pin with no position keeps its place.
    let marked = page.request("conversation-inbox-op", mark_unread(&design, true));
    assert_eq!(marked["marked_unread"], true, "{marked}");
    assert_eq!(marked["pin_position"], 1_000, "{marked}");
    assert_eq!(inbox_event(&mut page)["marked_unread"], true);
    let again = page.request("conversation-inbox-op", pin(&design, true, None));
    assert_eq!(again["pin_position"], 1_000, "{again}");
    assert_eq!(again["marked_unread"], true, "{again}");
    // Unpinned: no position.
    let unpinned = page.request("conversation-inbox-op", pin(&release, false, None));
    assert_eq!(unpinned["pinned"], false, "{unpinned}");
    assert!(unpinned.get("pin_position").is_none(), "{unpinned}");

    // Refusals: an unknown conversation, a room the actor is not in, a bad
    // op, a position past the largest exact integer.
    rejected(
        &page.reply("conversation-inbox-op", pin("conv_00000000000000000000000000", true, None)),
        "unknown_conversation",
    );
    rejected(&chief.reply("conversation-inbox-op", pin(&private, true, None)), "not_participant");
    rejected(
        &page.reply(
            "conversation-inbox-op",
            json!({"conversation": design, "op": {"kind": "inbox.archive", "archived": true}}),
        ),
        "bad request",
    );
    rejected(
        &page.reply("conversation-inbox-op", pin(&design, true, Some(1 << 53))),
        "bad request",
    );

    // The person's state is durable: a new daemon on the same state lists it.
    drop(page);
    drop(chief);
    drop(home);
    let addr = restart(&mut server);
    let mut page = Ws::open(&addr);
    let list = page.request("conversation-list", json!({}));
    let design_summary = listed(&list, &design);
    assert_eq!(design_summary["pinned"], true, "{design_summary}");
    assert_eq!(design_summary["pin_position"], 1_000, "{design_summary}");
    assert_eq!(design_summary["marked_unread"], true, "{design_summary}");
    let release_summary = listed(&list, &release);
    assert_eq!(release_summary["pinned"], false, "{release_summary}");
    // Cleared state leaves nothing behind.
    page.request("conversation-inbox-op", mark_unread(&design, false));
    page.request("conversation-inbox-op", pin(&design, false, None));
    let cleared = listed(&page.request("conversation-list", json!({})), &design);
    assert_eq!(cleared["pinned"], false, "{cleared}");
    assert_eq!(cleared["marked_unread"], false, "{cleared}");
}
