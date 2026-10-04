use cmux_feed_core::{
    Context, Feed, FeedError, ItemState, ListFilter, MAX_ITEMS, Notice, PostOutcome, RETENTION_MS,
};
use proptest::prelude::*;

fn notice(id: &str, key: &str, terminal: Option<&str>, at_ms: u64) -> Notice {
    Notice {
        id: id.into(),
        dedupe_key: key.into(),
        title: format!("title {id}"),
        body: format!("body {id}"),
        level: "info".into(),
        source: "terminal".into(),
        context: Context { terminal: terminal.map(str::to_string), ..Context::default() },
        actor: None,
        at_ms,
        read: false,
        coalesce: true,
    }
}

#[test]
fn post_creates_and_dedupes_by_key() {
    let mut feed = Feed::default();
    let (outcome, changes) = feed.post(notice("a", "k1", None, 1)).unwrap();
    assert!(matches!(outcome, PostOutcome::Created(_)));
    assert_eq!(changes.upserts.len(), 1);
    let (outcome, changes) = feed.post(notice("b", "k1", None, 2)).unwrap();
    assert!(matches!(outcome, PostOutcome::Deduped(ref item) if item.id == "a"));
    assert!(changes.is_empty());
    assert_eq!(feed.items().len(), 1);
}

#[test]
fn coalescing_folds_into_the_newest_unread_open_item_of_the_terminal() {
    let mut feed = Feed::default();
    feed.post(notice("a", "k1", Some("t1"), 1)).unwrap();
    let (outcome, changes) = feed.post(notice("b", "k2", Some("t1"), 2)).unwrap();
    let PostOutcome::Coalesced(item) = outcome else { panic!("expected coalesced") };
    assert_eq!(item.id, "a");
    assert_eq!(item.count, 2);
    assert_eq!(item.title, "title b", "latest text wins");
    assert_eq!(changes.upserts, vec![item]);
    // The coalesced key dedupes too.
    let (outcome, _) = feed.post(notice("c", "k2", Some("t1"), 3)).unwrap();
    assert!(matches!(outcome, PostOutcome::Deduped(ref item) if item.id == "a"));
    // Another terminal gets its own item.
    let (outcome, _) = feed.post(notice("d", "k3", Some("t2"), 4)).unwrap();
    assert!(matches!(outcome, PostOutcome::Created(_)));
}

#[test]
fn coalescing_skips_read_handing_off_and_moved_items() {
    let mut feed = Feed::default();
    feed.post(notice("a", "k1", Some("t1"), 1)).unwrap();
    feed.read(&["a".into()], 2).unwrap();
    let (outcome, _) = feed.post(notice("b", "k2", Some("t1"), 3)).unwrap();
    assert!(matches!(outcome, PostOutcome::Created(ref item) if item.id == "b"));
    feed.handoff_begin("b", 4).unwrap();
    let (outcome, _) = feed.post(notice("c", "k3", Some("t1"), 5)).unwrap();
    assert!(matches!(outcome, PostOutcome::Created(ref item) if item.id == "c"));
    feed.handoff_begin("c", 6).unwrap();
    feed.handoff_done("c", "cloud", 7).unwrap();
    let (outcome, _) = feed.post(notice("d", "k4", Some("t1"), 8)).unwrap();
    assert!(matches!(outcome, PostOutcome::Created(ref item) if item.id == "d"));
    let mut no_coalesce = notice("e", "k5", Some("t1"), 9);
    no_coalesce.coalesce = false;
    let (outcome, _) = feed.post(no_coalesce).unwrap();
    assert!(matches!(outcome, PostOutcome::Created(ref item) if item.id == "e"));
}

#[test]
fn read_refuses_moved_and_handing_off_items_and_is_idempotent() {
    let mut feed = Feed::default();
    for (id, terminal) in [("a", "t1"), ("b", "t2"), ("c", "t3")] {
        feed.post(notice(id, &format!("k-{id}"), Some(terminal), 1)).unwrap();
    }
    feed.handoff_begin("b", 2).unwrap();
    feed.handoff_begin("c", 2).unwrap();
    feed.handoff_done("c", "cloud", 3).unwrap();
    let error = feed.read(&["a".into(), "c".into()], 4).unwrap_err();
    assert_eq!(error.code(), "owner.unreachable");
    assert!(error.retryable());
    assert!(feed.get("a").unwrap().is_unread(), "a refused read is all or nothing");
    let error = feed.read(&["b".into()], 4).unwrap_err();
    assert_eq!(error, FeedError::Moving("b".into()));
    assert!(error.retryable());
    assert_eq!(feed.read(&["zzz".into()], 4).unwrap_err().code(), "not_found");
    let changes = feed.read(&["a".into()], 5).unwrap();
    assert_eq!(changes.upserts.len(), 1);
    assert!(feed.read(&["a".into()], 6).unwrap().is_empty(), "no-op on a read item");
    assert_eq!(feed.get("a").unwrap().read_at_ms, Some(5));
}

