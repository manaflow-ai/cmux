use super::*;

fn at(ms: Option<u64>) -> UnreadTab {
    UnreadTab { created_at_ms: ms }
}

#[test]
fn unread_tabs_sort_oldest_first_then_in_tree_order() {
    let unread = [at(Some(30)), at(None), at(Some(10)), at(None), at(Some(10))];
    assert_eq!(order(&unread), vec![1, 3, 2, 4, 0]);
}

#[test]
fn every_verb_refuses_with_no_unread_tab() {
    for verb in
        [Verb::JumpToUnread, Verb::MarkOldestAndJumpNext, Verb::MarkAllRead, Verb::ReadLatest]
    {
        assert_eq!(plan(verb, &[]).refusal, Some(Refusal::NoUnread), "{verb:?}");
    }
}

#[test]
fn jump_opens_the_latest_and_read_latest_acknowledges_it() {
    let unread = [at(Some(5)), at(Some(9)), at(Some(1))];
    assert_eq!(plan(Verb::JumpToUnread, &unread), Plan { open: Some(1), ..Plan::default() });
    assert_eq!(plan(Verb::ReadLatest, &unread), Plan { acknowledge: vec![1], ..Plan::default() });
}

#[test]
fn mark_oldest_reads_it_and_opens_the_next_when_there_is_one() {
    let unread = [at(Some(5)), at(Some(9)), at(Some(1))];
    assert_eq!(
        plan(Verb::MarkOldestAndJumpNext, &unread),
        Plan { acknowledge: vec![2], open: Some(0), ..Plan::default() }
    );
    assert_eq!(
        plan(Verb::MarkOldestAndJumpNext, &[at(Some(4))]),
        Plan { acknowledge: vec![0], ..Plan::default() }
    );
}

#[test]
fn mark_all_reads_every_unread_tab_oldest_first() {
    let unread = [at(Some(5)), at(Some(9)), at(Some(1))];
    assert_eq!(plan(Verb::MarkAllRead, &unread).acknowledge, vec![2, 0, 1]);
}

#[test]
fn the_last_prompt_is_the_newest_and_the_first_on_a_tie() {
    assert_eq!(last_prompt(&[3, 9, 9, 1]), Ok(1));
    assert_eq!(last_prompt(&[]), Err(Refusal::NoPrompt));
}

#[test]
fn mute_toggles_the_key_and_keeps_the_list_sorted() {
    let muted = vec!["b".to_owned(), "a".to_owned()];
    assert_eq!(toggle_mute(&muted, "c", None), vec!["a", "b", "c"]);
    assert_eq!(toggle_mute(&muted, "a", None), vec!["b"]);
}

#[test]
fn a_legacy_remote_mute_unmutes_with_its_qualified_key() {
    let muted = vec!["legacy".to_owned(), "m:w".to_owned(), "x".to_owned()];
    assert_eq!(toggle_mute(&muted, "m:w", Some("legacy")), vec!["x"]);
    assert_eq!(toggle_mute(&["legacy".to_owned()], "m:w", Some("legacy")), Vec::<String>::new());
}

#[test]
fn banners_toggle_between_off_and_unless_focused() {
    assert_eq!(toggle_banners("never"), "unlessFocused");
    for mode in ["unlessFocused", "always", "whenInactive"] {
        assert_eq!(toggle_banners(mode), "never");
    }
}
