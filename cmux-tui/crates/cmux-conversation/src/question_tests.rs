//! `question` parts and the `question.answer` op (question.rs).

use serde_json::json;

use super::*;

fn question(multi: bool) -> Question {
    serde_json::from_value(json!({
        "harness": "chief", "session": "sess_mux", "permission": "perm_1", "agent": "Chief",
        "items": [{"id": "q0", "header": "Auth", "prompt": "Which auth method?", "multi_select": multi,
                   "options": [{"id": "oauth", "label": "OAuth", "detail": "Delegated"},
                               {"id": "keys", "label": "API keys", "preview": {"text": "KEY=..."}}]}]
    }))
    .unwrap()
}

#[test]
fn wire_shape_is_a_tagged_part_with_snake_case_fields() {
    let part = Part::Question(question(false));
    let value = serde_json::to_value(&part).unwrap();
    assert_eq!(value["type"], "question");
    assert_eq!(value["state"], json!({"kind": "pending"}));
    assert_eq!(value["items"][0]["allows_other"], true);
    assert_eq!(
        value["items"][0]["options"][1]["preview"],
        json!({"text": "KEY=...", "format": "monospace"})
    );
    assert_eq!(serde_json::from_value::<Part>(value).unwrap(), part);
}
