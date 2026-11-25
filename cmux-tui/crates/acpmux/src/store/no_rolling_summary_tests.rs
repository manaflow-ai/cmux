//! The rolling chat summary and next action are gone (https://github.com/manaflow-ai/cmux/issues/51749):
//! a chat saved by an acpmux that still wrote one keeps loading, and acpmux never writes or
//! publishes one again, so no client has a summary to draw.

use super::*;
use serde_json::json;

fn saved_meta_with_summary() -> serde_json::Value {
    json!({
        "schema": META_SCHEMA,
        "id": "chat-a",
        "name": "chat-a",
        "harness": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 2,
        "rollingSummary": {
            "text": "All three review comments are fixed",
            "next": "Merge the PR",
            "source": "model",
            "turn": 4,
            "at": 3
        }
    })
}

#[test]
fn a_chat_saved_with_a_rolling_summary_loads_and_saves_without_it() {
    let meta: SessionMeta = serde_json::from_value(saved_meta_with_summary())
        .unwrap_or_else(|e| panic!("old session.json must still load: {e}"));
    assert_eq!(meta.id, "chat-a");
    let saved = serde_json::to_value(&meta).unwrap();
    assert!(saved.get("rollingSummary").is_none(), "saved again: {saved}");
}

#[test]
fn the_protocol_spec_has_no_rolling_summary() {
    let spec = include_str!("../../spec/acpmux-protocol.json");
    for marker in ["rollingSummary", "RollingSummary"] {
        assert!(!spec.contains(marker), "acpmux-protocol.json still names {marker}");
    }
}
