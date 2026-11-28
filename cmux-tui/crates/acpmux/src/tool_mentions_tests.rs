use super::*;

#[test]
fn tool_mention_shared_cases_read_as_the_web_page_reads_them() {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("tool_mention_cases.json")).expect("the cases parse");
    assert!(!cases.is_empty());
    for case in cases {
        let text = case["text"].as_str().expect("a case's text");
        let want: Vec<&str> = case["tools"]
            .as_array()
            .expect("a case's tools")
            .iter()
            .map(|t| t.as_str().expect("a tool"))
            .collect();
        assert_eq!(mentioned(text), want, "{text:?}");
    }
}

#[test]
fn tool_mention_note_names_each_tool_in_menu_order() {
    assert_eq!(note(&[]), None);
    let both = note(&["browser-use", "computer-use"]).unwrap();
    assert!(both.starts_with("<cmux-tools-context>\nThe person did not type this note; do not quote it.\nThe person wrote @computer-use:"), "{both}");
    assert!(both.ends_with("not in a separate or headless browser.\n</cmux-tools-context>"));
    assert!(crate::prompt_context::is_context_text(&both));
}

#[test]
fn tool_mention_note_is_added_once_from_the_persons_words() {
    let mut blocks = vec![json!({"type": "text", "text": "open it with @browser-use"})];
    add_note(&mut blocks);
    assert_eq!(blocks.len(), 2);
    assert!(crate::prompt_context::is_context(&blocks[1]));
    assert!(blocks[1]["text"].as_str().unwrap().contains("@browser-use: do this"));
    // The note's own words name the tool; it is not read as the person's.
    add_note(&mut blocks);
    assert_eq!(blocks.len(), 2);

    // A client's context that already holds it, after its workspace note.
    let combined = format!(
        "<cmux-workspace-context>W</cmux-workspace-context>\n\n{}",
        note(&["browser-use"]).unwrap()
    );
    let mut blocks = vec![
        json!({"type": "text", "text": "open it with @browser-use"}),
        json!({"type": "text", "text": combined, "_meta": {"acpmux": {"context": true}}}),
    ];
    add_note(&mut blocks);
    assert_eq!(blocks.len(), 2);

    let mut blocks = vec![json!({"type": "text", "text": "no tools"})];
    add_note(&mut blocks);
    assert_eq!(blocks.len(), 1);
}

#[test]
fn tool_mention_own_note_goes_from_a_transcript_and_nothing_else() {
    let cu = note(&["computer-use"]).unwrap();
    let both = note(&["computer-use", "browser-use"]).unwrap();
    // At the end, or followed by other text (a reply hint).
    assert_eq!(
        without_own_note(&format!("open Notes with @computer-use\n\n{cu}")),
        "open Notes with @computer-use"
    );
    assert_eq!(
        without_own_note(&format!(
            "use @browser-use and @computer-use\n\n{both}\n\nReply in one line."
        )),
        "use @browser-use and @computer-use\n\nReply in one line."
    );
    // A person's own context-shaped example stays, with the note after it gone.
    let example = "show me @computer-use with\n\n<cmux-foo-context>\nx\n</cmux-foo-context>";
    assert_eq!(without_own_note(example), example);
    assert_eq!(without_own_note(&format!("{example}\n\n{cu}")), example);
    // A note that is not the one the words make, or with no blank line before it, stays.
    let other = format!("open Notes with @browser-use\n\n{cu}");
    assert_eq!(without_own_note(&other), other);
    let no_mention = format!("plain words\n\n{cu}");
    assert_eq!(without_own_note(&no_mention), no_mention);
    let glued = format!("use @computer-use {cu}");
    assert_eq!(without_own_note(&glued), glued);
    assert_eq!(without_own_note("plain words"), "plain words");
}

#[test]
fn tool_mention_scan_stays_linear_on_unclosed_backticks() {
    let text = format!("{} @computer-use", "`a ".repeat(50_000));
    assert_eq!(mentioned(&text), ["computer-use"]);
}
