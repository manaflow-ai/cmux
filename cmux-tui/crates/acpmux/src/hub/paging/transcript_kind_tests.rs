use super::*;

fn mux(kind: &str) -> EventRecord {
    EventRecord {
        seq: 1,
        at: 0,
        dir: "mux".into(),
        kind: kind.into(),
        msg: json!({}),
        host_seq: None,
    }
}

/// A chat client that follows `transcript` sees every change to the
/// queue it shows: Edit queued prompt (`queue_updated`), Move up / Move
/// down (`queue_order`), and a queue held after a failed turn.
#[test]
fn queue_edits_are_transcript_records() {
    for kind in [
        "queued",
        "dequeued",
        "queue_removed",
        "queue_updated",
        "queue_order",
        "queue_paused",
        "queue_resumed",
        "queue_approved",
        "queue_declined",
    ] {
        assert!(is_transcript(&mux(kind)), "{kind} is not a transcript record");
    }
}

/// A chat client reads a subagent nothing will end any more as stopped
/// when the agent process behind the chat went away or started again.
#[test]
fn agent_process_changes_are_transcript_records() {
    for kind in ["stopped", "exited", "resumed", "reopened", "host_started", "host_ended"] {
        assert!(is_transcript(&mux(kind)), "{kind} is not a transcript record");
    }
}

/// A chat client notes a policy its harness cannot keep where it was
/// logged, as it notes a failover.
#[test]
fn an_unenforced_policy_is_a_transcript_record() {
    assert!(is_transcript(&mux("policy_unenforced")));
    let transcript = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
    assert!(!transcript.surely_skips(b"mux", b"policy_unenforced"));
}

/// A suggested next prompt reaches a `transcript` stream live, but no page holds it: pages
/// read with `matches` and `surely_skips`, the live stream with `matches_live`.
#[test]
fn a_prompt_suggestion_is_heard_live_but_never_paged() {
    let rec = EventRecord {
        seq: 1,
        at: 0,
        dir: "in".into(),
        kind: "prompt_suggestion".into(),
        msg: json!({"method": method::SESSION_UPDATE, "params": {"sessionId": "s", "update": {"sessionUpdate": "prompt_suggestion", "suggestion": "go on"}}}),
        host_seq: None,
    };
    let transcript = EventFilter::parse(Some(&json!(["transcript"]))).unwrap();
    assert!(!transcript.matches(&rec), "a page must leave it out");
    assert!(transcript.surely_skips(b"in", b"prompt_suggestion"));
    assert!(transcript.matches_live(&rec), "the live stream must send it");
    let usage = EventFilter::parse(Some(&json!(["usage_update"]))).unwrap();
    assert!(!usage.matches_live(&rec), "only a transcript stream hears it");
    // A raw harness line of that name is not an agent update.
    let mut raw = rec.clone();
    raw.msg = json!({});
    assert!(!transcript.matches_live(&raw));
}

/// A subagent pane opened on a subagent the chat's page no longer holds reads that subagent's
/// records alone: its spawn and end (`subagents[].id`) and its own updates (`subagent`), never
/// the chat's own words, another subagent's, or a mux record.
#[test]
fn a_subagent_filter_keeps_only_that_subagents_records() {
    let update = |seq: u64, mux: Value, text: &str| EventRecord {
        seq,
        at: 0,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"method": method::SESSION_UPDATE, "params": {"sessionId": "s",
                "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}},
                "_meta": {"acpmux": mux}}}),
        host_seq: None,
    };
    let spawn =
        update(1, json!({"subagents": [{"id": "s/t1", "parent": null, "state": "running"}]}), "");
    let own = update(2, json!({"subagent": "s/t1"}), "the child's words");
    let other = update(3, json!({"subagent": "s/t2"}), "another child's words");
    let chat = update(4, json!({}), "the chat's own words");
    let end =
        update(5, json!({"subagents": [{"id": "s/t1", "parent": null, "state": "completed"}]}), "");
    let filter =
        EventFilter::parse(Some(&json!(["transcript"]))).unwrap().of_subagent(Some("s/t1"));
    let kept: Vec<u64> = [&spawn, &own, &other, &chat, &end]
        .iter()
        .filter(|r| filter.matches(r))
        .map(|r| r.seq)
        .collect();
    assert_eq!(kept, [1, 2, 5]);
    assert!(!filter.matches(&mux("turn_result")));
    assert!(filter.surely_skips(b"mux", b"turn_result"));
    assert!(!filter.surely_skips(b"in", b"agent_message_chunk"));
    // No id, or a blank one, filters nothing.
    let all = EventFilter::parse(Some(&json!(["transcript"]))).unwrap().of_subagent(Some(""));
    assert!(all.matches(&chat));
}
