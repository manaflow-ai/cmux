//! `window_registry_store`'s rules, mirroring the app's tests of the moved Swift types
//! (`WindowRegistryAnswersTests`, `RestoreClosedWindowsTests`, `WindowCloseNeighborTests`' kept
//! selections, `WorkspaceCloseCountTests`' counts at the store); `schemas/window-registry-store/
//! vectors.json` checks every action against the Swift answers.

use crate::window_registry::{Changes, Registry, Window};
use crate::window_registry_store::{
    Claims, CloseWork, MembershipWork, RestoreClosed, Store, StoreAction,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};

const VECTORS: &str = include_str!("../../../../schemas/window-registry-store/vectors.json");

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

fn set(list: &[&str]) -> BTreeSet<String> {
    list.iter().map(|s| s.to_string()).collect()
}

fn open(registry: &mut Registry, id: &str, workspaces: &[&str]) -> Changes {
    registry.open_window(id, &ids(workspaces), None, None, false)
}

fn reconcile(registry: &mut Registry, live: &[&str], dead: &[&str], fallback: &str) -> Changes {
    registry.reconcile(
        &ids(live),
        &set(dead),
        &BTreeMap::new(),
        &BTreeSet::new(),
        &BTreeSet::new(),
        fallback,
    )
}

const ANSWER_IDS: [&str; 5] = ["a", "b", "c", "d", "z"];

/// What `registry` says for each workspace, computed without the store
/// (`WindowRegistryAnswersTests.answers`).
fn answers(registry: &Registry) -> (HashMap<String, bool>, HashMap<String, String>) {
    let mut kinds = HashMap::new();
    let mut owners = HashMap::new();
    for window in &registry.windows {
        for id in &window.workspace_ids {
            if !owners.contains_key(id) {
                owners.insert(id.clone(), window.id.clone());
                kinds.insert(id.clone(), registry.is_incognito(&window.id));
            }
        }
    }
    for id in &registry.discarding {
        kinds.insert(id.clone(), true);
    }
    (kinds, owners)
}

/// Both answer maps of `store` equal its registry's answers for every id the tests use.
fn expect_answers(store: &Store, step: &str) {
    let (kinds, owners) = answers(&store.value);
    for id in ANSWER_IDS {
        assert_eq!(
            store.incognito_of_workspace(id),
            kinds.get(id).copied(),
            "after {step}: kind of {id}"
        );
        assert_eq!(
            store.owner_of_workspace(id),
            owners.get(id).map(String::as_str),
            "after {step}: owner of {id}"
        );
        assert_eq!(
            store.owner_of_workspace(id),
            store.value.owner(id),
            "after {step}: owner of {id}"
        );
    }
}

