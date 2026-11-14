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
    assert!(continue_text("x", "transport").contains("a connection error (x)"));
    assert!(continue_text("simulated internal error", "error").contains("cut off by an error"));
}
