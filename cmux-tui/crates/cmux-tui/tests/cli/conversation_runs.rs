//! Agent runs on the local conversation owner (`conversation-runs-v1`), over
//! a real headless daemon's WebSocket (the Channels page path) and a Chief's
//! bound Unix connection: the Chief writes the trajectory of its turn (a tool
//! call that starts and ends, a reply segment, the run's end with its cost),
//! the page that asked for runs sees every append live, reads the run by the
//! reply's key and pages its steps, and the owner refuses writers that are
//! not the run's agent and links a page must not open.

use serde_json::{Value, json};

use super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

/// A JSON-lines client of the daemon's Unix socket.
pub(super) struct Unix {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    next: u64,
}

impl Unix {
    pub(super) fn open(socket: &std::path::Path) -> Self {
        let stream = transport::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { reader: BufReader::new(stream), writer, next: 1 }
    }

    pub(super) fn reply(&mut self, cmd: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        let mut body = params.as_object().cloned().unwrap_or_default();
        body.insert("id".into(), json!(id));
        body.insert("cmd".into(), json!(cmd));
        writeln!(self.writer, "{}", Value::Object(body)).unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the connection");
            let value: Value = serde_json::from_str(&line).unwrap();
            if value.get("event").is_none() && value["id"] == id {
                return value;
            }
        }
    }

    pub(super) fn request(&mut self, cmd: &str, params: Value) -> Value {
        let value = self.reply(cmd, params);
        assert_eq!(value["ok"], true, "{cmd} failed: {value}");
        value["data"].clone()
    }
}

/// An agent connection bound as `participant`.
pub(super) fn bound(server: &HeadlessServer, home: &mut Unix, participant: &str) -> Unix {
    let token =
        home.request("conversation-agent-token", json!({"participant": participant}))["token"]
            .as_str()
            .unwrap()
            .to_owned();
    let mut agent = Unix::open(&server.socket);
    agent.request("conversation-bind", json!({"participant": participant, "token": token}));
    agent
}

/// The next `conversation-run-changed` event on the page's stream.
fn run_event(page: &mut Ws) -> Value {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-run-changed" {
            return event;
        }
    }
}

pub(super) fn append(conversation: &str, run: Value, steps: Value) -> Value {
    json!({"conversation": conversation, "run": run, "steps": steps})
}

pub(super) fn refused(reply: &Value, reason: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains(reason), "expected {reason}: {reply}");
}

const TURN: &str = "turn:optchat:msg_1:1791968737566";

