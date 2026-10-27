//! Transcript text and timestamps come from files other programs write: any
//! length and any UTF-8 must give a value or `None`, never a panic.

use cmux_chat_index::transcript::{MAX_TEXT, capped};
use cmux_chat_index::{parse_rfc3339_ms, title_line, without_client_context};

#[test]
fn timestamps_parse_with_fraction_and_offset() {
    assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
    assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:01.5Z"), Some(1_500));
    assert_eq!(parse_rfc3339_ms("1970-01-01 00:00:01.123456Z"), Some(1_123));
    assert_eq!(parse_rfc3339_ms("1970-01-01T02:00:00+02:00"), Some(0));
    assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00-0130"), Some(5_400_000));
    assert_eq!(parse_rfc3339_ms("  2026-10-01T10:00:00.000Z "), Some(1_790_848_800_000));
}

#[test]
fn malformed_timestamps_are_none() {
    for text in [
        "",
        "2026",
        "2026-10-01T10:00",
        "2026-10-01T10:00:0",
        "2026-10-01X10:00:00Z",
        "2026/10/01T10:00:00Z",
        "2026-10-01T10:00:00.Z",
        "2026-10-01T10:00:00+2:00",
        "2026-10-01T10:00:00+0a:00",
        "2026-13-01T10:00:00Z",
        "é026-10-01T10:00:00Z",
        "2026-10-01T10:00:0é",
        "2026-10-01T10:00:00é",
        "2026-10-01T10:00:00.12é",
    ] {
        assert_eq!(parse_rfc3339_ms(text), None, "{text:?}");
    }
}

#[test]
fn client_context_is_cut_at_its_element() {
    assert_eq!(
        without_client_context("fix it<cmux-workspace-context>x</cmux-workspace-context>"),
        "fix it"
    );
    assert_eq!(without_client_context("é<cmux-a-context>"), "é");
    assert_eq!(without_client_context("<cmux-a-context>"), "");
    // Not a context element: no closing `>`, whitespace in the name, another suffix.
    for text in
        ["a <cmux-", "a <cmux-x-context", "a <cmux- x-context>", "a <cmux-note> b", "<<cmux-é"]
    {
        assert_eq!(without_client_context(text), text);
    }
    // The first real element wins, after one that is not.
    assert_eq!(without_client_context("a<cmux-note>b<cmux-x-context>c"), "a<cmux-note>b");
}

#[test]
fn title_line_skips_context_and_blank_lines() {
    assert_eq!(title_line("\n  \n  hello  \nworld"), Some("hello".to_owned()));
    assert_eq!(title_line("<cmux-x-context>only context"), None);
    let long = "é".repeat(200);
    let title = title_line(&long).unwrap();
    assert_eq!(title.chars().count(), 120);
    assert!(title.ends_with('…'));
}

#[test]
fn capped_cuts_on_a_character_boundary() {
    let short = "ü".repeat(MAX_TEXT);
    assert_eq!(capped(short.clone()), short);
    let long = "ü".repeat(MAX_TEXT + 5);
    let cut = capped(long);
    assert_eq!(cut.chars().count(), MAX_TEXT + 1);
    assert!(cut.ends_with('…'));
}
