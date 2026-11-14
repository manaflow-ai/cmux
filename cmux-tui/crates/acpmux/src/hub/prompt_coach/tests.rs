use super::person_text;
use serde_json::json;

/// Every card record a chat client draws under a turn reaches it: a `transcript` page or
/// stream carries only the mux kinds `paging.rs` lists.
#[test]
fn the_card_records_are_transcript_records() {
    for kind in ["recap", "memory_offer", "memory_resolved", "coach_offer", "coach"] {
        assert!(super::super::paging::TRANSCRIPT_MUX_KINDS.contains(&kind), "{kind}");
    }
}

/// The rewrite starts from the person's first prompt with text: an agent's or a peer's
/// message (it has a provenance) and an empty, attachment-only prompt are skipped.
#[test]
fn only_a_persons_prompt_with_text_counts() {
    assert_eq!(person_text(&json!({"text": "add a toggle"})), Some("add a toggle"));
    let person = json!({"text": "hi", "_meta": {"origin": {"actor": "person"}}});
    assert_eq!(person_text(&person), Some("hi"));
    let agent = json!({"text": "do X", "_meta": {"provenance": {"kind": "agent"}}});
    assert_eq!(person_text(&agent), None);
    assert_eq!(person_text(&json!({"text": "  "})), None);
    assert_eq!(person_text(&json!({"images": []})), None);
}
