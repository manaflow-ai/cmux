//! The JSONC editor reads the settings file by checked
//! byte access; these pin its results on edge inputs and check that no
//! prefix of a document makes any entry point panic.

use cmux_config::jsonc::{
    self, JsoncError, array_append, array_remove, array_replace, array_spans, strip,
};
use serde_json::json;

fn path(keys: &[&str]) -> Vec<String> {
    keys.iter().map(|key| (*key).to_string()).collect()
}

#[test]
fn strip_keeps_comment_newlines_and_drops_trailing_commas() {
    let source = "\u{feff}{\n  // note\n  \"a\": \"x/*y*/\", /* b */\n}";
    assert_eq!(strip(source).unwrap(), "{\n  \n  \"a\": \"x/*y*/\" \n}");
    assert_eq!(strip("[1] /").unwrap(), "[1] /");
    assert_eq!(strip("[1] // end").unwrap(), "[1] ");
}

#[test]
fn strip_refuses_unterminated_tokens_at_the_end() {
    assert_eq!(strip("{\"a\": 1 /* open"), Err(JsoncError::UnterminatedComment));
    assert_eq!(strip("{\"a\": 1 /*"), Err(JsoncError::UnterminatedComment));
    assert_eq!(strip("{\"a\": 1 /*/"), Err(JsoncError::UnterminatedComment));
    assert_eq!(strip("\"abc\\"), Err(JsoncError::UnterminatedString));
    assert_eq!(strip("\"abc\\\""), Err(JsoncError::UnterminatedString));
}

#[test]
fn a_scalar_member_ends_at_its_delimiter() {
    assert_eq!(jsonc::parse("{\"a\": true}").unwrap(), json!({"a": true}));
    assert_eq!(
        jsonc::set("{\"a\": 12 // n\n}", &path(&["a"]), &json!(3)).unwrap(),
        "{\"a\": 3 // n\n}"
    );
    assert_eq!(jsonc::remove("{\"a\": 1, \"b\": 2}", &path(&["b"])).unwrap(), "{\"a\": 1 }");
}

#[test]
fn array_edits_keep_comments_and_multibyte_text() {
    let source = "[\n  \"é\", // ü\n  2\n]\n";
    assert_eq!(array_spans(source).unwrap(), vec![(4, 8), (18, 19)]);
    assert_eq!(array_remove(source, 1).unwrap(), "[\n  \"é\" // ü\n]\n");
    assert_eq!(array_remove(source, 0).unwrap(), "[\n  2\n]\n");
    assert_eq!(array_replace(source, 1, &json!("ß")).unwrap(), "[\n  \"é\", // ü\n  \"ß\"\n]\n");
    assert_eq!(array_append("[\n  1 // one\n]", &json!(2)).unwrap(), "[\n  1, // one\n  2\n]");
    assert_eq!(array_append("[\n  1,\n]", &json!(2)).unwrap(), "[\n  1,\n  2\n]");
}

#[test]
fn appending_to_an_empty_array() {
    assert_eq!(array_append("[\n]", &json!(2)).unwrap(), "[\n  2\n]");
    assert_eq!(array_append("[]", &json!(2)).unwrap(), "[\n  2\n]");
    assert_eq!(array_append("  [ // c\n  ]", &json!(2)).unwrap(), "  [ // c\n    2\n  ]");
    assert_eq!(array_append("// only\n", &json!(2)).unwrap(), "// only\n[\n  2\n]\n");
    assert_eq!(array_remove("[]", 0), Err(JsoncError::Malformed { offset: 0 }));
}

#[test]
fn no_prefix_of_a_document_panics() {
    let documents = [
        "\u{feff}{\n  // ü\n  \"a\": { \"b\": [1, \"é\\\"\", /* c */ 2,], },\n  \"z\": null\n}\n",
        "[\n  { \"key\": \"cmd+k\", \"command\": \"é\" }, // one\n  /* two */ 3\n]\n",
    ];
    for document in documents {
        for end in (0..=document.len()).filter(|end| document.is_char_boundary(*end)) {
            let prefix = &document[..end];
            let _ = strip(prefix);
            let _ = jsonc::parse(prefix);
            let _ = jsonc::set(prefix, &path(&["a", "b"]), &json!("ö"));
            let _ = jsonc::remove(prefix, &path(&["a", "b"]));
            let _ = jsonc::remove(prefix, &path(&["z"]));
            let _ = array_spans(prefix);
            let _ = array_append(prefix, &json!({"key": "ä"}));
            for index in 0..3 {
                let _ = array_remove(prefix, index);
                let _ = array_replace(prefix, index, &json!(1));
            }
        }
    }
}
