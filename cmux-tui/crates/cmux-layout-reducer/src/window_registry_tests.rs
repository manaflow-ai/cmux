//! `window_registry`'s rules, mirroring the app's registry tests (`WindowRegistryAnswersTests`,
//! `RestoreClosedWindowsTests`, `GatherWindowsSharedSpaceTests`) at the registry, and the
//! documented transitions of the Swift type; `schemas/window-registry/vectors.json` checks every
//! action against the Swift answers.

use crate::window_registry::{Action, Changes, Registry, Window};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};

const VECTORS: &str = include_str!("../../../../schemas/window-registry/vectors.json");

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

/// What `registry` says for each workspace without `owner`: the first window that lists it gives
/// its owner and its kind; a discarded workspace is incognito (`WindowRegistryAnswersTests.answers`).
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

fn expect_answers(registry: &Registry, step: &str) {
    let (_, owners) = answers(registry);
    for id in ["a", "b", "c", "d", "z"] {
        assert_eq!(
            registry.owner(id).map(str::to_string),
            owners.get(id).cloned(),
            "after {step}: the owner of {id}"
        );
    }
    assert!(registry.violations().is_empty(), "after {step}: {:?}", registry.violations());
}

#[test]
fn the_answers_follow_each_registry_change() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a", "b"]);
    assert_eq!(registry.owner("a"), Some("w1"));
    assert_eq!(registry.owner("b"), Some("w1"));
    expect_answers(&registry, "a normal window opened");

    registry.mark_incognito("w2");
    assert!(registry.is_incognito("w2"));
    expect_answers(&registry, "a window marked incognito before its list");

    open(&mut registry, "w2", &["c"]);
    assert_eq!(registry.owner("c"), Some("w2"));
    assert_eq!(answers(&registry).0.get("c"), Some(&true));
    expect_answers(&registry, "the incognito window listed c");

    registry.activate("w1");
    assert_eq!(registry.recency, ids(&["w1", "w2"]));

    // Nothing moves across the kinds.
    assert!(registry.move_into(&ids(&["b"]), "w2", None).is_empty());
    assert_eq!(registry.owner("b"), Some("w1"));

    // The incognito window closes for good: its workspace is discarded, with no owner.
    let changes = registry.close("w2", true);
    assert_eq!(changes.discarded, ids(&["c"]));
    assert!(registry.discarding.contains("c"));
    assert_eq!(registry.owner("c"), None);
    assert!(registry.window("w2").is_none() && !registry.is_incognito("w2"));
    expect_answers(&registry, "the incognito window closed");

    // The daemon reports the discarded workspace gone.
    reconcile(&mut registry, &["a", "b"], &["c"], "w1");
    assert!(!registry.discarding.contains("c"));

    open(&mut registry, "w3", &["b"]);
    assert_eq!(registry.owner("b"), Some("w3"));
    assert_eq!(registry.window("w1").unwrap().workspace_ids, ids(&["a"]));

    // A normal window closes and keeps its list.
    let changes = registry.close("w3", true);
    assert!(changes.is_empty());
    assert!(!registry.window("w3").unwrap().is_open);
    assert_eq!(registry.owner("b"), Some("w3"));
    assert_eq!(registry.recency.first().map(String::as_str), Some("w3"));
    expect_answers(&registry, "a normal window closed with its list");
}

#[test]
fn a_discarded_workspace_with_no_window_is_given_to_none_until_it_is_gone() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a"]);
    registry.mark_discarding(&ids(&["z"]));
    reconcile(&mut registry, &["a", "z"], &[], "w1");
    assert_eq!(registry.owner("z"), None, "reconcile gave a discarded workspace to a window");
    reconcile(&mut registry, &["a"], &[], "w1");
    assert!(!registry.discarding.contains("z"));
}

#[test]
fn the_first_window_that_lists_a_workspace_answers_for_it() {
    let mut registry =
        Registry::new(vec![Window::new("w1", ids(&["d"])), Window::new("w2", ids(&["d", "a"]))]);
    registry.mark_incognito("w2");
    assert_eq!(registry.owner("d"), Some("w1"));
    assert_eq!(answers(&registry).0.get("a"), Some(&true));
    assert_eq!(registry.violations(), vec!["d owned by w1 and w2".to_string()]);
}

#[test]
fn a_late_workspace_goes_to_the_fallback_window() {
    // RestoreClosedWindowsTests: reconcile's fallback window is the closed launch window.
    let mut registry = Registry::default();
    let changes = reconcile(&mut registry, &["first"], &[], "launch");
    assert_eq!(registry.owner("first"), Some("launch"));
    assert_eq!(changes.moved.get("launch"), Some(&ids(&["first"])));
    assert!(registry.window("launch").unwrap().is_open);
}