#[test]
fn conversation_run_pages_keep_timestamp_ties_across_agents() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("conversation-run-ties", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let channel = page.create_channel("run-ties-channel", "release");
    let mut home = Unix::open(&server.socket);
    let mut chief = bound(&server, &mut home, "agent_mux");
    let mut builder = bound(&server, &mut home, "agent_builder");
    for (index, started_at) in [40, 30, 30, 30, 30, 30, 20, 20, 20].into_iter().enumerate() {
        let writer = if index % 2 == 0 { &mut chief } else { &mut builder };
        writer.request(
            "conversation-run-append",
            append(
                &channel,
                json!({"id": format!("turn:ties:{index}"), "status": "done", "started_at": started_at}),
                json!([]),
            ),
        );
    }

    let first = page.request("conversation-runs", json!({"conversation": channel, "limit": 2}));
    let ids = |page: &Value| -> Vec<String> {
        page["runs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|run| run["id"].as_str().unwrap().to_owned())
            .collect()
    };
    assert_eq!(
        ids(&first),
        ["turn:ties:0", "turn:ties:5", "turn:ties:4", "turn:ties:3", "turn:ties:2", "turn:ties:1"],
        "{first}"
    );
    assert_eq!(first["has_more"], true, "{first}");
    let boundary = first["runs"].as_array().unwrap().last().unwrap()["started_at"].clone();
    let second = page.request(
        "conversation-runs",
        json!({"conversation": channel, "before_started_at": boundary, "limit": 2}),
    );
    assert_eq!(ids(&second), ["turn:ties:8", "turn:ties:7", "turn:ties:6"], "{second}");
    // A final page can exceed the requested limit without having older rows.
    assert_eq!(second["has_more"], false, "{second}");
    let empty = page.request(
        "conversation-runs",
        json!({"conversation": channel, "before_started_at": 20, "limit": 2}),
    );
    assert!(ids(&empty).is_empty(), "{empty}");
    assert_eq!(empty["has_more"], false, "{empty}");
}

#[test]
fn a_chief_writes_its_run_and_a_page_streams_reads_and_pages_it() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("conversation-runs", Some(&config));
    let mut page = Ws::open(&ws_addr(&server));
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == "conversation-runs-v1"),
        "{identity}"
    );
    page.request(
        "set-client-info",
        json!({"name": "page", "capabilities": ["conversation-runs-v1"]}),
    );
    page.request("subscribe", json!({}));
    // An old page that did not ask for runs.
    let mut plain = Ws::open(&ws_addr(&server));
    plain.request("subscribe", json!({}));
    let channel = page.create_channel("runs-channel", "release");
    let mut home = Unix::open(&server.socket);
    let mut chief = bound(&server, &mut home, "agent_mux");
    let asked = page.sent(&channel, "ask", None, None);
    let asked_id = asked["id"].as_str().unwrap().to_owned();

    // The turn starts: the run and its first tool call, still running.
    let started = chief.request(
        "conversation-run-append",
        append(
            &channel,
            json!({"id": TURN, "turn": TURN, "answers": [asked_id], "status": "running",
                   "title": "Checking the 0.43 release", "harness": "claude",
                   "session": {"kind": "acpmux", "id": "01a139a8-f91e-7be2-86aa-516bf4c7e5e5"}}),
            json!([{"id": "tool:toolu_1", "kind": "tool", "status": "running",
                    "tool": {"name": "Bash", "kind": "execute", "title": "gh release list",
                             "input": {"command": "gh release list --limit 5"}}}]),
        ),
    );
    assert_eq!(started["run"]["author"], "agent_mux", "{started}");
    assert_eq!(started["steps"][0]["seq"], 1, "{started}");
    let event = run_event(&mut page);
    assert_eq!(event["conversation"], channel.as_str(), "{event}");
    assert_eq!(event["run"]["status"], "running", "{event}");
    assert_eq!(event["run"]["step_count"], 1, "{event}");
    assert!(event["run"].get("ended_at").is_none(), "{event}");
    assert_eq!(event["steps"][0]["tool"]["input"]["command"], "gh release list --limit 5");
    let first_at = event["steps"][0]["at"].clone();

    // The tool ends with its output and a changed file; a reply segment follows.
    chief.request(
        "conversation-run-append",
        append(
            &channel,
            json!({"id": TURN}),
            json!([
                {"id": "tool:toolu_1", "kind": "tool", "status": "done",
                 "tool": {"name": "Bash", "kind": "execute", "title": "gh release list",
                          "input": {"command": "gh release list --limit 5"},
                          "output": "v0.65.2\nv0.65.1", "exit_code": 0,
                          "files": [{"path": "notes/0.43.md", "new_text": "No 0.43 candidate.\n",
                                     "added": 1, "removed": 0}]}},
                {"id": "talk:0", "kind": "talk", "text": "No 0.43 candidate exists.",
                 "links": [{"label": "Agent session",
                            "url": "cmux://chief/5176e030/session/01a139a8-f91e-7be2-86aa-516bf4c7e5e5"}]}
            ]),
        ),
    );
    let event = run_event(&mut page);
    let steps = event["steps"].as_array().unwrap();
    assert_eq!(steps.len(), 2, "{event}");
    // A step keeps its place and first time when it changes.
    assert_eq!(steps[0]["seq"], 1, "{event}");
    assert_eq!(steps[0]["at"], first_at, "{event}");
    assert_eq!(steps[0]["status"], "done", "{event}");
    assert_eq!(steps[0]["tool"]["files"][0]["path"], "notes/0.43.md", "{event}");
    assert_eq!(steps[1]["seq"], 2, "{event}");
    assert!(steps[1]["rev"].as_u64() > steps[0]["rev"].as_u64(), "{event}");
    let tool_rev = steps[0]["rev"].as_u64().unwrap();

    // The run ends with its use and cost; the owner stamps the end.
    chief.request(
        "conversation-run-append",
        append(
            &channel,
            json!({"id": TURN, "status": "done", "cost_usd": 0.0421, "model": "claude-opus-5-5",
                   "usage": {"input": 1200, "output": 340, "cache_read": 46000}}),
            json!([]),
        ),
    );
    let event = run_event(&mut page);
    assert_eq!(event["run"]["status"], "done", "{event}");
    assert!(event["run"]["ended_at"].as_u64().is_some(), "{event}");
    assert_eq!(event["run"]["cost_usd"], 0.0421, "{event}");
    assert_eq!(event["run"]["usage"]["cache_read"], 46000, "{event}");

    // The reply carries the turn key: the page finds the run by it.
    chief.request(
        "conversation-op",
        json!({"conversation": channel, "idempotency_key": TURN,
               "op": {"kind": "message.send", "client_msg_id": TURN,
                      "parts": [{"type": "text", "text": "No 0.43 candidate exists."}]}}),
    );
    let found =
        page.request("conversation-runs", json!({"conversation": channel, "turns": [TURN]}));
    assert_eq!(found["runs"].as_array().unwrap().len(), 1, "{found}");
    assert_eq!(found["runs"][0]["id"], TURN, "{found}");
    assert_eq!(found["runs"][0]["answers"][0], asked_id.as_str(), "{found}");
    let newest = page.request("conversation-runs", json!({"conversation": channel}));
    assert_eq!(newest["runs"][0]["id"], TURN, "{newest}");
    assert_eq!(newest["has_more"], false, "{newest}");

    // Every step, then only what changed after a revision the page holds.
    let all = page.request("conversation-run", json!({"conversation": channel, "run": TURN}));
    let ids: Vec<&str> =
        all["steps"].as_array().unwrap().iter().map(|s| s["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["tool:toolu_1", "talk:0"], "{all}");
    assert_eq!(all["has_more"], false, "{all}");
    let later = page.request(
        "conversation-run",
        json!({"conversation": channel, "run": TURN, "after_rev": tool_rev}),
    );
    assert_eq!(later["steps"].as_array().unwrap().len(), 1, "{later}");
    assert_eq!(later["steps"][0]["id"], "talk:0", "{later}");
    let paged =
        page.request("conversation-run", json!({"conversation": channel, "run": TURN, "limit": 1}));
    assert_eq!(paged["has_more"], true, "{paged}");

    // The old page saw the conversation but never a run: the reply's message
    // event is the first conversation event on its stream.
    loop {
        let event = plain.events.pop_front().unwrap_or_else(|| plain.read());
        assert_ne!(event["event"], "conversation-run-changed", "{event}");
        if event["event"] == "conversation-changed"
            && event["change"]["message"]["client_msg_id"] == TURN
        {
            break;
        }
    }

    // Only the run's own agent writes it; a person never does.
    let person =
        page.reply("conversation-run-append", append(&channel, json!({"id": "turn:x"}), json!([])));
    refused(&person, "not_agent");
    let mut builder = bound(&server, &mut home, "agent_builder");
    let other =
        builder.reply("conversation-run-append", append(&channel, json!({"id": TURN}), json!([])));
    refused(&other, "not_run_author");
    // A link a page must not open, an unknown step kind, an unknown run.
    let script = chief.reply(
        "conversation-run-append",
        append(
            &channel,
            json!({"id": TURN}),
            json!([{"id": "note:1", "kind": "note", "links": [{"label": "x", "url": "javascript:alert(1)"}]}]),
        ),
    );
    refused(&script, "invalid_run");
    let kind = chief.reply(
        "conversation-run-append",
        append(&channel, json!({"id": TURN}), json!([{"id": "x:1", "kind": "shell"}])),
    );
    refused(&kind, "bad request");
    let unknown =
        page.reply("conversation-run", json!({"conversation": channel, "run": "turn:none"}));
    refused(&unknown, "unknown_run");
    let nowhere = chief.reply(
        "conversation-run-append",
        append("conv_00000000000000000000000000", json!({"id": TURN}), json!([])),
    );
    refused(&nowhere, "unknown_conversation");

    // A conversation keeps its newest 200 runs: a new run past them drops the oldest finished one.
    for index in 0..200 {
        chief.request(
            "conversation-run-append",
            append(
                &channel,
                json!({"id": format!("turn:bulk:{index}"), "status": "done", "started_at": 1_000_000 + index}),
                json!([]),
            ),
        );
    }
    let kept = page.request("conversation-runs", json!({"conversation": channel, "limit": 200}));
    assert_eq!(kept["runs"].as_array().unwrap().len(), 200, "{kept}");
    assert_eq!(kept["has_more"], false, "{kept}");
    let oldest =
        page.reply("conversation-run", json!({"conversation": channel, "run": "turn:bulk:0"}));
    refused(&oldest, "unknown_run");
}
