use super::*;

#[test]
fn a_two_line_answer_reads_as_summary_and_next() {
    let answer = "Summary: The parser now tolerates missing fields.\n\nNext: \"Open the PR.\"";
    assert_eq!(
        parse(answer),
        Some((
            "The parser now tolerates missing fields.".to_owned(),
            Some("Open the PR.".to_owned())
        ))
    );
}

#[test]
fn bold_labels_an_unlabelled_first_line_and_next_none_read_right() {
    assert_eq!(
        parse("**Summary:** Done and pushed.\n**Next:** none"),
        Some(("Done and pushed.".to_owned(), None))
    );
    assert_eq!(parse("All tests pass now."), Some(("All tests pass now.".to_owned(), None)));
    assert_eq!(parse("Next: do it"), None);
    assert_eq!(parse("  \n"), None);
}

#[test]
fn a_long_summary_is_cut_to_one_short_line() {
    let long = format!("Summary: {}\nNext: {}", "word ".repeat(80), "go ".repeat(80));
    let (text, next) = parse(&long).unwrap();
    assert!(text.chars().count() <= TEXT_CHARS, "{text}");
    assert!(next.unwrap().chars().count() <= NEXT_CHARS);
    assert!(!text.contains('\n'));
    assert!(text.ends_with('…'));
    // A summary at the limit stays whole.
    let whole = "a".repeat(TEXT_CHARS);
    assert_eq!(cut(&whole, TEXT_CHARS), whole);
}

#[test]
fn the_request_rolls_the_last_summary_with_only_the_latest_turn() {
    let last = RollingSummary {
        text: "Menu has three dishes.".into(),
        next: Some("Pick a dessert.".into()),
        source: MODEL.into(),
        turn: 1,
        at: 1,
    };
    let text = request(
        Some(&last),
        Some("make it vegetarian"),
        Some("Done: all three are now vegetarian."),
    );
    assert!(text.contains("Summary: Menu has three dishes."));
    assert!(text.contains("Next: Pick a dessert."));
    assert!(text.contains("make it vegetarian"));
    assert!(text.contains("all three are now vegetarian"));
    let huge = "x".repeat(10_000);
    assert!(request(None, Some(&huge), None).len() < PROMPT_CHARS * 4 + SYSTEM.len() + 100);
}