#[test]
fn the_answers_follow_each_registry_change() {
    let mut store = Store::new();
    store.apply(|r| open(r, "w1", &["a", "b"]));
    assert_eq!(store.value.owner("a"), Some("w1"));
    expect_answers(&store, "a normal window opened");
    assert_eq!(store.incognito_of_workspace("a"), Some(false));

    store.take_membership_work();
    store.apply(|r| r.mark_incognito("w2"));
    assert!(store.value.is_incognito("w2"));
    expect_answers(&store, "a window marked incognito before its list");
    assert_eq!(
        store.take_membership_work().answer_writes,
        0,
        "a mark with no listed workspace wrote"
    );

    store.apply(|r| open(r, "w2", &["c"]));
    assert_eq!(store.value.owner("c"), Some("w2"));
    expect_answers(&store, "the incognito window listed c");
    assert_eq!(store.incognito_of_workspace("c"), Some(true));
    assert_eq!(store.take_membership_work().answer_writes, 2, "one listed workspace, two answers");

    store.apply(|r| r.activate("w1"));
    expect_answers(&store, "a window came to the front");
    assert_eq!(store.take_membership_work().answer_writes, 0, "the front window wrote an answer");

    store.apply(|r| r.move_into(&ids(&["b"]), "w2", None));
    assert_eq!(
        store.value.owner("b"),
        Some("w1"),
        "a normal workspace moved into the incognito window"
    );
    expect_answers(&store, "a refused move across the kinds");

    store.apply(|r| r.close("w2", true));
    assert!(store.value.discarding.contains("c") && store.value.owner("c").is_none());
    expect_answers(&store, "the incognito window closed");
    assert_eq!(store.incognito_of_workspace("c"), Some(true));
    assert_eq!(store.owner_of_workspace("c"), None);

    store.apply(|r| reconcile(r, &["a", "b"], &["c"], "w1"));
    assert!(!store.value.discarding.contains("c"));
    expect_answers(&store, "the discarded workspace was reported gone");
    assert_eq!(store.incognito_of_workspace("c"), None);

    store.apply(|r| open(r, "w3", &["b"]));
    assert_eq!(store.value.owner("b"), Some("w3"));
    expect_answers(&store, "a workspace moved to a new normal window");

    store.apply(|r| r.close("w3", true));
    assert!(store.value.window("w3").is_some_and(|w| !w.is_open));
    assert_eq!(store.value.owner("b"), Some("w3"));
    expect_answers(&store, "a normal window closed with its list");
    assert_eq!(store.incognito_of_workspace("b"), Some(false));
}

#[test]
fn a_discarded_workspace_with_no_window_is_incognito() {
    let mut store = Store::new();
    store.apply(|r| open(r, "w1", &["a"]));
    store.apply(|r| r.mark_discarding(&ids(&["z"])));
    assert!(store.value.discarding.contains("z"));
    expect_answers(&store, "a workspace was marked discarded");
    assert_eq!(store.incognito_of_workspace("z"), Some(true));
    assert_eq!(store.owner_of_workspace("z"), None);
    store.apply(|r| reconcile(r, &["a"], &[], "w1"));
    assert!(!store.value.discarding.contains("z"));
    expect_answers(&store, "the daemon stopped reporting the discarded workspace");
    assert_eq!(store.incognito_of_workspace("z"), None);
}

#[test]
fn the_first_window_that_lists_a_workspace_answers_for_it() {
    let mut store = Store::new();
    store.apply(|r| {
        *r = Registry::new(vec![
            Window::new("w1", ids(&["d"])),
            Window::new("w2", ids(&["d", "a"])),
        ]);
        r.mark_incognito("w2");
    });
    assert_eq!(store.value.owner("d"), Some("w1"));
    expect_answers(&store, "two windows listed one workspace");
    assert_eq!(store.incognito_of_workspace("d"), Some(false));
    assert_eq!(store.owner_of_workspace("d"), Some("w1"));
    assert_eq!(store.incognito_of_workspace("a"), Some(true));
}

#[test]
fn a_transition_that_changes_nothing_writes_nothing() {
    let mut store = Store::new();
    store.apply(|r| open(r, "w1", &["a"]));
    let before = store.clone();
    store.apply(|r| r.activate("w1"));
    assert_eq!(store, before);
}

fn ended(awaiting: &[&str], registry: &Registry) -> RestoreClosed {
    let mut memory = RestoreClosed::default();
    memory.closed("launch", true);
    memory.closed("saved-front", false);
    memory.awaiting(set(awaiting), 10);
    memory.restore_ended(registry, 5, |_| false);
    memory
}

#[test]
fn only_the_closed_launch_window_outlasts_the_restore_while_its_workspace_is_unreported() {
    let memory = ended(&["first"], &Registry::default());
    assert_eq!(memory.launch_window_id.as_deref(), Some("launch"));
    assert_eq!(memory.windows, set(&["launch"]));
    assert_eq!(memory.awaited, set(&["first"]));
}

