use super::*;

fn tabs(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

/// A banner posts per new request and clears with the mark.
#[test]
fn a_banner_posts_per_new_request_and_clears_with_the_mark() {
    let login = tabs(&["tab_1"]);
    assert_eq!(
        changes(None, &login),
        Changes::default(),
        "a mark made before launch posts nothing"
    );
    assert_eq!(changes(Some(&[]), &login), Changes { post: vec![0], withdraw: vec![] });
    assert_eq!(
        changes(Some(&login), &login),
        Changes::default(),
        "the same request never posts twice"
    );
    let again = tabs(&["tab_1-next-request"]);
    assert_eq!(
        changes(Some(&login), &again),
        Changes { post: vec![0], withdraw: vec!["cmux-attention.tab_1".into()] },
        "a new request on the tab posts again and takes the old banner back"
    );
    assert_eq!(
        changes(Some(&again), &[]).withdraw,
        vec!["cmux-attention.tab_1-next-request".to_owned()],
        "a cleared mark takes its banner back"
    );
}

/// A reorder of the same marks changes nothing; posts and withdrawals keep
/// their lists' order.
#[test]
fn a_reorder_changes_nothing_and_order_is_kept() {
    let first = tabs(&["a", "b", "c"]);
    assert_eq!(changes(Some(&first), &tabs(&["c", "a", "b"])), Changes::default());
    assert_eq!(
        changes(Some(&first), &tabs(&["d", "b", "e"])),
        Changes {
            post: vec![0, 2],
            withdraw: vec!["cmux-attention.a".into(), "cmux-attention.c".into()]
        }
    );
}

/// The watch's eligible set posts its requests even when the last list
/// already held them (seen while the tree was unready).
#[test]
fn the_eligible_set_is_not_diffed_away() {
    let unready = tabs(&["a", "b"]);
    let ready = tabs(&["a", "b", "c"]);
    assert_eq!(posts(Some(&unready), &ready, Some(&tabs(&["a", "c"]))), vec![0, 2]);
    assert_eq!(posts(Some(&[]), &ready, Some(&[])), Vec::<usize>::new());
    assert_eq!(
        posts(None, &ready, Some(&tabs(&["b"]))),
        vec![1],
        "eligible wins over the first list"
    );
    assert_eq!(posts(Some(&unready), &ready, None), vec![2], "no set: the diff's posts");
    assert_eq!(posts(None, &ready, None), Vec::<usize>::new());
}

/// The banner names its tab and nothing else.
#[test]
fn the_banner_names_its_tab_and_nothing_else() {
    let id = banner_id("tab_0f3c");
    assert_eq!(id, "cmux-attention.tab_0f3c");
    assert_eq!(tab(&id), Some("tab_0f3c"));
    for other in ["cmux-notification-7", "cmux-attention.", "attention.42.tab_1", ""] {
        assert_eq!(tab(other), None, "{other}");
    }
    let machine = "mac-2:tab_9";
    assert_eq!(
        tab(&banner_id(machine)),
        Some(machine),
        "the banner names the machine-qualified key"
    );
}

/// A tab id past 256 UTF-8 bytes is no banner's.
#[test]
fn an_overlong_tab_is_refused_by_bytes() {
    let at_limit = "x".repeat(MAX_TAB_BYTES);
    assert_eq!(tab(&banner_id(&at_limit)), Some(at_limit.as_str()));
    assert_eq!(tab(&banner_id(&"x".repeat(MAX_TAB_BYTES + 1))), None);
    // 86 three-byte characters: 258 bytes, though only 86 characters.
    assert_eq!(tab(&banner_id(&"\u{65e5}".repeat(86))), None);
    assert!(tab(&banner_id(&"\u{65e5}".repeat(85))).is_some());
}

/// Launch reconciliation withdraws old requests but keeps concurrent new banners.
#[test]
fn launch_reconciliation_withdraws_old_requests_but_keeps_concurrent_new_banners() {
    let old = banner_id("old");
    let fresh = banner_id("fresh");
    assert_eq!(stale(std::slice::from_ref(&old), &[]), vec![old.clone()]);
    assert_eq!(stale(&[old.clone(), fresh.clone(), "other-banner".into()], &[fresh]), vec![old]);
}