#[test]
fn reconcile_places_orders_holds_and_closes_the_emptied() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["b", "a"]);
    open(&mut registry, "w2", &["c"]);
    registry.activate("w1");
    let placements = BTreeMap::from([("e".to_string(), "w3".to_string())]);
    let changes = registry.reconcile(
        &ids(&["a", "b", "d", "e", "f"]),
        &set(&["c"]),
        &placements,
        &set(&["f"]),
        &set(&["w3"]),
        "fallback",
    );
    assert_eq!(changes.emptied, ids(&["w2"]));
    assert_eq!(registry.window("w1").unwrap().workspace_ids, ids(&["a", "b", "d"]));
    assert_eq!(registry.owner("e"), Some("w3"));
    assert_eq!(registry.owner("f"), None, "a held orphan was given a window");
    assert_eq!(
        registry.recency.last().map(String::as_str),
        Some("w3"),
        "a placement behind was not last"
    );
    assert_eq!(changes.moved.get("w1"), Some(&ids(&["d"])));
}

#[test]
fn a_claim_on_a_closed_window_falls_through_to_the_most_recent_open() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a"]);
    open(&mut registry, "w2", &["b"]);
    registry.close("w2", true);
    let placements = BTreeMap::from([("c".to_string(), "w2".to_string())]);
    registry.reconcile(
        &ids(&["a", "b", "c"]),
        &BTreeSet::new(),
        &placements,
        &BTreeSet::new(),
        &BTreeSet::new(),
        "x",
    );
    assert_eq!(registry.owner("c"), Some("w1"));
}

#[test]
fn a_shared_space_hands_its_workspace_over_on_close() {
    let mut registry = Registry::default();
    open(&mut registry, "here", &["k0"]);
    open(&mut registry, "there", &["k1"]);
    registry.set_guests(&ids(&["k1"]), "here");
    registry.set_guests(&ids(&["k0"]), "there");
    assert!(registry.is_guest("k1", "here") && registry.is_guest("k0", "there"));
    assert_eq!(registry.owner("k0"), Some("here"));
    assert_eq!(registry.owner("k1"), Some("there"));
    assert!(registry.lists("k1", "here"));

    let changes = registry.close("there", true);
    assert_eq!(changes.moved.get("here"), Some(&ids(&["k1"])));
    assert_eq!(registry.owner("k1"), Some("here"));
    assert!(registry.window("there").is_none(), "a window left with nothing stayed");
    assert_eq!(changes.emptied, ids(&["there"]));
    assert!(registry.violations().is_empty());
}

#[test]
fn a_gather_closes_a_giver_left_with_guests_only_and_keeps_a_view() {
    let mut registry = Registry::default();
    open(&mut registry, "here", &["k0"]);
    open(&mut registry, "there", &["k2", "k3"]);
    registry.open_view("view", &ids(&["k2", "k3"]));
    assert!(registry.window("view").unwrap().owned_ids().is_empty());
    open(&mut registry, "third", &["k4"]);
    registry.set_guests(&ids(&["k0"]), "third");

    // The view never owned k2 or k3, so it is no giver (passed as one, it would close too).
    let changes = registry.gather(&ids(&["k2", "k3"]), "here", &ids(&["there"]));
    assert!(registry.window("there").is_none(), "the emptied window stayed");
    assert_eq!(changes.emptied, ids(&["there"]));
    assert_eq!(registry.owner("k2"), Some("here"));
    assert_eq!(registry.owner("k3"), Some("here"));
    assert!(registry.window("view").unwrap().is_open, "the view closed");
    assert_eq!(registry.window("view").unwrap().workspace_ids, ids(&["k2", "k3"]));
    assert!(registry.is_guest("k0", "third"), "a moved workspace's view lost it");
}

#[test]
fn a_window_without_records_merges_into_the_most_recent_other() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a"]);
    open(&mut registry, "w2", &["b", "c"]);
    registry.activate("w1");
    let changes = registry.close("w2", false);
    assert_eq!(changes.moved.get("w1"), Some(&ids(&["b", "c"])));
    assert!(registry.window("w2").is_none());
    assert_eq!(registry.window("w1").unwrap().workspace_ids, ids(&["a", "b", "c"]));
    // The last window stays, closed, with its list.
    registry.close("w1", false);
    assert!(!registry.window("w1").unwrap().is_open);
}

