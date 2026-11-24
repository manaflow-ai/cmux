use super::*;

#[test]
fn a_key_names_a_sub_session_by_its_last_segments_only() {
    assert!(ends_with_segments("claude-sr2/mac-ci-3", "mac-ci-3"));
    assert!(ends_with_segments("a/claude-sr2/mac-ci-3", "claude-sr2/mac-ci-3"));
    assert!(!ends_with_segments("claude-sr2/mac-ci-3", "ci-3"), "not a segment boundary");
    assert!(!ends_with_segments("mac-ci-3", "mac-ci-3"), "the whole name is the exact match");
    assert!(!ends_with_segments("claude-sr2/mac-ci-3", ""));
    assert!(!ends_with_segments("claude-sr2/mac-ci-3", "/mac-ci-3"));
}

#[test]
fn candidates_put_segment_matches_first_and_list_each_once() {
    let names =
        ["mac-ci-30", "x/mac-ci-3-old", "claude-sr2/mac-ci-3", "other", "claude-sr2/mac-ci-3"];
    assert_eq!(
        candidates(names, "MAC-CI-3"),
        ["claude-sr2/mac-ci-3", "mac-ci-30", "x/mac-ci-3-old"],
    );
    assert!(candidates(names, "").is_empty());
}

#[test]
fn refusals_keep_the_text_clients_read_and_carry_the_candidates() {
    let e = not_found("lane", &["a/lane".into()]);
    assert!(e.message.starts_with("no session matches \"lane\""), "{}", e.message);
    assert!(e.message.ends_with("close matches: a/lane"), "{}", e.message);
    assert_eq!(e.data.unwrap()["candidates"][0], "a/lane");
    let plain = not_found("lane", &[]);
    assert_eq!(plain.message, "no session matches \"lane\"");
    assert!(plain.data.is_none());
    let many: Vec<String> = (0..10).map(|i| format!("p{i}/lane")).collect();
    let e = ambiguous("lane", &many);
    assert!(e.message.starts_with("\"lane\" matches 10 sessions"), "{}", e.message);
    assert!(e.message.ends_with("p7/lane, … and 2 more"), "{}", e.message);
    assert_eq!(e.data.unwrap()["candidates"].as_array().unwrap().len(), CANDIDATES_SHOWN);
}

#[test]
fn opaque_names_get_a_hint_and_task_names_do_not() {
    for (name, why) in [
        ("cloud-item-14", "ends in a counter (-14)"),
        ("gcp-codex-lane-12/cloud-item-11", "ends in a counter (-11)"),
        ("optchat-sub-6b68ac4a-a26", "has an id in it (6b68ac4a)"),
        ("dispatch-019a3f2e", "has an id in it (019a3f2e)"),
    ] {
        assert_eq!(opaque_reason(name).as_deref(), Some(why), "{name}");
        assert!(naming_hint(name).is_some_and(|h| h.contains("2-5 words")), "{name}");
    }
    for name in [
        "session-info-drag-handles",
        "drain-cx-b-cloud-ios",
        "fix-27310-crash",
        "tests",
        "deadbeef-notes",
        "123",
        "facade-cleanup",
    ] {
        assert_eq!(opaque_reason(name), None, "{name}");
        assert_eq!(naming_hint(name), None, "{name}");
    }
}
