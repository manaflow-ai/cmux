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

use serde_json::Value;
use sha2::{Digest as _, Sha256};

/// The version of the breakdown in `detail`: the first 16 hex digits of the SHA-256 of its JSON.
/// The hash covers the whole copy, so any change to it (a new turn, a running turn's elapsed
/// time, a daemon that folds it differently) is a new version.
fn version(breakdown: &Value) -> Option<String> {
    let bytes = serde_json::to_vec(breakdown).ok()?;
    let digest = format!("{:x}", Sha256::digest(&bytes));
    Some(digest[..16].to_owned())
}

/// Names the reply's breakdown copy and leaves it out when `params` holds that version.
pub(super) fn apply(reply: &mut Value, params: &Value) {
    let Some(detail) = reply.get_mut("session").and_then(Value::as_object_mut) else {
        return;
    };
    let Some(version) = detail.get("timeBreakdown").filter(|b| b.is_object()).and_then(version)
    else {
        return;
    };
    let held = params.get("timeBreakdownVersion").and_then(Value::as_str);
    if held == Some(version.as_str()) {
        detail.remove("timeBreakdown");
    }
    reply["timeBreakdownVersion"] = Value::String(version);
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
        apply(&mut first, &json!({}));
        let version = first["timeBreakdownVersion"].as_str().unwrap().to_owned();
        assert!(first["session"]["timeBreakdown"].is_object(), "sent without a held version");
        let mut again = reply();
        apply(&mut again, &json!({"timeBreakdownVersion": version}));
        assert!(again["session"].get("timeBreakdown").is_none());
        assert_eq!(again["timeBreakdownVersion"], json!(version));
    }

    #[test]
    fn a_changed_or_unknown_copy_is_sent_whole() {
        let mut changed = reply();
        let mut held = reply();
        apply(&mut held, &json!({}));
        changed["session"]["timeBreakdown"]["totalMs"] = json!(6);
        apply(&mut changed, &json!({"timeBreakdownVersion": held["timeBreakdownVersion"]}));
        assert!(changed["session"]["timeBreakdown"].is_object());
        assert_ne!(changed["timeBreakdownVersion"], held["timeBreakdownVersion"]);
        let mut other = reply();
        apply(&mut other, &json!({"timeBreakdownVersion": "0000000000000000"}));
        assert!(other["session"]["timeBreakdown"].is_object());
    }

    #[test]
    fn a_reply_without_a_breakdown_names_no_version() {
        let mut bare = json!({"session": {"id": "c"}});
        apply(&mut bare, &json!({"timeBreakdownVersion": "x"}));
        assert!(bare.get("timeBreakdownVersion").is_none());
    }
}
