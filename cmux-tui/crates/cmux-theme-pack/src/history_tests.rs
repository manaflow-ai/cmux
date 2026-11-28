use super::*;

fn generation(pack: &str, text: &str) -> Generation {
    Generation {
        pack: pack.into(),
        dir: PathBuf::from("/packs").join(pack),
        theme: format!("pack-{pack}"),
        text: text.into(),
        edits: Map::new(),
    }
}

fn applied(step: Option<Step>) -> String {
    match step {
        Some(Step::Apply { text, .. }) => text,
        Some(Step::Restore(before)) => format!("restore {before:?}"),
        None => "none".into(),
    }
}

#[test]
fn undo_and_redo_move_whole_packs() {
    let mut history = History::default();
    history.push(generation("a", "A"), Some("harbor".into()));
    history.push(generation("b", "B"), Some("pack-a".into()));
    assert_eq!(applied(history.undo()), "A");
    assert_eq!(applied(history.undo()), "restore Some(\"harbor\")");
    assert_eq!(applied(history.undo()), "none");
    assert_eq!(applied(history.redo()), "A");
    assert_eq!(applied(history.redo()), "B");
    assert_eq!(applied(history.redo()), "none");
}

#[test]
fn a_new_pack_after_undo_drops_the_redo_tail() {
    let mut history = History::default();
    history.push(generation("a", "A"), None);
    history.push(generation("b", "B"), None);
    history.undo();
    history.push(generation("c", "C"), None);
    assert_eq!(history.generations.len(), 2);
    assert_eq!(applied(history.redo()), "none");
    assert_eq!(applied(history.undo()), "A");
}

#[test]
fn live_edits_replace_the_applied_generation() {
    let mut history = History::default();
    history.push(generation("a", "A1"), None);
    history.replace(generation("a", "A2"), None);
    history.replace(generation("a", "A3"), None);
    assert_eq!(history.generations.len(), 1);
    assert_eq!(applied(history.undo()), "restore None");
    assert_eq!(applied(history.redo()), "A3");
}

#[test]
fn off_is_one_undoable_step() {
    let mut history = History::default();
    history.push(generation("a", "A"), Some("phosphor".into()));
    assert_eq!(applied(history.off()), "restore Some(\"phosphor\")");
    assert_eq!(applied(history.off()), "none");
    assert_eq!(applied(history.undo()), "A");
    assert_eq!(applied(history.redo()), "restore Some(\"phosphor\")");
    // A pack after off keeps the look before the first pack as `before`.
    history.push(generation("b", "B"), None);
    assert_eq!(applied(history.undo()), "restore Some(\"phosphor\")");
    assert_eq!(applied(history.undo()), "A");
}

#[test]
fn history_is_bounded() {
    let mut history = History::default();
    for index in 0..(MAXIMUM_GENERATIONS + 10) {
        history.push(generation("a", &index.to_string()), None);
    }
    assert_eq!(history.generations.len(), MAXIMUM_GENERATIONS);
    assert_eq!(history.cursor, MAXIMUM_GENERATIONS);
}

#[test]
fn a_garbage_history_file_starts_over() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(".history.json");
    std::fs::write(&path, "{not json").unwrap();
    assert_eq!(History::read(&path), History::default());
    std::fs::write(&path, r#"{"generations":[],"cursor":99}"#).unwrap();
    assert_eq!(History::read(&path).cursor, 0);
}
