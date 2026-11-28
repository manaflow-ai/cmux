use super::*;

fn entry(revision: u64, before: &str, undoes: Option<u64>) -> HistoryEntry {
    HistoryEntry {
        revision,
        at: revision * 10,
        origin: "cli".to_string(),
        keys: vec!["editor.tabSize".to_string()],
        before: before.to_string(),
        undoes,
    }
}

#[test]
fn trim_keeps_the_newest_entries() {
    let entries: Vec<_> = (1..=5).map(|revision| entry(revision, "", None)).collect();
    let kept: Vec<u64> = trim(&entries, 3).iter().map(|entry| entry.revision).collect();
    assert_eq!(kept, vec![3, 4, 5]);
    assert_eq!(trim(&entries, 10).len(), 5);
    assert!(trim(&[], 3).is_empty());
}

#[test]
fn parse_skips_a_line_cut_short() {
    let line = serde_json::to_string(&entry(4, "{}", Some(2))).unwrap();
    let text = format!("{line}\n{{\"revision\": 5, \"at\"\n\n{line}\n");
    let parsed = parse(&text);
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0], entry(4, "{}", Some(2)));
    let plain = serde_json::to_string(&entry(1, "", None)).unwrap();
    assert!(!plain.contains("undoes"), "{plain}");
}

/// Undo walks back: the newest change, then the one before, skipping
/// undo entries and the changes they undid.
#[test]
fn undo_pick_walks_back_one_change_at_a_time() {
    let mut entries = vec![entry(1, "a", None), entry(2, "b", None), entry(3, "c", None)];
    assert_eq!(undo_pick(&entries, "d").map(|entry| entry.revision), Some(3));
    entries.push(entry(4, "d", Some(3)));
    assert_eq!(undo_pick(&entries, "c").map(|entry| entry.revision), Some(2));
    entries.push(entry(5, "c", Some(2)));
    assert_eq!(undo_pick(&entries, "b").map(|entry| entry.revision), Some(1));
    entries.push(entry(6, "b", Some(1)));
    assert_eq!(undo_pick(&entries, "a"), None, "nothing left to undo");
}

/// A change after an undo is undone first; then the walk goes on.
#[test]
fn undo_pick_takes_a_new_change_first() {
    let entries =
        vec![entry(1, "a", None), entry(2, "b", None), entry(3, "c", Some(2)), entry(4, "b", None)];
    assert_eq!(undo_pick(&entries, "e").map(|entry| entry.revision), Some(4));
    let mut entries = entries;
    entries.push(entry(5, "e", Some(4)));
    assert_eq!(undo_pick(&entries, "b").map(|entry| entry.revision), Some(1));
}

#[test]
fn undo_pick_passes_over_a_change_that_would_change_nothing() {
    let entries = vec![entry(1, "a", None), entry(2, "same", None)];
    assert_eq!(undo_pick(&entries, "same").map(|entry| entry.revision), Some(1));
    assert_eq!(undo_pick(&[], "x"), None);
}

/// An append after a line cut short starts a line of its own.
#[test]
fn an_append_after_a_line_cut_short_is_kept() {
    let dir = std::env::temp_dir().join(format!("cmux-history-cut-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let mut log = HistoryLog::new(&dir, Path::new("/x/cmux-next.json"));
    std::fs::write(log.path(), "{\"revision\": 5, \"at\"").unwrap();
    log.append(&entry(6, "a", None));
    assert_eq!(log.read(), vec![entry(6, "a", None)]);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Two settings files keep two histories; one path always names the same.
#[test]
fn each_settings_file_has_its_own_history() {
    let a = history_file_name(Path::new("/home/a/cmux-next.json"));
    let b = history_file_name(Path::new("/home/b/cmux-next.json"));
    assert_ne!(a, b);
    assert_eq!(a, history_file_name(Path::new("/home/a/cmux-next.json")));
    assert_ne!(last_text_file_name(Path::new("/home/a/cmux-next.json")), a);
}

#[test]
fn find_names_the_entry_of_a_revision() {
    let entries = vec![entry(1, "a", None), entry(2, "b", None)];
    assert_eq!(find(&entries, 2).map(|entry| entry.before.as_str()), Some("b"));
    assert_eq!(find(&entries, 9), None);
}

#[test]
fn the_summary_leaves_the_file_text_out() {
    let summary = entry(7, "{\"secret\": 1}", Some(6)).summary_json();
    assert_eq!(
        summary,
        json!({"revision": "7", "at": "70", "origin": "cli", "keys": ["editor.tabSize"], "undoes": "6"})
    );
    assert_eq!(entry(7, "", None).summary_json().get("undoes"), None);
}
