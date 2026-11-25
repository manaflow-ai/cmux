use super::*;

/// Review of e840a32 (root B): read-back code never uses the lossy AX
/// readers, which take a failed read for "empty", "false" or "none".
#[test]
fn read_back_code_uses_only_strict_reads() {
    let source = include_str!("readback.rs");
    let code = &source[..source.find("#[cfg(test)]").expect("tests at the end")];
    for lossy in [
        ".elements(",
        ".element(",
        ".string(",
        ".bool(",
        ".number(",
        ".value_text()",
        ".selected_range()",
        ".frame()",
        "unwrap_or_default",
    ] {
        assert!(!code.contains(lossy), "read-back code calls the lossy {lossy}");
    }
}

/// Root B: one failed read makes the whole baseline unknown.
#[test]
fn a_failed_read_makes_the_baseline_unknown() {
    let err = super::super::sys::AX_CANNOT_COMPLETE;
    assert_eq!(all_known(vec![Ok(1), Ok(2)]), Some(vec![1, 2]));
    assert_eq!(all_known(vec![Ok(1), Err(err)]), None);
    assert_eq!(all_known(Vec::<Result<u8, AXError>>::new()), Some(vec![]));
}

/// Root A: in an Any, a sub-check whose wanted state already held
/// (states no change) never makes the whole hold, even when it holds.
#[test]
fn an_unchanged_sub_check_never_makes_any_hold() {
    assert_eq!(any_holds(&[(false, Some(true))]), None, "already held");
    assert_eq!(any_holds(&[(false, Some(true)), (true, Some(true))]), Some(true));
    assert_eq!(any_holds(&[(true, None), (true, Some(false))]), None);
    assert_eq!(any_holds(&[]), None);
}

#[test]
fn typed_text_shows_only_when_more_of_it_is_there() {
    assert!(typed_shows("", "Zed", "Zed"));
    assert!(typed_shows("Zed", "ZedZed", "Zed"));
    assert!(!typed_shows("Zed", "Zed", "Zed"));
    assert!(!typed_shows("abc", "abd", "x"));
    assert!(!typed_shows("", "", ""));
}

#[test]
fn the_typed_value_inserts_at_the_caret() {
    let at = |location, length| Some(CFRange { location, length });
    assert_eq!(typed_value("ab", "Z", at(1, 0)), "aZb");
    assert_eq!(typed_value("aXXb", "Z", at(1, 2)), "aZb");
    assert_eq!(typed_value("ab", "Z", None), "abZ");
}

/// Review 9 (7): a scroll down that moved the view up, or not at all,
/// is not the scroll asked for.
#[test]
fn a_scroll_confirms_only_moving_the_way_asked() {
    assert!(moved_toward(0.2, 0.3, 1.0));
    assert!(!moved_toward(0.3, 0.2, 1.0));
    assert!(!moved_toward(0.3, 0.3, 1.0));
    assert!(moved_toward(0.3, 0.2, -1.0));
    assert!(!moved_toward(0.0, 0.0, -1.0));
}

/// Review of e75f474 (8): typing shows at the caret, with the value
/// grown by the text; the same text elsewhere does not count.
#[test]
fn typed_text_shows_at_the_caret() {
    let at = |location, length| CFRange { location, length };
    assert!(typed_at("ab", "aZedb", "Zed", at(1, 0)));
    assert!(typed_at("aXXb", "aZb", "Z", at(1, 2)), "replacing a selection");
    assert!(typed_at("Zed", "ZedZed", "Zed", at(3, 0)), "typed at the end");
    assert!(!typed_at("ab!", "ab!Zed", "Zed", at(0, 0)), "landed elsewhere");
    assert!(!typed_at("ab", "ab", "Z", at(1, 0)), "nothing typed");
    assert!(!typed_at("ab", "aZZb", "Z", at(1, 0)), "typed twice");
    assert!(typed_at("é", "éZ", "Z", at(1, 0)), "UTF-16 offsets");
}

