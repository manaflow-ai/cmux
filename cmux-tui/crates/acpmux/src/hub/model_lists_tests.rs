use super::*;

fn pairs(ids: &[&str]) -> Vec<(String, String)> {
    ids.iter().map(|id| (id.to_string(), id.to_uppercase())).collect()
}

#[test]
fn an_invalidated_list_is_served_stale_until_a_probe_writes_it_again() {
    let lists = ModelLists::default();
    assert_eq!(lists.acp_freshness("acme"), Freshness::Missing);
    assert!(lists.put_acp("acme", pairs(&["a"]), lists.stamp()));
    assert_eq!(lists.acp_freshness("acme"), Freshness::Fresh);
    lists.invalidate(ListTag::Every);
    assert_eq!(lists.acp_freshness("acme"), Freshness::Stale);
    assert_eq!(lists.acp("acme"), Some(pairs(&["a"])), "a stale list is still served");
    assert!(!lists.put_acp("acme", pairs(&["a"]), lists.stamp()), "the same list again");
    assert_eq!(lists.acp_freshness("acme"), Freshness::Fresh);
    // Another harness's profile changing leaves this one fresh.
    lists.invalidate(ListTag::Profile("other".into()));
    assert_eq!(lists.acp_freshness("acme"), Freshness::Fresh);
}

#[test]
fn a_probe_that_read_across_an_invalidation_writes_a_stale_list() {
    let lists = ModelLists::default();
    let before = lists.stamp();
    lists.invalidate(ListTag::Profile("acme".into()));
    lists.put_acp("acme", pairs(&["a"]), before);
    assert_eq!(lists.acp_freshness("acme"), Freshness::Stale);
}

#[test]
fn a_disk_list_is_stale_and_never_replaces_a_reported_one() {
    let lists = ModelLists::default();
    lists.put_acp("reported", pairs(&["new"]), lists.stamp());
    let served = lists.serve_acp_from_disk([
        ("reported".to_owned(), pairs(&["old"])),
        ("cold".to_owned(), pairs(&["disk"])),
    ]);
    assert_eq!(served, vec!["cold".to_owned()]);
    assert_eq!(lists.acp("reported"), Some(pairs(&["new"])));
    assert_eq!(lists.acp_freshness("reported"), Freshness::Fresh);
    assert_eq!(lists.acp_freshness("cold"), Freshness::Stale);
}

#[test]
fn a_changed_binary_turns_only_its_live_list_stale() {
    let lists = ModelLists::default();
    let key = |len| CacheKey { program: "/bin/claude".into(), len, modified_ns: 1 };
    let model = LiveModel {
        id: "m".into(),
        name: "M".into(),
        efforts: vec![],
        default_effort: None,
        fast: None,
        service_tiers: vec![],
        is_default: false,
        upgrade: None,
    };
    lists.put_live("claude", vec![model.clone()], Some(key(1)), lists.stamp());
    lists.put_live("codex", vec![model], None, lists.stamp());
    lists.invalidate(ListTag::Binary(key(1)));
    assert_eq!(lists.live_freshness("claude"), Freshness::Stale);
    assert_eq!(lists.live_freshness("codex"), Freshness::Fresh);
    assert_eq!(lists.live_binary("claude"), Some(Some(key(1))));
}

#[test]
fn each_update_of_a_cli_is_claimed_once() {
    let lists = ModelLists::default();
    let key = |len| CacheKey { program: "/bin/codex".into(), len, modified_ns: 1 };
    assert!(!lists.claim_binary_change("codex", &key(1), Some(key(1))), "unchanged");
    assert!(lists.claim_binary_change("codex", &key(1), Some(key(2))));
    // Its probe failed, so the list still names the old program: no second probe.
    assert!(!lists.claim_binary_change("codex", &key(1), Some(key(2))));
    assert!(lists.claim_binary_change("codex", &key(1), Some(key(3))), "another update");
    assert!(lists.claim_binary_change("codex", &key(1), None), "the program is gone");
}
