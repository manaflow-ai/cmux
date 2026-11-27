use super::*;
use serde_json::json;

#[test]
fn direction_controls_and_invisible_characters_are_found_with_their_position() {
    let found = first_hidden("let a = 1;\nlet b = \"\u{202E}x\";\n", Context::Code);
    assert_eq!(found, Some(Hidden { line: 2, column: 10, code_point: "U+202E".into() }));
    for character in ['\u{2066}', '\u{200F}', '\u{200B}', '\u{2062}', '\u{E0041}', '\u{E0100}'] {
        assert!(is_hidden(character, Context::Code), "{character:?}");
    }
}

#[test]
fn ordinary_text_passes() {
    // A family emoji (ZWJ), a heart with its presentation selector,
    // Persian with a ZWNJ, and a script that strips a byte-order mark.
    let text = "const a = '\u{1F468}\u{200D}\u{1F4BB} \u{2764}\u{FE0F} \u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}';\ntext.replace(/^\u{FEFF}/, '');\n";
    assert_eq!(first_hidden(text, Context::Code), None);
    assert!(is_hidden('\u{FEFF}', Context::ManifestString));
}

#[test]
fn a_manifest_string_or_key_with_one_is_refused_by_pointer_without_its_value() {
    let manifest = json!({
        "name": "Clock\u{202E}",
        "presentation": { "sidebarItem": { "title\u{200B}": "x" } },
        "files": ["main.js", "ok"]
    });
    let issues = manifest_issues(&manifest);
    let pointers: Vec<&str> = issues.iter().map(|issue| issue.path.as_str()).collect();
    assert_eq!(pointers, ["/name", "/presentation/sidebarItem"]);
    assert!(issues.iter().all(|issue| issue.code == "text.hidden"));
    assert!(!issues[0].message.contains("Clock"));
}