/// Live, Safari and Chrome: an empty ProseMirror or Lexical editor reads
/// "\n" (its empty paragraph) before typing and "Zq9 x" (or "Zq9 x\n\n")
/// after: the text landed; the break was the placeholder's.
#[test]
fn typed_text_shows_in_a_rich_editor_whose_empty_paragraph_was_a_break() {
    let at = |location, length| CFRange { location, length };
    assert!(typed_at("\n", "Zq9 x", "Zq9 x", at(0, 0)), "ProseMirror");
    assert!(typed_at("\n", "Zq9 x", "Zq9 x", at(1, 0)), "caret after the break");
    assert!(typed_at("\n", "Zq9 x\n\n", "Zq9 x", at(0, 0)), "Lexical");
    assert!(typed_at("ab\n", "abZ\n", "Z", at(2, 0)));
    assert!(!typed_at("\n", "Zq9 xZq9 x", "Zq9 x", at(0, 0)), "typed twice");
    assert!(!typed_at("\n", "\n", "Zq9 x", at(0, 0)), "nothing typed");
    assert!(!typed_at("ab\n", "Zab\n", "Z", at(2, 0)), "landed elsewhere");
    assert!(!typed_at("\n", "a\nb", "a\nb\n", at(0, 0)), "text with its own breaks stays exact");
}

/// A calculator digit: exactly one text changed, a display that took
/// the digit; two changed texts, none, or another digit say nothing.
#[test]
fn one_text_changed_ending_with_the_digit() {
    let p = |b: &str, a: &str| (Some(b.to_string()), Some(a.to_string()));
    assert!(one_changed_ending(&[p("0", "8"), p("C", "C")], '8'));
    assert!(one_changed_ending(&[p("1,23", "1,238")], '8'));
    assert!(!one_changed_ending(&[p("0", "8"), p("a", "b")], '8'), "two changed");
    assert!(!one_changed_ending(&[p("8", "8")], '8'), "none changed");
    assert!(!one_changed_ending(&[p("0", "9")], '8'), "another digit");
}

/// Review of 13dca61 (8), e840a32: a display, the old value a strict
/// prefix or cleared; not a lone label that ends with the digit.
#[test]
fn the_digit_check_reads_a_display() {
    let p = |b: &str, a: &str| (Some(b.to_string()), Some(a.to_string()));
    assert!(one_changed_ending(&[p("12", "128")], '8'));
    assert!(one_changed_ending(&[p("0", "8")], '8'));
    assert!(one_changed_ending(&[p("", "8")], '8'), "a blank display");
    assert!(!one_changed_ending(&[p("Items: 3", "Items: 8")], '8'), "a label");
    assert!(!one_changed_ending(&[p("5", "8")], '8'), "not appended");
    assert!(!one_changed_ending(&[p("12", "8")], '8'), "replaced, not appended");
}

/// Batch 2: ⌘S confirms when the document file was written after the
/// press; an unchanged or unreadable time says nothing.
#[test]
fn a_save_shows_as_a_newer_file() {
    assert!(saved(Some(100.0), Some(101.5)));
    assert!(!saved(Some(100.0), Some(100.0)));
    assert!(!saved(None, Some(100.0)), "no file before");
    assert!(!saved(Some(100.0), None));
}

/// Batch 2: Finder ⌘⇧N and Notes New Note: one new row selected, by
/// name (review of e840a32: not by element identity).
#[test]
fn a_new_row_is_one_selected_row_not_seen_before() {
    let names = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert!(new_row_selected(&names(&["a", "b"]), &names(&["untitled folder"])));
    assert!(!new_row_selected(&names(&["a", "b"]), &names(&["a"])), "an old row");
    assert!(!new_row_selected(&names(&["a"]), &names(&["x", "y"])), "two selected");
    assert!(!new_row_selected(&names(&["a"]), &[]), "none selected");
}

/// Batch 2: type-to-select picked the row whose name starts with the
/// typed text; a row that does not is a wrong pick, said as such.
#[test]
fn type_select_reads_the_picked_row() {
    let one = |s: &str| vec![s.to_string()];
    assert_eq!(type_selected(&one("file-07.txt"), "file-07"), Some(true));
    assert_eq!(type_selected(&one("File-07.txt"), "file-07"), Some(true), "any case");
    assert_eq!(type_selected(&one("file-08.txt"), "file-07"), Some(false));
    assert_eq!(type_selected(&[], "file"), None);
    assert_eq!(type_selected(&[one("a"), one("b")].concat(), "a"), None, "two selected");
}

#[test]
fn rows_grew_when_any_list_has_more_rows() {
    assert!(rows_grew(&[(3, 3), (5, 6)]));
    assert!(!rows_grew(&[(3, 3), (6, 5)]));
    assert!(!rows_grew(&[]));
}

