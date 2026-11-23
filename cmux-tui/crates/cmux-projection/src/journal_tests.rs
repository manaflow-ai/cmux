use super::*;

fn paths(since: &Since) -> Vec<&str> {
    match since {
        Since::Changes { paths, .. } => paths.iter().map(String::as_str).collect(),
        Since::Overflow { why, .. } => panic!("overflow ({}) where changes were due", why.as_str()),
    }
}

#[test]
fn a_cursor_sees_only_the_changes_after_it_each_path_once() {
    let journal = Journal::default();
    journal.note("a.rs");
    let first = journal.cursor();
    journal.note("b.rs");
    journal.note("a.rs");
    journal.note("b.rs");
    journal.note("c.rs");
    let since = journal.since(Some(first));
    assert_eq!(paths(&since), ["a.rs", "b.rs", "c.rs"]);
    // From the answer's cursor nothing is new until the next change.
    assert_eq!(paths(&journal.since(Some(since.cursor()))), Vec::<&str>::new());
    journal.note("d.rs");
    assert_eq!(paths(&journal.since(Some(since.cursor()))), ["d.rs"]);
}

#[test]
fn a_cursor_round_trips_as_text() {
    let journal = Journal::default();
    journal.note("x");
    let cursor = journal.cursor();
    assert_eq!(Cursor::parse(&cursor.to_string()), Some(cursor));
    assert_eq!(Cursor::parse(&format!("{cursor}\n")), Some(cursor));
    for bad in ["", "c:", "c:zz:1", "c:1", "1:2", "c:1:-1"] {
        assert_eq!(Cursor::parse(bad), None, "{bad:?} parsed");
    }
    journal.note("y");
    assert_eq!(paths(&journal.since_text(&cursor.to_string())), ["y"]);
}

/// The overflow detector: every cursor the journal cannot answer exactly says so, with why.
#[test]
fn a_cursor_it_cannot_answer_is_an_overflow_never_a_short_list() {
    let journal = Journal::new(3);
    let start = journal.cursor();
    for path in ["a", "b", "c"] {
        journal.note(path);
    }
    assert_eq!(paths(&journal.since(Some(start))), ["a", "b", "c"]);
    // A fourth distinct path lets "a" go: the start cursor may have missed it.
    journal.note("d");
    let since = journal.since(Some(start));
    assert_eq!(since, Since::Overflow { why: Overflow::Truncated, cursor: journal.cursor() });
    // A cursor taken after what was let go still lists exactly.
    let after_a = Cursor { seq: 1, ..start };
    assert_eq!(paths(&journal.since(Some(after_a))), ["b", "c", "d"]);
    // A path changed again is not let go by the newer ones: it moved to its latest change.
    journal.note("b");
    journal.note("e");
    assert_eq!(paths(&journal.since(Some(Cursor { seq: 4, ..start }))), ["b", "e"]);

    // Another daemon's cursor, or no cursor.
    let other = Journal::new(3);
    let fresh = journal.since(Some(other.cursor()));
    assert!(matches!(fresh, Since::Overflow { why: Overflow::FreshInstance, .. }));
    assert!(matches!(journal.since(None), Since::Overflow { why: Overflow::FreshInstance, .. }));
    assert!(matches!(
        journal.since_text("not a token"),
        Since::Overflow { why: Overflow::FreshInstance, .. }
    ));
    // A cursor ahead of the journal.
    let ahead = Cursor { seq: journal.cursor().seq + 1, ..journal.cursor() };
    assert!(matches!(journal.since(Some(ahead)), Since::Overflow { why: Overflow::Future, .. }));
}

#[test]
fn its_memory_stays_at_its_capacity_under_a_burst() {
    let journal = Journal::new(100);
    let start = journal.cursor();
    for at in 0..10_000 {
        journal.note(&format!("f{at}"));
    }
    assert_eq!(journal.lock().latest.len(), 100);
    assert_eq!(journal.lock().order.len(), 100);
    assert!(matches!(journal.since(Some(start)), Since::Overflow { why: Overflow::Truncated, .. }));
    let recent = Cursor { seq: 9_950, ..start };
    assert_eq!(paths(&journal.since(Some(recent))).len(), 50);
}

#[test]
fn the_fsmonitor_answer_is_the_token_then_the_paths_or_everything() {
    let journal = Journal::default();
    let start = journal.cursor();
    journal.note("src/a.rs");
    journal.note_tree("moved");
    let since = journal.since(Some(start));
    let mut want = since.cursor().to_string().into_bytes();
    want.extend_from_slice(b"\0src/a.rs\0moved/\0");
    assert_eq!(since.fsmonitor(), want);
    let overflow = journal.since(None);
    let mut want = overflow.cursor().to_string().into_bytes();
    want.extend_from_slice(b"\0/\0");
    assert_eq!(overflow.fsmonitor(), want);
}
