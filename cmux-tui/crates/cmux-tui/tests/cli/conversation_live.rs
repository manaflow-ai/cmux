//! A Chief's live run frames on the local conversation owner (`chief-live-v1`),
//! over a real headless daemon's WebSocket (the Channels page path) and the
//! Chief's bound Unix connection: the Chief streams its reply's text
//! (`step.delta`) and a "working on" line (`run.activity`) while its run is
//! running; a page that asked for live frames hears each one, a page that
//! joins late reads the text so far (`conversation-live`, a `run.live`
//! snapshot), and the run's end frees it. Nothing is stored: the frames are
//! not messages, not run steps, and gone after the run ends.

use serde_json::{Value, json};

use super::conversation_runs::{Unix, append, bound, refused};
use super::conversation_tree::{TOKEN, Ws, ws_addr};
use super::*;

const TURN: &str = "turn:optchat:msg_live:1791968737566";

fn live_event(page: &mut Ws) -> Value {
    loop {
        let event = page.events.pop_front().unwrap_or_else(|| page.read());
        if event["event"] == "conversation-live" {
            return event;
        }
    }
}

fn delta(conversation: &str, step: &str, kind: &str, seq: u64, text: &str) -> Value {
    json!({"conversation": conversation, "frame": {
        "type": "step.delta", "conversation": conversation, "run": TURN,
        "step": step, "kind": kind, "seq": seq, "text": text}})
}

fn live_page(server: &HeadlessServer) -> Ws {
    let mut page = Ws::open(&ws_addr(server));
    page.request(
        "set-client-info",
        json!({"name": "page", "capabilities": ["conversation-runs-v1", "chief-live-v1"]}),
    );
    page.request("subscribe", json!({}));
    page
}

