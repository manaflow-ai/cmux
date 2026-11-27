use super::*;

fn chip(id: &str) -> Value {
    json!({"id": id, "kind": "image", "name": "a.png", "mimeType": "image/png", "size": 3, "data": "AAA"})
}

#[test]
fn a_push_then_get_brings_the_draft_back_whole_and_a_drop_removes_it() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    let draft = push(&dir, "chat", "first", vec![chip("a")], None, 1).unwrap();
    let path = chat_path(&dir, "chat");
    let kept = load(&path).unwrap();
    assert_eq!(kept, vec![draft.clone()]);
    assert_eq!(kept[0].attachments[0]["data"], "AAA");
    // The list's row has no contents.
    assert!(draft.row()["attachments"][0].get("data").is_none());
    assert!(remove(&dir, "chat", &draft.id).unwrap());
    assert!(!remove(&dir, "chat", &draft.id).unwrap());
    assert!(!path.exists());
}

#[test]
fn a_stack_holds_at_most_stash_limit_newest_first() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    for at in 0..(STASH_LIMIT as u64 + 2) {
        push(&dir, "chat", &format!("draft {at}"), Vec::new(), None, at).unwrap();
    }
    let texts: Vec<String> =
        load(&chat_path(&dir, "chat")).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts.len(), STASH_LIMIT);
    assert_eq!(texts[0], format!("draft {}", STASH_LIMIT + 1));
}

#[test]
fn an_empty_draft_is_refused_and_chats_are_apart() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    assert!(push(&dir, "chat", "  ", Vec::new(), None, 0).is_err());
    push(&dir, "one", "a", Vec::new(), None, 0).unwrap();
    push(&dir, "two", "b", Vec::new(), None, 0).unwrap();
    assert_eq!(load(&chat_path(&dir, "one")).unwrap()[0].text, "a");
    assert_eq!(load(&chat_path(&dir, "two")).unwrap()[0].text, "b");
}

#[test]
fn at_most_stash_chats_keep_a_stack() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    for n in 0..=STASH_CHATS {
        push(&dir, &format!("chat {n}"), "draft", Vec::new(), None, n as u64).unwrap();
    }
    assert_eq!(fs::read_dir(&dir).unwrap().count(), STASH_CHATS);
    assert!(chat_path(&dir, &format!("chat {STASH_CHATS}")).exists());
}

#[test]
fn a_file_that_does_not_parse_is_never_written_over() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    fs::create_dir_all(&dir).unwrap();
    let path = chat_path(&dir, "chat");
    fs::write(&path, "not json").unwrap();
    assert!(push(&dir, "chat", "draft", Vec::new(), None, 0).is_err());
    assert_eq!(fs::read_to_string(&path).unwrap(), "not json");
}

#[test]
fn a_push_in_place_of_a_draft_lets_no_other_go() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    let mut ids = Vec::new();
    for at in 0..STASH_LIMIT as u64 {
        ids.push(push(&dir, "chat", &format!("draft {at}"), Vec::new(), None, at).unwrap().id);
    }
    let newest = ids.last().unwrap().clone();
    push(&dir, "chat", "typed meanwhile", Vec::new(), Some(&newest), 99).unwrap();
    let texts: Vec<String> =
        load(&chat_path(&dir, "chat")).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts.len(), STASH_LIMIT);
    assert_eq!(texts[0], "typed meanwhile");
    assert!(texts.contains(&"draft 0".to_owned()), "{texts:?}");
    assert!(!texts.contains(&format!("draft {}", STASH_LIMIT - 1)), "{texts:?}");
}

#[test]
fn a_draft_too_large_to_answer_whole_is_refused() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    let size = crate::rpc::MAX_MESSAGE_BYTES - REPLY_SLACK;
    let big = json!({"id": "a", "kind": "image", "name": "a.png", "mimeType": "image/png", "data": "A".repeat(size)});
    assert!(push(&dir, "chat", "large", vec![big], None, 0).is_err());
    assert!(!chat_path(&dir, "chat").exists());
}

