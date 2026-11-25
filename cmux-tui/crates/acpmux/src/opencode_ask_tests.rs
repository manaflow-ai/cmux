use super::*;
use serde_json::{Value, json};

fn parsed(text: &str) -> Value {
    serde_json::from_str(text).unwrap()
}

#[test]
fn no_config_becomes_one_that_asks_for_everything() {
    for existing in [None, Some(""), Some("  ")] {
        let config = asking_config(existing).unwrap();
        assert_eq!(parsed(&config), json!({"permission": {"*": "ask"}}), "{existing:?}");
    }
}

#[test]
fn a_config_keeps_every_key_but_its_permission_in_order_and_as_written() {
    let own = r#"{"model":"own/model","permission":{"*":"allow"},"agent":{"build":{"permission":{"edit":"allow","*":"ask"}}}}"#;
    assert_eq!(
        asking_config(Some(own)).unwrap(),
        r#"{"model":"own/model","agent":{"build":{"permission":{"edit":"allow","*":"ask"}}},"permission":{"*":"ask"}}"#
    );
    // A permission given as one string is replaced too.
    let one = asking_config(Some(r#"{"permission":"allow"}"#)).unwrap();
    assert_eq!(parsed(&one), json!({"permission": {"*": "ask"}}));
}

#[test]
fn a_config_that_is_not_a_json_object_is_not_touched() {
    for text in ["not json", "[1]", "\"text\"", "{\"a\": 1, // note\n}"] {
        assert_eq!(asking_config(Some(text)), None, "{text:?}");
    }
}