#[test]
fn a_chief_streams_its_run_live_and_a_late_page_reads_the_text_so_far() {
    let config = json!({"server": {"ws": "127.0.0.1:0", "ws_token": TOKEN}}).to_string();
    let server = HeadlessServer::start_with_config("conversation-live", Some(&config));
    let mut page = live_page(&server);
    let identity = page.request("identify", json!({}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|c| c == "chief-live-v1"),
        "{identity}"
    );
    // A page that reads runs but did not ask for live frames.
    let mut plain = Ws::open(&ws_addr(&server));
    plain.request(
        "set-client-info",
        json!({"name": "old", "capabilities": ["conversation-runs-v1"]}),
    );
    plain.request("subscribe", json!({}));
    let channel = page.create_channel("live-channel", "release");
    let mut home = Unix::open(&server.socket);
    let mut chief = bound(&server, &mut home, "agent_mux");

    // No run yet: nothing live, and a frame for an unknown run is refused.
    let empty = page.request("conversation-live", json!({"conversation": channel}));
    assert_eq!(
        empty,
        json!({"type": "run.live", "t": "run.live", "conversation": channel, "runs": []})
    );
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 0, "x")),
        "unknown_run",
    );

    chief.request(
        "conversation-run-append",
        append(&channel, json!({"id": TURN, "turn": TURN, "status": "running"}), json!([])),
    );

    // The reply streams in two frames, the page hears both as sent.
    chief.request("conversation-live-publish", delta(&channel, "talk:0", "talk", 0, "Checking "));
    chief.request(
        "conversation-live-publish",
        delta(&channel, "talk:0", "talk", 1, "the 0.43 release."),
    );
    let first = live_event(&mut page);
    assert_eq!(first["conversation"], channel.as_str(), "{first}");
    assert_eq!(
        first["frame"],
        json!({"type": "step.delta", "t": "step.delta", "conversation": channel, "run": TURN,
               "author": "agent_mux",
               "step": "talk:0", "kind": "talk", "seq": 0, "text": "Checking "}),
    );
    let second = live_event(&mut page);
    assert_eq!(second["frame"]["seq"], 1, "{second}");
    assert_eq!(second["frame"]["text"], "the 0.43 release.", "{second}");

    // A "working on" line: the newest wins.
    for line in ["Thinking", "Running gh release list"] {
        chief.request(
            "conversation-live-publish",
            json!({"conversation": channel, "frame": {"type": "run.activity", "conversation": channel,
                   "run": TURN, "line": line, "since": 1_791_968_740_000u64, "at": 1_791_968_741_000u64}}),
        );
        assert_eq!(live_event(&mut page)["frame"]["line"], line);
    }
    chief.request(
        "conversation-live-publish",
        delta(&channel, "thought:0", "thought", 0, "The tag list is short."),
    );
    assert_eq!(live_event(&mut page)["frame"]["kind"], "thought");

    // A page that joins now reads the text so far and the newest line.
    let mut late = live_page(&server);
    let snapshot = late.request("conversation-live", json!({"conversation": channel}));
    assert_eq!(
        snapshot,
        json!({"type": "run.live", "t": "run.live", "conversation": channel, "runs": [{
            "run": TURN,
            "author": "agent_mux",
            "steps": [
                {"step": "talk:0", "kind": "talk", "seq": 1, "text": "Checking the 0.43 release."},
                {"step": "thought:0", "kind": "thought", "seq": 0, "text": "The tag list is short."}
            ],
            "activity": {"line": "Running gh release list", "since": 1_791_968_740_000u64,
                         "at": 1_791_968_741_000u64}
        }]}),
    );

    // The producer never skips a frame; a gap, a bad frame, a person, another agent are refused.
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 3, "x")),
        "seq_gap",
    );
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 2, "")),
        "invalid_live",
    );
    refused(
        &chief.reply(
            "conversation-live-publish",
            delta(&channel, "talk:0", "talk", 2, &"x".repeat(4097)),
        ),
        "invalid_live",
    );
    refused(
        &chief.reply(
            "conversation-live-publish",
            json!({"conversation": channel, "frame": {"type": "run.activity", "conversation": channel,
                   "run": TURN, "line": "two\nlines", "since": 1, "at": 2}}),
        ),
        "invalid_live",
    );
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "tool:1", "tool", 0, "x")),
        "bad request",
    );
    refused(
        &page.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 2, "x")),
        "not_agent",
    );
    let mut builder = bound(&server, &mut home, "agent_builder");
    refused(
        &builder.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 2, "x")),
        "not_run_author",
    );

    // The last frame of a step: no frame after it.
    chief.request(
        "conversation-live-publish",
        json!({"conversation": channel, "frame": {"type": "step.delta", "conversation": channel,
               "run": TURN, "step": "talk:0", "kind": "talk", "seq": 2, "text": " Done.", "final": true}}),
    );
    assert_eq!(live_event(&mut page)["frame"]["final"], true);
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 3, "x")),
        "step_final",
    );
    // Its row is written: the step's live text goes, and no late frame reopens it.
    chief.request(
        "conversation-run-append",
        append(
            &channel,
            json!({"id": TURN}),
            json!([{"id": "talk:0", "kind": "talk", "text": "Checking the 0.43 release. Done."}]),
        ),
    );
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "talk:0", "talk", 0, "again")),
        "step_final",
    );
    let freed = late.request("conversation-live", json!({"conversation": channel}));
    assert!(
        freed["runs"][0]["steps"].as_array().unwrap().iter().all(|s| s["step"] != "talk:0"),
        "{freed}"
    );

    // A producer that retries starts the step again at seq 0: its text is
    // replaced and the pages get the conversation's run.live.
    chief.request("conversation-live-publish", delta(&channel, "talk:2", "talk", 0, "First try"));
    chief.request("conversation-live-publish", delta(&channel, "talk:2", "talk", 1, " goes on"));
    chief.request("conversation-live-publish", delta(&channel, "talk:2", "talk", 0, "Second try"));
    let reset = loop {
        let event = live_event(&mut page);
        if event["frame"]["type"] == "run.live" {
            break event;
        }
    };
    let retried = reset["frame"]["runs"][0]["steps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["step"] == "talk:2")
        .cloned()
        .unwrap();
    assert_eq!(retried, json!({"step": "talk:2", "kind": "talk", "seq": 0, "text": "Second try"}));

    // The buffer keeps at most 64 KiB of a step: the tail, with the seq of the last frame.
    for seq in 0..17u64 {
        let letter = char::from(b'a' + seq as u8).to_string();
        chief.request(
            "conversation-live-publish",
            delta(&channel, "talk:1", "talk", seq, &letter.repeat(4096)),
        );
    }
    let capped = late.request("conversation-live", json!({"conversation": channel}));
    let long = capped["runs"][0]["steps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["step"] == "talk:1")
        .cloned()
        .unwrap();
    assert_eq!(long["seq"], 16, "{long}");
    let text = long["text"].as_str().unwrap();
    assert_eq!(text.len(), 64 * 1024);
    assert!(text.starts_with('b') && text.ends_with(&"q".repeat(4096)), "the tail is kept");

    // The run ends: nothing is live, and the frames were never stored.
    chief.request(
        "conversation-run-append",
        append(&channel, json!({"id": TURN, "status": "done"}), json!([])),
    );
    let ended = late.request("conversation-live", json!({"conversation": channel}));
    assert_eq!(ended["runs"], json!([]), "{ended}");
    refused(
        &chief.reply("conversation-live-publish", delta(&channel, "talk:3", "talk", 0, "x")),
        "run_not_running",
    );
    // Only the row the Chief wrote is stored, never the frames.
    let run = page.request("conversation-run", json!({"conversation": channel, "run": TURN}));
    assert_eq!(run["steps"].as_array().unwrap().len(), 1, "{run}");
    let snapshot =
        page.request("conversation-snapshot", json!({"conversation": channel, "tail": 50}));
    assert!(!snapshot.to_string().contains("Checking the 0.43"), "{snapshot}");

    // The page that did not ask heard no live frame: the run's end is the
    // next run event on its stream after the start.
    let mut runs_seen = 0;
    loop {
        let event = plain.events.pop_front().unwrap_or_else(|| plain.read());
        assert_ne!(event["event"], "conversation-live", "{event}");
        if event["event"] == "conversation-run-changed" {
            runs_seen += 1;
            if event["run"]["status"] == "done" {
                break;
            }
        }
    }
    assert_eq!(runs_seen, 3);
}