#[test]
fn read_terminal_reads_owned_items_and_reports_the_others() {
    let mut feed = Feed::default();
    let mut first = notice("a", "k1", Some("t1"), 1);
    first.coalesce = false;
    feed.post(first).unwrap();
    let mut second = notice("b", "k2", Some("t1"), 2);
    second.coalesce = false;
    feed.post(second).unwrap();
    feed.handoff_begin("b", 3).unwrap();
    feed.handoff_done("b", "cloud", 4).unwrap();
    let (changes, refused) = feed.read_terminal("t1", 5);
    assert_eq!(changes.upserts.iter().map(|item| item.id.as_str()).collect::<Vec<_>>(), ["a"]);
    assert_eq!(refused.len(), 1);
    assert_eq!(refused[0].code(), "owner.unreachable");
}

#[test]
fn handoff_moves_once_and_repeats_are_idempotent() {
    let mut feed = Feed::default();
    feed.post(notice("a", "k1", None, 1)).unwrap();
    let error = feed.handoff_done("a", "cloud", 2).unwrap_err();
    assert_eq!(error.code(), "feed.invalid_state");
    let (item, changes) = feed.handoff_begin("a", 2).unwrap();
    assert_eq!(item.state, ItemState::HandingOff);
    assert_eq!(changes.upserts.len(), 1);
    let (_, changes) = feed.handoff_begin("a", 3).unwrap();
    assert!(changes.is_empty());
    let (item, changes) = feed.handoff_done("a", "cloud", 4).unwrap();
    assert_eq!(item.state, ItemState::Moved);
    assert_eq!(item.home.as_deref(), Some("cloud"));
    assert_eq!(changes.upserts.len(), 1);
    let (_, changes) = feed.handoff_done("a", "cloud", 5).unwrap();
    assert!(changes.is_empty());
    assert_eq!(feed.handoff_done("a", "elsewhere", 5).unwrap_err().code(), "feed.invalid_state");
    assert_eq!(feed.handoff_begin("a", 6).unwrap_err().code(), "feed.invalid_state");
    let filter = ListFilter { state: Some(ItemState::Moved), ..ListFilter::default() };
    assert_eq!(feed.list(&filter).len(), 1);
}

/// The handoff abort (`feed.adopt.cancel` answered `cancelled: true`): a
/// handing-off item is owned here again. Repeating it on an open item is a
/// no-op; a moved item refuses, because the cloud owns it.
#[test]
fn handoff_abort_unfreezes_only_a_handing_off_item() {
    let mut feed = Feed::default();
    feed.post(notice("a", "k1", Some("t1"), 1)).unwrap();
    let (item, changes) = feed.handoff_abort("a", 2).unwrap();
    assert_eq!(item.state, ItemState::Open);
    assert!(changes.is_empty(), "an abort of an open item is a no-op");
    feed.handoff_begin("a", 3).unwrap();
    let (item, changes) = feed.handoff_abort("a", 4).unwrap();
    assert_eq!((item.state, item.home.as_deref()), (ItemState::Open, None));
    assert_eq!(changes.upserts, vec![item]);
    feed.read(&["a".into()], 5).unwrap();
    assert!(!feed.get("a").unwrap().is_unread(), "the reopened item takes ops again");

    feed.post(notice("b", "k2", Some("t2"), 6)).unwrap();
    feed.handoff_begin("b", 7).unwrap();
    feed.handoff_done("b", "cloud", 8).unwrap();
    assert_eq!(feed.handoff_abort("b", 9).unwrap_err().code(), "feed.invalid_state");
    assert_eq!(feed.handoff_abort("nope", 9).unwrap_err().code(), "not_found");
}

#[test]
fn prune_drops_old_read_and_moved_items_and_bounds_the_count() {
    let mut feed = Feed::default();
    feed.post(notice("old-read", "k1", Some("t1"), 1)).unwrap();
    feed.read(&["old-read".into()], 1).unwrap();
    feed.post(notice("old-open", "k2", Some("t2"), 1)).unwrap();
    let changes = feed.prune(1 + RETENTION_MS);
    assert_eq!(changes.removed, ["old-read"]);
    assert!(feed.get("old-open").is_some(), "unread items stay past retention");

    let mut feed = Feed::default();
    feed.post(notice("frozen", "k-frozen", None, 0)).unwrap();
    feed.handoff_begin("frozen", 0).unwrap();
    for index in 0..MAX_ITEMS + 10 {
        let mut next = notice(&format!("i{index}"), &format!("k{index}"), None, 1 + index as u64);
        next.coalesce = false;
        feed.post(next).unwrap();
    }
    assert_eq!(feed.items().len(), MAX_ITEMS);
    assert!(feed.get("frozen").is_some(), "a handing-off item is never pruned");
}