#[test]
fn the_late_workspace_goes_to_the_closed_launch_window_and_the_memory_ends() {
    let mut memory = ended(&["first"], &Registry::default());
    let mut registry = Registry::default();
    let fallback = memory.launch_window_id.clone().unwrap_or("new".into());
    reconcile(&mut registry, &["first"], &[], &fallback);
    memory.keep_closed(&mut registry);
    assert_eq!(registry.owner("first"), Some("launch"));
    assert!(registry.window("launch").is_some_and(|w| !w.is_open));
    memory.settle(&registry, 11, |id| id == "first");
    assert_eq!(memory, RestoreClosed::default());
}

#[test]
fn a_workspace_the_store_applied_past_without_listing_is_gone_and_ends_the_memory() {
    let mut memory = ended(&["first"], &Registry::default());
    memory.settle(&Registry::default(), 9, |_| false);
    assert_eq!(
        memory.launch_window_id.as_deref(),
        Some("launch"),
        "not applied past the create yet"
    );
    memory.settle(&Registry::default(), 10, |_| false);
    assert_eq!(memory, RestoreClosed::default());
}

#[test]
fn nothing_awaited_or_the_launch_window_reopened_forgets_at_the_end() {
    assert_eq!(ended(&[], &Registry::default()), RestoreClosed::default());
    let mut memory = RestoreClosed::default();
    memory.closed("launch", true);
    memory.awaiting(set(&["first"]), 10);
    memory.reopened("launch");
    memory.restore_ended(&Registry::default(), 0, |_| false);
    assert_eq!(memory, RestoreClosed::default());
}

#[test]
fn a_kept_selection_needs_no_pick() {
    let members = ids(&["a", "b"]);
    let kept = |current, preferred: &[&str]| {
        Store::repaired_selection_kept(current, &members, &ids(preferred))
    };
    assert_eq!(kept(Some("a"), &[]).as_deref(), Some("a"), "the selection stays");
    assert_eq!(kept(Some("c"), &["a"]).as_deref(), Some("a"), "a preferred member applies");
    assert_eq!(
        kept(Some("a"), &["z", "b"]).as_deref(),
        Some("b"),
        "the first preferred member wins"
    );
    assert_eq!(kept(Some("c"), &[]), None, "a gone selection is the rule's pick");
    assert_eq!(kept(None, &["z"]), None);
}

#[test]
fn settle_reads_a_guest_as_listed_by_its_window() {
    let mut store = Store::new();
    store.apply(|r| {
        open(r, "w1", &["a"]);
        open(r, "w2", &["b"]);
        r.set_guests(&ids(&["a"]), "w2");
    });
    assert_eq!(store.settle_owner("w2", "a").as_deref(), Some("w2"));
    assert_eq!(store.settle_owner("w2", "b").as_deref(), Some("w2"));
    assert_eq!(store.settle_owner("w1", "b").as_deref(), Some("w2"));
    assert_eq!(store.settle_owner("w1", "z"), None);
}

#[test]
fn a_close_reads_the_shown_window_alone() {
    let mut store = Store::new();
    let many: Vec<String> = (0..200).map(|i| format!("s{i}")).collect();
    store.apply(|r| {
        r.open_window("w1", &ids(&["a", "b"]), None, None, false);
        r.open_window("w2", &many, None, None, false);
    });
    store.take_close_work();
    let unlisted = store.unlisted(&ids(&["a", "s1", "x"]), "w1");
    assert_eq!(unlisted, set(&["s1", "x"]));
    let shown = store.repairs(Some("w1"));
    assert_eq!(shown.len(), 1);
    let work = store.take_close_work();
    // a is w1's own; s1 is w2's (w1 read once, 2 ids); x has no owner.
    assert_eq!(
        work,
        CloseWork { repaired_windows: 1, repaired_ids: 2, show_calls: 1, shown_ids: 5 }
    );
    assert_eq!(work.to_string(), "repaired windows 1, repaired ids 2, show calls 1, shown ids 5");
    assert_eq!(store.take_close_work(), CloseWork::default());
}