#[test]
fn reopen_and_release_closed() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a"]);
    open(&mut registry, "w2", &["b"]);
    registry.close("w1", true);
    registry.close("w2", true);
    assert_eq!(registry.open_recency(), Vec::<String>::new());
    assert_eq!(registry.reopen(), Some("w2".to_string()));
    assert!(!registry.reopen_id("w2"), "an open window reopened");
    // w1's group was deleted: its workspace moves to the open w2.
    let changes = registry.release_closed("w1");
    assert_eq!(changes.moved.get("w2"), Some(&ids(&["a"])));
    assert!(registry.window("w1").is_none());
    // With no open window of its kind, a released window opens again.
    registry.close("w2", true);
    assert!(registry.release_closed("w2").is_empty());
    assert!(registry.window("w2").unwrap().is_open);
}

#[test]
fn open_window_refuses_a_mix_of_kinds_and_inherits_incognito() {
    let mut registry = Registry::default();
    open(&mut registry, "n", &["a"]);
    registry.mark_incognito("i");
    open(&mut registry, "i", &["b"]);
    assert!(open(&mut registry, "x", &["a", "b"]).is_empty(), "a mix of kinds opened");
    assert!(registry.window("x").is_none());
    // A tear-off from an incognito window is incognito; a window marked incognito takes no normal one.
    open(&mut registry, "j", &["b"]);
    assert!(registry.is_incognito("j"));
    assert!(registry.window("i").is_none(), "the emptied incognito window stayed");
    registry.mark_incognito("k");
    assert!(open(&mut registry, "k", &["a"]).is_empty());
    // A window opened behind is the least recent.
    registry.open_window("back", &ids(&["c"]), None, None, true);
    assert_eq!(registry.recency.last().map(String::as_str), Some("back"));
}

#[test]
fn move_inserts_before_the_anchor_and_closes_the_emptied() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a", "b"]);
    open(&mut registry, "w2", &["c"]);
    let changes = registry.move_into(&ids(&["c", "c"]), "w1", Some("b"));
    assert_eq!(registry.window("w1").unwrap().workspace_ids, ids(&["a", "c", "b"]));
    assert_eq!(changes.emptied, ids(&["w2"]));
    assert_eq!(changes.moved.get("w1"), Some(&ids(&["c"])));
    registry.order(&ids(&["b", "a"]));
    assert_eq!(registry.window("w1").unwrap().workspace_ids, ids(&["b", "a", "c"]));
}

#[test]
fn set_guests_skips_own_and_unowned_and_keeps_a_lone_views_list() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a"]);
    open(&mut registry, "w2", &["b"]);
    registry.set_guests(&ids(&["a", "b", "zz"]), "w2");
    assert_eq!(registry.window("w2").unwrap().workspace_ids, ids(&["b", "a"]));
    assert_eq!(registry.window("w2").unwrap().guests, set(&["a"]));
    registry.open_view("v", &ids(&["a"]));
    registry.set_guests(&[], "v");
    assert_eq!(
        registry.window("v").unwrap().workspace_ids,
        ids(&["a"]),
        "a view lost its last list"
    );
}

#[test]
fn queries() {
    let mut registry = Registry::default();
    open(&mut registry, "w1", &["a"]);
    open(&mut registry, "w2", &["b"]);
    assert_eq!(registry.most_recent(&ids(&["w1", "w2"])), Some("w2".to_string()));
    assert_eq!(registry.most_recent(&ids(&["nope", "w1"])), Some("w1".to_string()));
    assert_eq!(registry.most_recent(&[]), None);
    assert_eq!(registry.most_recent_open(&ids(&["w2"]), false), Some("w1".to_string()));
    assert_eq!(registry.most_recent_open(&[], true), None);
    registry.mark_incognito("w2");
    assert!(registry.crosses_incognito(&ids(&["b"]), "w1"));
    assert!(!registry.crosses_incognito(&ids(&["unknown"]), "w1"));
}

#[test]
fn every_vector_answers_as_the_swift_registry_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 1000, "{} cases", cases.len());
    for (index, case) in cases.iter().enumerate() {
        let mut registry: Registry =
            serde_json::from_value(case["request"]["registry"].clone()).unwrap();
        let action: Action = serde_json::from_value(case["request"]["action"].clone()).unwrap();
        let (changes, value) = registry.apply(action);
        let response = serde_json::json!({
            "registry": registry,
            "changes": changes,
            "value": value,
        });
        assert_eq!(response, case["response"], "case {index}: {}", case["request"]);
    }
}