/// The ledger pass posts old entries with their own times. `post_unpruned`
/// never drops an item, even past [`MAX_ITEMS`] or retention, so the pass's
/// copy keeps every item it still matches entries against.
#[test]
fn post_unpruned_never_prunes() {
    let mut feed = Feed::default();
    feed.post(notice("old-read", "k-old", None, 1)).unwrap();
    feed.read(&["old-read".into()], 1).unwrap();
    for index in 0..MAX_ITEMS {
        let mut next = notice(&format!("i{index}"), &format!("k{index}"), None, 2 + index as u64);
        next.coalesce = false;
        let (_, changes) = feed.post_unpruned(next).unwrap();
        assert!(changes.removed.is_empty(), "post_unpruned removed {:?}", changes.removed);
    }
    let late = notice("late", "k-late", None, 1 + RETENTION_MS * 2);
    let (_, changes) = feed.post_unpruned(late).unwrap();
    assert!(changes.removed.is_empty());
    assert_eq!(feed.items().len(), MAX_ITEMS + 2);
    assert!(feed.get("old-read").is_some(), "a read item past retention stays in the copy");
    // The pruning post drops them.
    let (_, changes) = feed.post(notice("later", "k-later", None, 2 + RETENTION_MS * 2)).unwrap();
    assert!(changes.removed.contains(&"old-read".to_string()));
}

#[derive(Clone, Debug)]
enum Op {
    Post { terminal: u8, key: u8 },
    Read { item: u8 },
    ReadTerminal { terminal: u8 },
    Begin { item: u8 },
    Done { item: u8 },
    Abort { item: u8 },
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        (0u8..3, 0u8..40).prop_map(|(terminal, key)| Op::Post { terminal, key }),
        (0u8..40).prop_map(|item| Op::Read { item }),
        (0u8..3).prop_map(|terminal| Op::ReadTerminal { terminal }),
        (0u8..40).prop_map(|item| Op::Begin { item }),
        (0u8..40).prop_map(|item| Op::Done { item }),
        (0u8..40).prop_map(|item| Op::Abort { item }),
    ]
}

proptest! {
    /// Invariants under random ops: dedupe keys stay unique, a moved item
    /// never changes again except by pruning, and at most one unread open
    /// item per terminal is the coalescing target.
    #[test]
    fn invariants_hold_under_random_ops(ops in prop::collection::vec(op(), 1..120)) {
        let mut feed = Feed::default();
        let mut moved: std::collections::HashMap<String, cmux_feed_core::Item> = Default::default();
        let mut next_id = 0u32;
        for (step, op) in ops.into_iter().enumerate() {
            let at = step as u64 + 1;
            let ids: Vec<String> = feed.items().iter().map(|item| item.id.clone()).collect();
            let pick = |index: u8| ids.get(index as usize % ids.len().max(1)).cloned();
            match op {
                Op::Post { terminal, key } => {
                    next_id += 1;
                    let id = format!("i{next_id}");
                    let term = format!("t{terminal}");
                    let _ = feed.post(notice(&id, &format!("k{key}"), Some(&term), at)).unwrap();
                }
                Op::Read { item } => if let Some(id) = pick(item) {
                    let result = feed.read(std::slice::from_ref(&id), at);
                    if moved.contains_key(&id) {
                        prop_assert_eq!(result.unwrap_err().code(), "owner.unreachable");
                    }
                },
                Op::ReadTerminal { terminal } => { let _ = feed.read_terminal(&format!("t{terminal}"), at); }
                Op::Begin { item } => if let Some(id) = pick(item) { let _ = feed.handoff_begin(&id, at); },
                Op::Done { item } => if let Some(id) = pick(item) { let _ = feed.handoff_done(&id, "cloud", at); },
                Op::Abort { item } => if let Some(id) = pick(item) {
                    let result = feed.handoff_abort(&id, at);
                    if moved.contains_key(&id) {
                        prop_assert_eq!(result.unwrap_err().code(), "feed.invalid_state");
                    }
                },
            }
            let mut keys = std::collections::HashSet::new();
            for item in feed.items() {
                prop_assert!(keys.insert(item.dedupe_key.clone()), "duplicate dedupe key");
                for alias in &item.aliases {
                    prop_assert!(keys.insert(alias.clone()), "duplicate alias");
                }
                if item.state == ItemState::Moved {
                    if let Some(before) = moved.get(&item.id) {
                        prop_assert_eq!(before, item, "a moved item changed");
                    }
                    moved.insert(item.id.clone(), item.clone());
                }
            }
            prop_assert!(feed.items().len() <= MAX_ITEMS);
        }
    }
}
