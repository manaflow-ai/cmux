//! An attach leaves out the chat's `timeBreakdown` when the client already holds that copy.
//!
//! The breakdown (`time_breakdown.rs`, up to `MAX_SPANS` spans, one per turn) rides in every
//! attach's `session` detail, so a reopen with nothing new (iOS `AcpmuxHub.swift`'s reopen with
//! `afterSeq`) cost the whole breakdown again on every reattach: ~71 KB on a 2,000-turn chat
//! against ~13 KB on a 20-turn one (the network-conditions harness's warm phase,
//! `tests/mobile_link_conditions.rs`). Every attach reply now names its copy in
//! `timeBreakdownVersion`, a hash of the breakdown's JSON. A client that sends that version back
//! as `timeBreakdownVersion` gets no `timeBreakdown` while the copy is the same; one that sends
//! none, or another, gets the field exactly as before.
//!
//! A reopen usually follows new turns, and each turn adds a span, so the held version rarely
//! matches then (the harness's warm phase reopens after a prompt and still got the whole ~71 KB at
//! 100x). A client that never draws the breakdown (the phone: `AcpmuxHub.swift` reads no
//! `timeBreakdown`) sends `omitTimeBreakdown: true` and gets none at all; the web pane's Session
//! Info sends neither and keeps the field.
//!
//! The attach was the smaller half. An attached chat's `session_changed` carries the same
//! breakdown, 93 of its 96 KB on a 2,000-turn chat, on every record of a running turn: over LTE
//! the phone took two to six of them ahead of a cold open's attach reply, and one per record
//! while a reply streamed (Leo, 2026-11-24: "im also still noticing in intervals lag spikes when
//! just typing on phone"). A client that sends `omitTimeBreakdown: true` in its `initialize`
//! `_meta.acpmux` gets no breakdown on that connection at all: not in its attaches, not in its
//! rows (`server/mod.rs` fan-out). An older daemon ignores the key and sends it as before.

use serde_json::Value;
use sha2::{Digest as _, Sha256};

/// The version of the breakdown in `detail`: the first 16 hex digits of the SHA-256 of its JSON.
/// The hash covers the whole copy, so any change to it (a new turn, a running turn's elapsed
/// time, a daemon that folds it differently) is a new version.
fn version(breakdown: &Value) -> Option<String> {
    let bytes = serde_json::to_vec(breakdown).ok()?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    digest.get(..16).map(str::to_owned)
}

/// `row` without its breakdown, for a connection that asked for none.
pub(crate) fn without(row: &mut Value) {
    if let Some(row) = row.as_object_mut() {
        row.remove("timeBreakdown");
    }
}

/// Names the reply's breakdown copy (null when it has none) and leaves it out when `params`
/// holds that version or asks for none (`omitTimeBreakdown`), or `conn`'s `initialize` did.
pub(super) fn apply(reply: &mut Value, params: &Value, conn: &super::Conn) {
    let omit_all = conn.omit_time_breakdown.load(std::sync::atomic::Ordering::SeqCst);
    apply_with(reply, params, omit_all);
}

fn apply_with(reply: &mut Value, params: &Value, omit_all: bool) {
    let Some(reply) = reply.as_object_mut() else {
        return;
    };
    let detail = reply.get_mut("session").and_then(Value::as_object_mut);
    let version = detail
        .as_ref()
        .and_then(|d| d.get("timeBreakdown"))
        .filter(|b| b.is_object())
        .and_then(version);
    if let (Some(detail), Some(version)) = (detail, version.as_deref()) {
        let omit =
            omit_all || params.get("omitTimeBreakdown").and_then(Value::as_bool) == Some(true);
        if omit || params.get("timeBreakdownVersion").and_then(Value::as_str) == Some(version) {
            detail.remove("timeBreakdown");
        }
    }
    reply.insert("timeBreakdownVersion".into(), version.map_or(Value::Null, Value::String));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn reply() -> Value {
        json!({"session": {"id": "c", "timeBreakdown": {"totalMs": 5, "spans": [{"turnSeq": 1}]}}})
    }

    #[test]
    fn a_client_holding_the_copy_gets_no_breakdown() {
        let mut first = reply();
        apply_with(&mut first, &json!({}), false);
        let version = first["timeBreakdownVersion"].as_str().unwrap().to_owned();
        assert!(first["session"]["timeBreakdown"].is_object(), "sent without a held version");
        let mut again = reply();
        apply_with(&mut again, &json!({"timeBreakdownVersion": version}), false);
        assert!(again["session"].get("timeBreakdown").is_none());
        assert_eq!(again["timeBreakdownVersion"], json!(version));
    }

    #[test]
    fn a_client_that_draws_none_gets_none_even_after_a_change() {
        let mut held = reply();
        apply_with(&mut held, &json!({}), false);
        let mut changed = reply();
        changed["session"]["timeBreakdown"]["totalMs"] = json!(6);
        apply_with(
            &mut changed,
            &json!({"omitTimeBreakdown": true,
                                    "timeBreakdownVersion": held["timeBreakdownVersion"]}),
            false,
        );
        assert!(changed["session"].get("timeBreakdown").is_none());
        assert!(changed["timeBreakdownVersion"].is_string(), "the version is still named");
        let mut asked = reply();
        apply_with(&mut asked, &json!({"omitTimeBreakdown": false}), false);
        assert!(asked["session"]["timeBreakdown"].is_object());
    }

    #[test]
    fn a_changed_or_unknown_copy_is_sent_whole() {
        let mut changed = reply();
        let mut held = reply();
        apply_with(&mut held, &json!({}), false);
        changed["session"]["timeBreakdown"]["totalMs"] = json!(6);
        apply_with(
            &mut changed,
            &json!({"timeBreakdownVersion": held["timeBreakdownVersion"]}),
            false,
        );
        assert!(changed["session"]["timeBreakdown"].is_object());
        assert_ne!(changed["timeBreakdownVersion"], held["timeBreakdownVersion"]);
        let mut other = reply();
        apply_with(&mut other, &json!({"timeBreakdownVersion": "0000000000000000"}), false);
        assert!(other["session"]["timeBreakdown"].is_object());
    }

    #[test]
    fn a_reply_without_a_breakdown_names_a_null_version() {
        let mut bare = json!({"session": {"id": "c"}});
        apply_with(&mut bare, &json!({"timeBreakdownVersion": "x"}), false);
        assert_eq!(bare["timeBreakdownVersion"], Value::Null);
        assert_eq!(bare["session"], json!({"id": "c"}));
    }

    #[test]
    fn a_connection_that_asked_for_none_gets_none_whatever_the_attach_sends() {
        let mut bare = reply();
        apply_with(&mut bare, &json!({}), true);
        assert!(bare["session"].get("timeBreakdown").is_none(), "{bare}");
        assert!(bare["timeBreakdownVersion"].is_string(), "the version is still named");
        let mut row = reply()["session"].clone();
        without(&mut row);
        assert_eq!(row, json!({"id": "c"}));
    }
}