#[test]
fn an_unregistered_window_answers_from_its_launch_snapshot() {
    let mut store = Store::new();
    store.provisional.insert("w9".into(), ids(&["a", "b"]));
    assert_eq!(store.members("w9"), ids(&["a", "b"]));
    assert_eq!(store.unlisted(&ids(&["a", "c"]), "w9"), set(&["c"]));
    store.clear_provisional();
    assert!(store.members("w9").is_empty());
}

#[test]
fn a_gather_keeps_its_givers_until_they_enter_a_space() {
    let mut store = Store::new();
    store.apply(|r| {
        open(r, "w1", &["a"]);
        open(r, "w2", &["b"]);
    });
    store.hold_own_space("w1");
    store.gather("w1", &ids(&["w2", "gone"]), |s| s.space_entered("w2"));
    assert_eq!(store.gather_sources, set(&["w2"]), "the gather's own entry and a gone giver");
    store.space_entered("w2");
    assert!(store.gather_sources.is_empty());
}

#[test]
fn only_a_launching_store_restores_a_session() {
    let mut store = Store::new();
    let saved = ids(&["w2"]);
    assert!(!store.restores_session("w1", Some("w1"), None));
    store.is_launching = true;
    assert!(store.restores_session("w1", Some("w1"), None));
    assert!(store.restores_session("w2", None, Some(&saved)));
    assert!(!store.restores_session("w3", Some("w1"), Some(&saved)));
}

#[test]
fn membership_work_counts_order_builds() {
    let mut store = Store::new();
    assert_eq!(store.order_build(|| 7), 7);
    let work = store.take_membership_work();
    assert_eq!(work, MembershipWork { order_builds: 1, answer_writes: 0 });
    assert_eq!(work.to_string(), "order builds 1, answer writes 0");
}

#[test]
fn a_claim_goes_only_when_its_workspace_is_unlisted() {
    let mut claims = Claims::default();
    claims.pending.insert("a".into(), "w1".into());
    claims.quiet.insert("a".into());
    claims.background.insert("a".into());
    assert!(claims.awaits("a", "w1"));
    assert!(!claims.awaits("a", "w2"));
    assert!(!claims.release("a", true), "a listed workspace keeps its claim");
    assert!(claims.release("a", false));
    assert_eq!(claims, Claims::default());
    assert!(!claims.release("a", false), "no claim, no window waited");
}

#[test]
fn every_vector_answers_as_the_swift_store_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 1000, "{} cases", cases.len());
    for (index, case) in cases.iter().enumerate() {
        let request = &case["request"];
        let response = match case["op"].as_str().unwrap() {
            "registry_store_apply" => {
                let mut store: Store = serde_json::from_value(request["store"].clone()).unwrap();
                let action: StoreAction =
                    serde_json::from_value(request["action"].clone()).unwrap();
                let (changes, value) = store.run(action);
                serde_json::json!({ "store": store, "changes": changes, "value": value })
            }
            "registry_store_restore_closed" => {
                let mut memory: RestoreClosed =
                    serde_json::from_value(request["memory"].clone()).unwrap();
                let mut registry: Registry =
                    serde_json::from_value(request["registry"].clone()).unwrap();
                memory
                    .run(&mut registry, serde_json::from_value(request["action"].clone()).unwrap());
                serde_json::json!({ "memory": memory, "registry": registry })
            }
            "registry_store_claims" => {
                let mut claims: Claims = serde_json::from_value(request["claims"].clone()).unwrap();
                let value = claims.run(serde_json::from_value(request["action"].clone()).unwrap());
                serde_json::json!({ "claims": claims, "value": value })
            }
            op => panic!("case {index}: unknown op {op}"),
        };
        assert_eq!(response, case["response"], "case {index}: {request}");
    }
}
