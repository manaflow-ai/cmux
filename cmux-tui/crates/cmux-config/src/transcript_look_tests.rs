use super::*;
use serde_json::json;

#[test]
fn the_table_parses_and_every_look_is_valid() {
    let spec: Spec = serde_json::from_str(SOURCE).expect("transcript-look.json parses");
    assert_eq!(spec.version, 1);
    assert!(spec.tokens.len() >= 10);
    for token in &spec.tokens {
        assert!(
            token.refusal(&token.default).is_none(),
            "{}'s default is one of its values",
            token.name
        );
        match token.kind {
            TokenKind::Choice => assert!(!token.choices.is_empty() && token.min.is_none()),
            TokenKind::Number => assert!(token.choices.is_empty() && token.min < token.max),
        }
    }
    for look in &spec.looks {
        let tokens = Value::Object(look.tokens.clone());
        assert!(problems(&tokens).is_empty(), "{}: {:?}", look.name, problems(&tokens));
    }
    let names: Vec<_> = spec.looks.iter().map(|look| look.name.as_str()).collect();
    assert_eq!(names, ["cmux", "claude", "codex", "studio"]);
}

#[test]
fn cmux_sets_no_token() {
    assert!(look(DEFAULT_LOOK).is_some_and(|look| look.tokens.is_empty()));
    assert!(resolve(DEFAULT_LOOK, &json!({})).is_empty());
    assert!(resolve("no-such-look", &json!({})).is_empty());
}

#[test]
fn an_override_wins_and_a_bad_one_is_dropped() {
    let values = resolve(
        "codex",
        &json!({"userMessage.radius": 4, "timestamps": "sometimes", "nope": 1, "rowSpacing": 9}),
    );
    assert_eq!(values["userMessage.radius"], json!(4));
    assert_eq!(values["timestamps"], json!("off"));
    assert!(!values.contains_key("nope"));
    assert!(!values.contains_key("rowSpacing"));
}

#[test]
fn the_tokens_row_refuses_unknown_tokens_and_out_of_range_values() {
    assert!(accepts_tokens(&json!({})));
    assert!(accepts_tokens(&json!({"userMessage.style": "plain", "userMessage.fill": 0})));
    assert!(!accepts_tokens(&json!({"userMessage.style": "square"})));
    assert!(!accepts_tokens(&json!({"userMessage.fill": 0.5})));
    assert!(!accepts_tokens(&json!({"userMessage.fill": "0.1"})));
    assert!(!accepts_tokens(&json!({"avatar": "on"})));
    assert!(!accepts_tokens(&json!([])));
}