/// Review of 13dca61 (1): a failed read after the press is not a change.
#[test]
fn a_failed_menu_item_read_is_never_a_change() {
    let ok = |v: Option<&str>| -> Read { Ok(v.map(String::from)) };
    let err: Read = Err(super::super::sys::AX_CANNOT_COMPLETE);
    assert!(item_changed(&ok(Some("Hide Ruler")), &ok(Some("Show Ruler"))));
    assert!(item_changed(&ok(None), &ok(Some("\u{2713}"))), "a check mark appeared");
    assert!(!item_changed(&ok(Some("Hide Ruler")), &ok(Some("Hide Ruler"))));
    assert!(!item_changed(&ok(Some("Hide Ruler")), &err), "after-read failed");
    assert!(!item_changed(&err, &ok(Some("Show Ruler"))), "before-read failed");
}

/// Review of 13dca61 (2): a sheet is gone only when its element is
/// invalid or it left its window; a timeout says nothing.
#[test]
fn a_sheet_is_gone_only_when_invalid_or_detached() {
    let invalid: Read = Err(super::super::sys::AX_INVALID_ELEMENT);
    let timeout: Read = Err(super::super::sys::AX_CANNOT_COMPLETE);
    let alive: Read = Ok(Some("AXSheet".into()));
    assert_eq!(sheet_gone(&invalid, None), Some(true));
    assert_eq!(sheet_gone(&timeout, None), None, "a timeout is not gone");
    assert_eq!(sheet_gone(&timeout, Some(true)), None);
    assert_eq!(sheet_gone(&alive, Some(true)), None, "still a child of its window");
    assert_eq!(sheet_gone(&alive, Some(false)), Some(true), "left its window");
    assert_eq!(sheet_gone(&alive, None), None, "its window unreadable");
}

#[test]
fn checks_are_taken_once_and_bounded() {
    let mut checks = Checks::default();
    let scroll = || Check::Scroll { bars: vec![], wanted: None };
    let first = checks.add(scroll());
    assert_eq!(first.what, "scroll");
    for _ in 0..KEPT {
        checks.add(scroll());
    }
    assert!(checks.take(first.token).is_none(), "the oldest is dropped");
    let last = checks.add(scroll());
    assert!(checks.take(last.token).is_some());
    assert!(checks.take(last.token).is_none());
}

/// Review of 02ca109 (1): a stepper asked for 10 that stopped at 7 has
/// not reached what was wanted (one step of tolerance); a direction is
/// reached only by moving that way; a toggle only by a different value.
#[test]
fn the_wanted_value_comes_from_the_request() {
    let to = |v: &str| Wanted::from_request(v);
    assert!(!wanted_reached("5", "7", &to("10"), Some(1.0)), "stopped short");
    assert!(wanted_reached("5", "9.5", &to("10"), Some(1.0)), "within one step");
    assert!(wanted_reached("5", "6", &Wanted::Direction(1.0), None));
    assert!(!wanted_reached("5", "4", &Wanted::Direction(1.0), None), "the other way");
    assert!(!wanted_reached("5", "5", &Wanted::Direction(-1.0), None));
    assert!(wanted_reached("0", "1", &Wanted::Other, None));
    assert!(!wanted_reached("1", "1", &Wanted::Other, None));
}

/// Notes on macOS 27.0.1: its window walk ran past its bound (708
/// elements, 83 rows in its notes list), so no "New Note" read-back
/// was attached. A list search finds lists by their containers and does
/// not walk into their rows; everything else is walked as before.
#[test]
fn a_list_search_does_not_walk_into_rows() {
    for role in ["AXTable", "AXOutline", "AXList"] {
        assert!(!list_search_enters(Some(role)), "{role}");
    }
    for role in ["AXWindow", "AXSplitGroup", "AXScrollArea", "AXGroup", "AXToolbar"] {
        assert!(list_search_enters(Some(role)), "{role}");
    }
    assert!(list_search_enters(None));
}

#[test]
fn values_match_as_text_or_within_the_tolerance() {
    assert!(value_matches("abc", "abc", Some(0.0)));
    assert!(!value_matches("abc", "abd", Some(1.0)));
    assert!(value_matches("60.4", "60", Some(1.0)));
    assert!(!value_matches("62", "60", Some(1.0)));
    assert!(value_matches("1", "1.0", Some(0.0)));
}

/// Review of e28e981 (2): numbers only when the value is a number; a
/// text value compares exactly (a ZIP code "00501" is not 501).
#[test]
fn a_text_value_compares_exactly() {
    assert!(!value_matches("501", "00501", None), "text: exact");
    assert!(value_matches("00501", "00501", None));
    assert!(value_matches("501", "00501", Some(0.0)), "a number value: 501");
}
