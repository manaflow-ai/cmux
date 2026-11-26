use super::*;

fn parsed(source: &str) -> Value {
    parse(&json!({ "source": source })).unwrap()
}

#[test]
fn comments_and_trailing_commas_are_read() {
    let reply = parsed("// head\n{\n  /* a */ \"a\": 1, // b\n  \"b\": [1, 2,],\n}\n");
    assert_eq!(reply, json!({ "value": { "a": 1, "b": [1, 2] } }));
}

#[test]
fn empty_and_comment_only_texts_are_an_empty_object() {
    assert_eq!(parsed(""), json!({ "value": {} }));
    assert_eq!(parsed("  // nothing\n/* here */\n"), json!({ "value": {} }));
}

#[test]
fn a_bom_is_dropped_and_strings_keep_comment_text() {
    let reply = parsed("\u{feff}{\"url\": \"https://x//y/*z*/\"}");
    assert_eq!(reply, json!({ "value": { "url": "https://x//y/*z*/" } }));
}

#[test]
fn numbers_are_canonical() {
    assert_eq!(parsed("{\"a\": 1.0, \"b\": 0.5}"), json!({ "value": { "a": 1, "b": 0.5 } }));
}

#[test]
fn problems_say_what_and_where() {
    assert_eq!(parsed("{\"a\": 1 /* open"), json!({ "problem": "a /* comment is never closed" }));
    assert_eq!(parsed("{\"a\": \"open"), json!({ "problem": "a string is never closed" }));
    assert_eq!(
        parsed("{\n  \"a\": 1,\n  x\n}"),
        json!({ "problem": "the text is not valid JSON at line 3, column 3" })
    );
}

#[test]
fn a_comment_keeps_the_line_number() {
    let reply = parsed("// settings\n/* two\nlines */\n{ \"a\": , }\n");
    let problem = reply["problem"].as_str().unwrap();
    assert!(problem.contains("line 4"), "{problem}");
    let reply = parsed("{\n  \"appearance\": {\n    \"accent\": blue\n  }\n}\n");
    assert!(reply["problem"].as_str().unwrap().contains("line 3"), "{reply}");
    assert!(parsed("{ \"a\": 1,, }")["problem"].as_str().unwrap().contains("line 1"));
}

#[test]
fn position_counts_lines_and_characters() {
    assert_eq!(position(0, "abc"), "line 1, column 1");
    assert_eq!(position(5, "ab\ncd"), "line 2, column 3");
    assert_eq!(position(3, "é\nx"), "line 2, column 1");
    assert_eq!(position(3, "\"é\""), "line 1, column 3");
}

#[test]
fn position_of_finds_a_nested_key_in_utf16_columns() {
    let source = "{\n  \"a\": {\n    \"b\": 1 },\n  \"é😀\": 2, \"c\": 3\n}";
    let at = |path: Value| position_of(&json!({ "source": source, "path": path })).unwrap();
    assert_eq!(at(json!(["a", "b"])), json!({ "line": 3, "column": 5 }));
    assert_eq!(at(json!(["c"])), json!({ "line": 4, "column": 13 }));
    assert_eq!(at(json!(["a", "x"])), json!({}));
    assert_eq!(at(json!([])), json!({}));
    assert_eq!(position_of(&json!({ "source": "{", "path": ["a"] })).unwrap(), json!({}));
}

#[test]
fn strip_answers_strict_text() {
    let reply = strip(&json!({ "source": "{\"a\": 1, // c\n}" })).unwrap();
    let text = reply["text"].as_str().unwrap();
    assert!(!text.contains(',') && !text.contains("//"), "{text}");
    assert_eq!(serde_json::from_str::<Value>(text).unwrap(), json!({ "a": 1 }));
}

#[test]
fn a_request_without_source_is_invalid() {
    assert!(matches!(parse(&json!({})), Err(OpError::Invalid(_))));
    assert_eq!(super::super::call("nope", &json!({})), Err(OpError::Unknown));
}
