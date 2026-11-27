//! `DaemonHomeSource`'s decisions (what an event publishes, limits, search hits, refusals) and
//! `HomeConversationSession`'s revision rule, pinned through the `mapping.*` ops.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: Value) -> Value {
    call(&format!("mapping.{name}"), &request).unwrap_or_else(|e| panic!("{name}: {e:?}"))
}

fn wire_message(seq: u64) -> Value {
    json!({"id": format!("m{seq}"), "conversation": "c1", "seq": seq, "client_msg_id": "k1",
           "author": "p_me", "parts": [{"type": "text", "text": "hi"}],
           "created_at": "2026-11-25T20:16:00.000Z"})
}

fn summary() -> Value {
    json!({"id": "c1", "title": "Room", "participants": [], "last_seq": 3, "rev": 9,
           "created_at": "2026-11-25T20:00:00Z", "updated_at": "2026-11-25T20:16:00Z"})
}

fn kinds(reply: &Value) -> Vec<String> {
    reply["publish"]
        .as_array()
        .expect("publish")
        .iter()
        .map(|p| p["kind"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[test]
fn a_message_with_its_head_publishes_both() {
    let reply = op(
        "conversationEvent",
        json!({"event": {"rev": 9, "change": {"kind": "message", "message": wire_message(3)}},
               "summary": summary()}),
    );
    assert_eq!(kinds(&reply), ["message", "conversationChanged"]);
    assert_eq!(reply["rereadInbox"], false);
    assert_eq!(reply["publish"][0]["rev"], 9);
    assert_eq!(reply["publish"][0]["message"]["seq"], 3);
}

#[test]
fn a_message_without_a_head_rereads_the_inbox() {
    let reply = op(
        "conversationEvent",
        json!({"event": {"rev": 4, "change": {"kind": "messageUpdated", "message": wire_message(2)}}}),
    );
    assert_eq!(kinds(&reply), ["message"]);
    assert_eq!(reply["rereadInbox"], true);
}

#[test]
fn a_conversation_change_publishes_its_own_head() {
    let reply = op(
        "conversationEvent",
        json!({"event": {"rev": 9, "change": {"kind": "conversation", "head": summary()}}}),
    );
    assert_eq!(kinds(&reply), ["conversationChanged"]);
    assert_eq!(reply["rereadInbox"], true);
    let with_head = op(
        "conversationEvent",
        json!({"event": {"rev": 9, "change": {"kind": "conversation", "head": summary()}},
               "summary": summary()}),
    );
    assert_eq!(with_head["rereadInbox"], false);
}

#[test]
fn a_read_cursor_or_unknown_change_only_republishes_the_head() {
    for kind in ["readCursor", "somethingNew"] {
        let reply = op(
            "conversationEvent",
            json!({"event": {"rev": 2, "change": {"kind": kind}}, "summary": summary()}),
        );
        assert_eq!(kinds(&reply), ["conversationChanged"], "{kind}");
    }
}

#[test]
fn refusals_map_as_swift_names_them() {
    let rejected = |error: Value| op("rejection", json!({"error": error}))["rejection"].clone();
    assert_eq!(
        rejected(json!({"kind": "command", "code": "conversation_rejected", "message": "no"})),
        json!({"kind": "invalid", "message": "no"})
    );
    assert_eq!(
        rejected(json!({"kind": "command", "code": "attachment_rejected", "message": "big"})),
        json!({"kind": "invalid", "message": "big"})
    );
    assert_eq!(
        rejected(json!({"kind": "command", "code": "timeout", "message": "x"})),
        json!({"kind": "indeterminate"})
    );
    assert_eq!(rejected(json!({"kind": "notConnected"})), json!({"kind": "ownerUnreachable"}));
    assert_eq!(rejected(json!({"kind": "io"})), json!({"kind": "indeterminate"}));
    let passed = json!({"kind": "invalid", "message": "kept"});
    assert_eq!(rejected(json!({"kind": "rejection", "rejection": passed.clone()})), passed);
}

#[test]
fn limits_clamp_to_the_owner_ranges() {
    assert_eq!(
        op("requestLimits", json!({"tail": 0, "limit": 9000, "searchLimit": 500})),
        json!({"tail": 1, "limit": 500, "searchLimit": 100})
    );
    assert_eq!(op("requestLimits", json!({"limit": 50})), json!({"limit": 50}));
}

#[test]
fn a_search_hit_is_a_message_of_its_snippet() {
    let reply = op(
        "searchHits",
        json!({"hits": [{"conversation": "c1", "title": "Room", "seq": 7, "message_id": "m7",
                         "author": "p_you", "created_at": "bad date", "snippet": "found it"}]}),
    );
    let hit = &reply["hits"][0];
    assert_eq!(hit["conversation"], "c1");
    assert_eq!(hit["message"]["id"], "m7");
    assert_eq!(hit["message"]["seq"], 7);
    assert_eq!(hit["message"]["parts"][0]["text"]["_0"], "found it");
    assert_eq!(hit["message"]["createdAt"], -62135769600.0);
    assert_eq!(hit["highlights"], json!([]));
}

fn step(state: Value, event: Value) -> Value {
    op("sessionStep", json!({"state": state, "event": event}))
}

fn effect_kinds(reply: &Value) -> Vec<String> {
    reply["effects"]
        .as_array()
        .expect("effects")
        .iter()
        .map(|e| e["kind"].as_str().unwrap_or_default().to_string())
        .collect()
}

fn event(rev: u64, kind: &str) -> Value {
    json!({"kind": "event", "event": {"rev": rev, "change": {"kind": kind}}})
}

#[test]
fn the_next_revision_applies_and_appends() {
    let reply = step(json!({"mirrorRev": 4}), event(5, "message"));
    assert_eq!(effect_kinds(&reply), ["applyToMirror", "settle", "appended"]);
    assert_eq!(reply["state"]["mirrorRev"], 5);
    assert_eq!(reply["accepted"], true);
    let updated = step(json!({"mirrorRev": 4}), event(5, "messageUpdated"));
    assert_eq!(effect_kinds(&updated), ["applyToMirror", "settle", "updated"]);
}

#[test]
fn a_stale_event_is_dropped_and_a_gap_asks_for_a_reload() {
    let stale = step(json!({"mirrorRev": 4}), event(4, "message"));
    assert_eq!(effect_kinds(&stale), Vec::<String>::new());
    assert_eq!(stale["accepted"], true);
    let gap = step(json!({"mirrorRev": 4}), event(7, "message"));
    assert_eq!(gap["accepted"], false);
    assert_eq!(gap["state"]["mirrorRev"], 4);
}

#[test]
fn events_buffer_while_loading_and_replay_after_the_snapshot() {
    let mut state = step(json!({}), json!({"kind": "load"}))["state"].clone();
    assert_eq!(state["loading"], true);
    for rev in [3, 4, 5] {
        state = step(state, event(rev, "message"))["state"].clone();
    }
    assert_eq!(state["buffered"].as_array().map(Vec::len), Some(3));
    let loaded = step(state, json!({"kind": "loaded", "rev": 3}));
    assert_eq!(
        effect_kinds(&loaded),
        [
            "adoptSnapshot",
            "applyToMirror",
            "settle",
            "appended",
            "applyToMirror",
            "settle",
            "appended",
            "settle",
            "reset",
            "resend"
        ]
    );
    assert_eq!(loaded["state"]["mirrorRev"], 5);
    assert_eq!(loaded["state"]["loading"], false);
    assert_eq!(loaded["state"]["buffered"], json!([]));
}

#[test]
fn an_older_snapshot_never_moves_the_mirror_back() {
    let reply = step(json!({"mirrorRev": 8, "loading": true}), json!({"kind": "loaded", "rev": 5}));
    assert_eq!(reply["state"]["mirrorRev"], 8);
    assert_eq!(effect_kinds(&reply), ["settle", "reset", "resend"]);
}

#[test]
fn a_failed_load_drops_the_buffer() {
    let reply =
        step(json!({"loading": true, "buffered": [{"rev": 1}]}), json!({"kind": "loadFailed"}));
    assert_eq!(effect_kinds(&reply), ["logFailure"]);
    assert_eq!(reply["state"]["buffered"], json!([]));
}

#[test]
fn typing_is_sorted_and_only_reported_on_change() {
    let on = |state: Value, who: &str, on: bool| {
        step(state, json!({"kind": "setTyping", "participant": who, "on": on}))
    };
    let a = on(json!({}), "p_zed", true);
    let b = on(a["state"].clone(), "p_amy", true);
    assert_eq!(b["effects"][0]["participants"], json!(["p_amy", "p_zed"]));
    let again = on(b["state"].clone(), "p_amy", true);
    assert_eq!(effect_kinds(&again), Vec::<String>::new());
    let off = on(b["state"].clone(), "p_zed", false);
    assert_eq!(off["effects"][0]["participants"], json!(["p_amy"]));
}
