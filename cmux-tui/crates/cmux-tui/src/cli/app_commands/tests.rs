//! Building an app op's arguments from the words after its CLI path.

use serde_json::json;

use super::build_args;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

fn input() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["text"],
        "properties": {
            "text": { "type": "string" },
            "count": { "type": "integer" },
            "loud": { "type": "boolean" },
            "tags": { "type": "array", "items": { "type": "string" } },
            "mode": { "enum": ["a", "b"] },
            "dryRun": { "type": "boolean" }
        }
    })
}

#[test]
fn flags_positionals_and_types_come_from_the_input_schema() {
    let args = build_args(
        &words("hello --count 3 --loud --tags x --tags=y --mode a --no-dry-run"),
        &input(),
        &json!(["text"]),
    )
    .unwrap();
    assert_eq!(
        args,
        json!({ "text": "hello", "count": 3, "loud": true, "tags": ["x", "y"], "mode": "a", "dryRun": false })
    );
    let whole =
        build_args(&words(r#"--args {"text":"hi","count":1}"#), &input(), &json!([])).unwrap();
    assert_eq!(whole, json!({ "text": "hi", "count": 1 }));
    let rest = build_args(&words("t a b"), &input(), &json!(["text", "tags"])).unwrap();
    assert_eq!(rest["tags"], json!(["a", "b"]));
}

#[test]
fn a_wrong_word_names_itself_and_a_missing_required_names_its_flag() {
    let none = json!([]);
    assert!(
        build_args(&words("--text a --nope 1"), &input(), &none).unwrap_err().contains("--nope")
    );
    assert!(
        build_args(&words("--text a --count x"), &input(), &none).unwrap_err().contains("--count")
    );
    assert!(
        build_args(&words("--text a --mode c"), &input(), &none).unwrap_err().contains("--mode")
    );
    assert!(build_args(&words("--text a extra"), &input(), &none).unwrap_err().contains("extra"));
    assert!(build_args(&words("--count 1"), &input(), &none).unwrap_err().contains("--text"));
}

#[test]
fn a_spelled_out_boolean_takes_its_value_and_leaves_the_positional_alone() {
    let args = build_args(&words("--loud false hello"), &input(), &json!(["text"])).unwrap();
    assert_eq!(args, json!({ "loud": false, "text": "hello" }));
    let on = build_args(&words("--loud true hello"), &input(), &json!(["text"])).unwrap();
    assert_eq!(on, json!({ "loud": true, "text": "hello" }));
}