#[test]
fn draft_ids_are_unique_across_chats_in_one_millisecond() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    let mut ids = std::collections::HashSet::new();
    for n in 0..200 {
        let chat = format!("chat {}", n % 3);
        let draft = push(&dir, &chat, "same", Vec::new(), None, 7).unwrap();
        assert!(ids.insert(draft.id), "a repeated id");
    }
}

#[test]
fn a_list_row_holds_only_the_start_of_a_long_draft() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    let long = "é".repeat(ROW_TEXT_CHARS * 4);
    let draft = push(&dir, "chat", &long, Vec::new(), None, 1).unwrap();
    assert_eq!(draft.row()["text"].as_str().unwrap().chars().count(), ROW_TEXT_CHARS);
    assert_eq!(load(&chat_path(&dir, "chat")).unwrap()[0].text, long);
}

#[test]
fn a_move_puts_the_whole_stack_on_top_and_removes_the_source() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    push(&dir, "session", "the session's own", Vec::new(), None, 2).unwrap();
    push(&dir, "new", "older", vec![chip("a")], None, 1).unwrap();
    push(&dir, "new", "newer", Vec::new(), None, 3).unwrap();
    assert_eq!(move_stack(&dir, "new", "session").unwrap().count, 2);
    let kept = load(&chat_path(&dir, "session")).unwrap();
    let texts: Vec<&str> = kept.iter().map(|d| d.text.as_str()).collect();
    assert_eq!(texts, ["newer", "older", "the session's own"]);
    assert_eq!(kept[1].attachments[0]["data"], "AAA");
    assert!(!chat_path(&dir, "new").exists());
    // Nothing left to move: tried again, it changes nothing.
    assert_eq!(move_stack(&dir, "new", "session").unwrap().count, 0);
    assert_eq!(load(&chat_path(&dir, "session")).unwrap(), kept);
}

#[test]
fn a_move_tried_again_after_a_failed_removal_adds_no_draft_twice() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    for at in 0..STASH_LIMIT as u64 {
        push(&dir, "new", &format!("draft {at}"), Vec::new(), None, at).unwrap();
    }
    // The move wrote the session's stack but its source stayed (a removal that failed).
    let source = fs::read(chat_path(&dir, "new")).unwrap();
    let first = move_stack(&dir, "new", "session").unwrap();
    fs::write(chat_path(&dir, "new"), source).unwrap();
    // Tried again it adds none, and still names every draft it took.
    let again = move_stack(&dir, "new", "session").unwrap();
    assert_eq!((first.count, again.count), (STASH_LIMIT, 0));
    assert_eq!(again.ids, first.ids);
    let texts: Vec<String> =
        load(&chat_path(&dir, "session")).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts, ["draft 4", "draft 3", "draft 2", "draft 1", "draft 0"]);
}

#[test]
fn a_move_whose_source_cannot_be_removed_changes_neither_stack() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    push(&dir, "new", "moving", Vec::new(), None, 1).unwrap();
    push(&dir, "session", "own", Vec::new(), None, 2).unwrap();
    let session = fs::read(chat_path(&dir, "session")).unwrap();
    let refused = move_stack_with(&dir, "new", "session", |_| Err(io::Error::other("refused")));
    assert!(refused.is_err());
    // The session's stack is as it was and the draft is still the new chat's, only there.
    assert_eq!(fs::read(chat_path(&dir, "session")).unwrap(), session);
    assert_eq!(load(&chat_path(&dir, "new")).unwrap()[0].text, "moving");
    // Into a chat with no stack, the put-back leaves none.
    assert!(move_stack_with(&dir, "new", "empty", |_| Err(io::Error::other("refused"))).is_err());
    assert!(!chat_path(&dir, "empty").exists());
    // Tried again with the removal working, it moves once.
    assert_eq!(move_stack(&dir, "new", "session").unwrap().count, 1);
    let texts: Vec<String> =
        load(&chat_path(&dir, "session")).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts, ["moving", "own"]);
}

