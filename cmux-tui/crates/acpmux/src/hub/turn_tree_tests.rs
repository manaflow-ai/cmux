use super::*;

const BEFORE: &str = r#"- Page URL: http://127.0.0.1:5173/
- main:
  - heading "Settings" [level=1]
  - textbox "Name" [ref=e3] [focused]
  - text "Draft"
  - button "Save" [ref=e4]
# 2 interactive elements outside the viewport are not shown
"#;

#[test]
fn refs_focus_and_notes_do_not_count_as_a_change() {
    // The same page read again: its refs renumbered and focus moved.
    let again = BEFORE.replace("[ref=e3] [focused]", "[ref=e9]").replace("e4", "e10");
    let change = tree_diff(&tree_lines(BEFORE), &tree_lines(&again));
    assert!(change.is_empty(), "{change:?}");
    assert!(!tree_lines(BEFORE).iter().any(|l| l.contains("outside the viewport")));
    // Other attributes stay: a checkbox that became checked is a change.
    assert_eq!(
        normalize(r#"  - checkbox "A" [ref=e1] [checked] [focused]"#),
        r#"  - checkbox "A" [checked]"#
    );
}

#[test]
fn a_changed_label_reads_as_one_element_out_and_one_in() {
    let after = BEFORE.replace(r#"text "Draft""#, r#"text "Saved""#);
    let change = tree_diff(&tree_lines(BEFORE), &tree_lines(&after));
    assert_eq!((change.added, change.removed), (1, 1));
    assert_eq!(change.lines, vec![r#"+ text "Saved""#.to_owned(), r#"- text "Draft""#.to_owned()]);
    assert_eq!(change.summary(), r#"+1 -1 elements: + text "Saved"; - text "Draft""#);
}

#[test]
fn repeated_rows_count_by_how_many() {
    let one = "- list:\n  - listitem \"Row\"\n";
    let three = "- list:\n  - listitem \"Row\"\n  - listitem \"Row\"\n  - listitem \"Row\"\n";
    let change = tree_diff(&tree_lines(one), &tree_lines(three));
    assert_eq!((change.added, change.removed), (2, 0));
    let back = tree_diff(&tree_lines(three), &tree_lines(one));
    assert_eq!((back.added, back.removed), (0, 2));
}

#[test]
fn a_frame_is_kept_anyway_only_for_a_tree_and_pixel_change() {
    let changed = TreeChange { added: 1, removed: 0, lines: vec![] };
    assert!(keeps_anyway(Some(&changed), true));
    // A change off the picture: the pixels are the same, nothing is kept.
    assert!(!keeps_anyway(Some(&changed), false));
    // A blinking caret: the pixels moved, the tree did not.
    assert!(!keeps_anyway(Some(&TreeChange::default()), true));
    // No tree (the app's window, an old host): the dHash alone decides, as before.
    assert!(!keeps_anyway(None, true));
}

#[test]
fn named_lines_are_bounded() {
    let wide = format!("- text \"{}\"\n", "x".repeat(500));
    let many: String = (0..50).map(|i| format!("- button \"B{i}\"\n")).collect();
    let change = tree_diff(&[], &tree_lines(&format!("{wide}{many}")));
    assert_eq!(change.added, 51);
    assert_eq!(change.lines.len(), SAMPLE);
    assert!(change.lines[0].chars().count() <= LINE_CHARS + 2, "{}", change.lines[0]);
    assert!(change.lines[0].ends_with('…'));
    let huge: String = (0..MAX_LINES + 10).map(|i| format!("- text \"{i}\"\n")).collect();
    assert_eq!(tree_lines(&huge).len(), MAX_LINES);
}

#[test]
fn a_tree_file_is_read_once_and_removed() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("x.capture.png.tree");
    std::fs::write(&path, BEFORE).unwrap();
    let lines = take_tree(&path).unwrap();
    assert_eq!(lines.len(), 6);
    assert!(!path.exists());
    assert!(take_tree(&path).is_none());
    std::fs::write(&path, "# only a note\n").unwrap();
    assert!(take_tree(&path).is_none());
}

/// The duress number: a 20,000-line tree (a long page's whole viewport read at its cap) against
/// itself with one row changed. Printed for the PR; bounded loosely so a slow CI box passes.
#[test]
fn a_cap_sized_tree_compares_in_milliseconds() {
    let page: String =
        (0..MAX_LINES).map(|i| format!("  - row \"Item {i}\" [ref=e{i}]\n")).collect();
    let moved = page.replace("\"Item 777\"", "\"Item 777 (edited)\"");
    let started = std::time::Instant::now();
    let rounds = 10;
    for _ in 0..rounds {
        let change = tree_diff(&tree_lines(&page), &tree_lines(&moved));
        assert_eq!((change.added, change.removed), (1, 1));
    }
    let each = started.elapsed() / rounds;
    eprintln!("turn_tree duress: {MAX_LINES} lines, normalize both + diff: {each:?} per frame");
    assert!(each < std::time::Duration::from_millis(500), "{each:?}");
}
