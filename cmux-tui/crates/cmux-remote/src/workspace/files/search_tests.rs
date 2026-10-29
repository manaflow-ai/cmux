//! Search lines, matches and globs read searched text by bounds checks and
//! char boundaries, never by a byte index that could split a character.

use super::*;

fn line(text: &str, start: usize) -> Option<(&str, usize, usize)> {
    search_line(text, start).map(|line| (line.content, line.content_end, line.next_start))
}

#[test]
fn search_line_strips_line_endings() {
    let text = "ab\r\ncd\n\ne";
    assert_eq!(line(text, 0), Some(("ab", 2, 4)));
    assert_eq!(line(text, 4), Some(("cd", 6, 7)));
    assert_eq!(line(text, 7), Some(("", 7, 8)));
    assert_eq!(line(text, 8), Some(("e", 9, 9)));
    assert_eq!(line(text, 9), None);
    assert_eq!(line(text, 100), None);
}

#[test]
fn a_carriage_return_without_a_newline_is_kept() {
    assert_eq!(line("ab\r", 0), Some(("ab\r", 3, 3)));
}

#[test]
fn search_line_off_a_char_boundary_is_none() {
    assert_eq!(line("é", 1), None);
}

#[test]
fn matches_walk_every_line_with_context() {
    let mut file = SearchFileContinuation {
        protocol_path: "notes.txt".into(),
        text: "één x\nno\nx é x\n".into(),
        position: SearchFilePosition {
            line_start: 0,
            line_number: 1,
            match_offset: 0,
            previous_line: None,
        },
    };
    let first = file.next_match("x").unwrap();
    assert_eq!((first.line, first.column, first.text.as_str()), (1, 7, "één x"));
    assert!(first.before.is_empty());
    assert_eq!(first.after, vec!["no".to_owned()]);
    let second = file.next_match("x").unwrap();
    assert_eq!((second.line, second.column), (3, 1));
    assert_eq!(second.before, vec!["no".to_owned()]);
    let third = file.next_match("x").unwrap();
    assert_eq!((third.line, third.column), (3, 6));
    assert!(file.next_match("x").is_none());
}

#[test]
fn wildcard_matches_question_marks_and_stars() {
    assert!(wildcard_match("*.rs", "lib.rs"));
    assert!(wildcard_match("?ib.r*", "lib.rs"));
    assert!(wildcard_match("a*b*c", "aXbYc"));
    assert!(wildcard_match("**", ""));
    assert!(!wildcard_match("*.rs", "lib.rsx"));
    assert!(!wildcard_match("?", ""));
    assert!(!wildcard_match("", "a"));
}