#[test]
fn a_move_whose_put_back_fails_too_keeps_every_draft_of_the_full_stack() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    for n in 0..STASH_LIMIT as u64 {
        push(&dir, "session", &format!("own {n}"), Vec::new(), None, n).unwrap();
    }
    push(&dir, "new", "moving", Vec::new(), None, 9).unwrap();
    // The source stays, and the put-back cannot write: the stash folder is made read-only (a
    // root run writes anyway, and then the put-back works; either way no draft may be gone).
    let session = chat_path(&dir, "session");
    let refused = move_stack_with(&dir, "new", "session", |_| {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).unwrap();
        }
        Err(io::Error::other("refused"))
    });
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
    }
    assert!(refused.is_err());
    // Whatever the session's file holds now, none of its own drafts is gone.
    let texts: Vec<String> = load(&session).unwrap().into_iter().map(|d| d.text).collect();
    for n in 0..STASH_LIMIT {
        assert!(texts.contains(&format!("own {n}")), "own {n} is gone: {texts:?}");
    }
    // Tried again it finishes once: the moved draft on top, the oldest let go.
    move_stack(&dir, "new", "session").unwrap();
    let texts: Vec<String> = load(&session).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts, ["moving", "own 4", "own 3", "own 2", "own 1"]);
}

#[test]
fn a_move_at_the_chat_limit_loses_no_draft_of_the_new_chat() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    push(&dir, "new", "first", Vec::new(), None, 1).unwrap();
    push(&dir, "new", "second", Vec::new(), None, 2).unwrap();
    for at in 0..STASH_CHATS as u64 - 1 {
        push(&dir, &format!("other {at}"), "kept", Vec::new(), None, 10 + at).unwrap();
    }
    // The session's stack is one chat more: the trim may let an old chat go, never the move's.
    move_stack(&dir, "new", "session").unwrap();
    let texts: Vec<String> =
        load(&chat_path(&dir, "session")).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts, ["second", "first"]);
}

#[test]
fn a_list_row_holds_no_nested_media() {
    let draft = Draft {
        id: "d".into(),
        text: "t".into(),
        attachments: vec![
            json!({"id": "v", "kind": "video", "name": "a.mov", "frames": [{"data": "AAA"}], "poster": {"data": "BBB"}}),
        ],
        at: 1,
    };
    let row = draft.row();
    let chip = &row["attachments"][0];
    assert_eq!(chip["name"], "a.mov");
    assert!(chip.get("frames").is_none() && chip.get("poster").is_none());
}

#[test]
fn a_move_onto_a_full_stack_keeps_the_moved_drafts_even_when_their_times_tie() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    for n in 0..STASH_LIMIT {
        push(&dir, "session", &format!("own {n}"), Vec::new(), None, 7).unwrap();
    }
    push(&dir, "new", "moved", Vec::new(), None, 7).unwrap();
    assert_eq!(move_stack(&dir, "new", "session").unwrap().count, 1);
    let texts: Vec<String> =
        load(&chat_path(&dir, "session")).unwrap().into_iter().map(|d| d.text).collect();
    assert_eq!(texts, ["moved", "own 4", "own 3", "own 2", "own 1"]);
}

#[test]
fn a_move_keeps_a_draft_equal_to_one_the_session_holds_but_its_own() {
    let home = tempfile::tempdir().unwrap();
    let dir = home.path().join(DIR);
    push(&dir, "session", "same", Vec::new(), None, 5).unwrap();
    push(&dir, "new", "same", Vec::new(), None, 5).unwrap();
    assert_eq!(move_stack(&dir, "new", "session").unwrap().count, 1);
    let kept = load(&chat_path(&dir, "session")).unwrap();
    assert_eq!(kept.len(), 2);
    assert_ne!(kept[0].id, kept[1].id);
    assert!(!chat_path(&dir, "new").exists());
}
