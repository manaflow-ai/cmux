//! A pack's own text (an unknown key, its value, a section name) reaches a
//! terminal through `PackDiagnostic::display`, so no control character from a
//! pack may survive it: an escape sequence printed by `cmux pack check` would
//! drive the reader's terminal (and, where allowed, its clipboard).

use cmux_theme_pack::PackDiagnostic;

#[test]
fn display_escapes_every_control_character_a_pack_supplies() {
    let hostile = "\u{1b}]52;c;cHduZWQ=\u{7}\u{1b}[2J\u{9b}31m\r\n\u{0}\u{7f}";
    let diagnostic = PackDiagnostic {
        section: format!("look{hostile}"),
        key: Some(format!("appearance.{hostile}")),
        message: format!("unknown key{hostile}"),
        value: Some(format!("\"{hostile}\"")),
    };
    for text in
        [diagnostic.display(), PackDiagnostic { section: String::new(), ..diagnostic }.display()]
    {
        assert!(!text.chars().any(char::is_control), "control character left in {text:?}");
        assert!(text.contains("\\u{1b}]52;c;cHduZWQ="), "escaped text stays readable: {text:?}");
        assert!(text.contains("\\r\\n"), "{text:?}");
    }
}

#[test]
fn display_leaves_plain_text_alone() {
    let diagnostic = PackDiagnostic {
        section: "look".into(),
        key: Some("appearance.accent".into()),
        message: "expected one of blue, pink".into(),
        value: Some("\"pinkish\"".into()),
    };
    assert_eq!(
        diagnostic.display(),
        "look: appearance.accent = \"pinkish\": expected one of blue, pink"
    );
}
