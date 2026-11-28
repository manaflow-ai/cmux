use super::*;

fn kept(id: &str) -> Option<Value> {
    (id == "img1").then(|| json!({"type": "image", "mimeType": "image/png", "data": "AQID"}))
}

#[test]
fn a_prompt_is_rebuilt_from_its_record_in_order() {
    let msg = json!({"text": "look\nhere", "inlineParts": [
        {"kind": "text", "text": "look", "pasted": true},
        {"kind": "image", "id": "img1", "mimeType": "image/png"},
        {"kind": "pasted", "name": "Pasted text", "text": "here"},
    ]});
    assert_eq!(
        prompt_blocks(&msg, kept),
        Some(vec![
            json!({"type": "text", "text": "look", "_meta": {"cmux": {"pasted": true}}}),
            json!({"type": "image", "mimeType": "image/png", "data": "AQID"}),
            json!({"type": "text", "text": "here", "_meta": {"cmux": {"pasted": true}}}),
        ])
    );
    // Without its parts: its text, then its images.
    let msg = json!({"text": "hi", "images": [{"id": "img1"}]});
    assert_eq!(prompt_blocks(&msg, kept).map(|b| b.len()), Some(2));
}

/// The log leaves out the tools note (`tool_mentions.rs`); a rebuilt prompt gets it again.
#[test]
fn tool_mention_note_comes_back_on_a_rebuilt_prompt() {
    let msg = json!({"text": "open it with @browser-use"});
    let blocks = prompt_blocks(&msg, kept).unwrap();
    assert_eq!(blocks.len(), 2, "{blocks:?}");
    assert!(crate::prompt_context::is_context(&blocks[1]), "{blocks:?}");
    assert!(blocks[1]["text"].as_str().unwrap().starts_with(crate::tool_mentions::TAG));
}

#[test]
fn a_prompt_that_cannot_be_rebuilt_is_not_resent() {
    for parts in [
        json!([{"kind": "text", "text": "a"}, {"kind": "image", "id": "gone"}]),
        json!([{"kind": "document", "name": "brief.pdf"}]),
        json!([{"kind": "file", "name": "notes.txt", "uri": "attachment://notes.txt"}]),
        json!([]),
    ] {
        let msg = json!({"text": "a", "inlineParts": parts});
        assert_eq!(prompt_blocks(&msg, kept), None, "{parts}");
    }
    assert_eq!(prompt_blocks(&json!({"text": ""}), kept), None);
}

#[test]
fn a_continuation_names_the_error_it_continues_after() {
    assert!(
        super::super::continue_text_at("x", "transport", None, 0)
            .contains("a connection error (x)")
    );
    assert!(
        super::super::continue_text_at("simulated internal error", "error", None, 0)
            .contains("cut off by an error")
    );
    // 2026-11-24T22:41:00Z cut, 23:02:00Z resumed.
    let timed = super::super::continue_text_at(
        "529",
        "capacity",
        Some(1_795_560_060_000),
        1_795_561_320_000,
    );
    assert!(
        timed.starts_with("Your previous turn was cut off by a capacity error upstream (the provider or the gateway was full) (529) at 22:41Z; acpmux paused the chat until now (23:02Z). Check"),
        "{timed}"
    );
}
