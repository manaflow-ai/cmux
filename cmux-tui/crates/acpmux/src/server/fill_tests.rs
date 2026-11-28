use super::*;

#[test]
fn reads_the_marker_up_to_the_checkout() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    std::fs::create_dir_all(root.join(".git")).unwrap();
    std::fs::create_dir_all(root.join("a/b")).unwrap();
    assert_eq!(fill_of(&root.join("a/b")), None, "no marker: whole");
    std::fs::write(root.join(".git").join(MARKER), b"").unwrap();
    assert_eq!(fill_of(&root.join("a/b")), Some(0), "a marker with no figure");
    std::fs::write(root.join(".git").join(MARKER), b"{\"fill\":42}\n").unwrap();
    assert_eq!(fill_of(&root.join("a/b")), Some(42));
    assert_eq!(fill_of(root), Some(42));
    std::fs::write(root.join(".git").join(MARKER), b"{\"fill\":900}").unwrap();
    assert_eq!(fill_of(root), Some(100));
}

#[test]
fn the_kill_switch_turns_it_off() {
    assert!(!killed(None));
    assert!(!killed(Some("1")));
    for off in ["0", "off", "FALSE", " no "] {
        assert!(killed(Some(off)), "{off}");
    }
}

#[test]
fn a_worktree_file_is_not_a_seed() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(".git"), b"gitdir: /elsewhere\n").unwrap();
    assert_eq!(fill_of(dir.path()), None);
}

#[test]
fn the_note_carries_the_figure_where_clients_read_it() {
    let Message::Notification { params: Some(params), .. } = note("s1", 37) else {
        panic!("a notification with params")
    };
    assert_eq!(params["sessionId"], "s1");
    assert_eq!(params["fill"], 37);
    assert_eq!(params.pointer("/_meta/acpmux/fill"), Some(&json!(37)));
}
