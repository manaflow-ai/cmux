use super::*;

fn wrapped(text: &str) -> String {
    format!("\u{1b}[0m{text}\u{1b}[0m\n")
}

#[test]
fn text_and_colors_come_back_and_line_endings_become_newlines() {
    assert_eq!(
        replay("$ make test\r\n\u{1b}[32mall 12 passed\u{1b}[0m\r\n\n").as_deref(),
        Some(wrapped("$ make test\n\u{1b}[32mall 12 passed\u{1b}[0m").as_str())
    );
    assert_eq!(replay("a\tb").as_deref(), Some(wrapped("a\tb").as_str()));
}

/// A saved title, clipboard write, hyperlink, mode change or cursor move never runs again.
#[test]
fn every_other_sequence_and_control_is_dropped() {
    let saved = "\u{1b}]0;title\u{07}\u{1b}]52;c;cGFzdGU=\u{1b}\\\u{1b}]8;;https://x\u{07}link\
                     \u{1b}]8;;\u{07}\u{1b}[?1049h\u{1b}[2J\u{1b}[1;31mred\u{1b}(B\u{1b}7\u{07}\u{08}\u{9b}x\
                     \u{1b}Pdcs\u{1b}\\\u{1b}_apc\u{1b}[0m";
    assert_eq!(replay(saved).as_deref(), Some(wrapped("link\u{1b}[1;31mredx\u{1b}[0m").as_str()));
    // An unterminated string is dropped to the end; a string cut by ESC hands over to it.
    assert_eq!(replay("ok\u{1b}]0;never ends").as_deref(), Some(wrapped("ok").as_str()));
    assert_eq!(replay("\u{1b}]0;t\u{1b}[31mx").as_deref(), Some(wrapped("\u{1b}[31mx").as_str()));
    // A CSI with a non-SGR parameter byte (private mode) is not color.
    assert_eq!(replay("\u{1b}[?25ma").as_deref(), Some(wrapped("a").as_str()));
}

#[test]
fn nothing_printable_is_none() {
    assert_eq!(replay(""), None);
    assert_eq!(replay("\n\r\n\u{1b}]0;title\u{07}\u{07}"), None);
}

#[test]
fn the_newest_lines_within_the_limits_are_kept() {
    let many: Vec<String> = (0..MAX_LINES + 10).map(|n| format!("line {n}")).collect();
    let text = replay(&many.join("\n")).unwrap();
    let body = text.trim_start_matches("\u{1b}[0m").trim_end_matches("\u{1b}[0m\n");
    assert_eq!(body.lines().count(), MAX_LINES);
    assert!(body.starts_with("line 10\n") && body.ends_with(&format!("line {}", MAX_LINES + 9)));

    // Whole lines go first, oldest first, while more than one is left.
    let long = format!("old\n{}\nnew", "x".repeat(MAX_CHARACTERS));
    let text = replay(&long).unwrap();
    assert_eq!(text, "\u{1b}[0mnew\u{1b}[0m\n");
    // One line over the limit keeps its tail.
    let line = format!("{}end", "x".repeat(MAX_CHARACTERS));
    let text = replay(&line).unwrap();
    let body = text.trim_start_matches("\u{1b}[0m").trim_end_matches("\u{1b}[0m\n");
    assert_eq!(body.chars().count(), MAX_CHARACTERS);
    assert!(body.ends_with("end"));
}
