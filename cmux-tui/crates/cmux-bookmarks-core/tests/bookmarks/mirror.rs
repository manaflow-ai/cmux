//! The bookmark mirror: the app's read model, fed only by `apply` deltas,
//! must equal the mirror's shown tree after every edit; pending edits
//! survive an echo until settled; a rejected edit goes away.

use std::collections::HashMap;

use cmux_bookmarks_core::mirror::Mirror;
use cmux_bookmarks_core::{Bookmark, Delta, OrderStep};
use serde_json::{Value, json};

const PROFILE: &str = "default";

fn id(n: u64) -> String {
    format!("bm_{n:032x}")
}

fn call(mirror: &mut Mirror, name: &str, input: Value) -> Value {
    mirror.call(name, &serde_json::to_vec(&input).unwrap())
}

fn view(mirror: &mut Mirror) -> Vec<Bookmark> {
    serde_json::from_value(
        call(mirror, "view", json!({"browser_profile_id": PROFILE}))["tree"].clone(),
    )
    .unwrap()
}

/// What the app keeps: nodes by id and each parent's ordered child ids,
/// changed only by deltas.
#[derive(Default)]
struct ReadModel {
    nodes: HashMap<String, Bookmark>,
    children: HashMap<String, Vec<String>>,
}

impl ReadModel {
    fn apply(&mut self, delta: &Delta) {
        for step in &delta.order {
            match step {
                OrderStep::Insert { parent, insert, at } => {
                    let list = self.children.entry(parent.clone()).or_default();
                    list.insert((*at).min(list.len()), insert.clone());
                }
                OrderStep::Remove { parent, remove } => {
                    if let Some(list) = self.children.get_mut(parent) {
                        list.retain(|value| value != remove);
                    }
                }
                OrderStep::Clear { clear } => {
                    self.children.remove(clear);
                }
            }
        }
        for gone in &delta.deleted {
            self.nodes.remove(gone);
            self.children.remove(gone);
        }
        for node in &delta.upserted {
            self.nodes.insert(node.id.clone(), node.clone());
        }
    }

    /// Pre-order like `listing`, with `index` from the child lists.
    fn listing(&self) -> Vec<Bookmark> {
        let mut out = Vec::new();
        let mut stack: Vec<(String, usize)> = Vec::new();
        for root in ["other", "bar"] {
            if let Some(list) = self.children.get(root) {
                stack.extend(list.iter().enumerate().rev().map(|(i, id)| (id.clone(), i)));
            }
        }
        while let Some((id, index)) = stack.pop() {
            if let Some(list) = self.children.get(&id) {
                stack.extend(list.iter().enumerate().rev().map(|(i, id)| (id.clone(), i)));
            }
            let mut node = self.nodes[&id].clone();
            node.index = index;
            out.push(node);
        }
        out
    }
}

struct Seeded(u64);

impl Seeded {
    fn below(&mut self, bound: usize) -> usize {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 % bound.max(1) as u64) as usize
    }
}

fn random_op(random: &mut Seeded, nodes: &[Bookmark], step: u64) -> Value {
    let folders = nodes.iter().filter(|node| node.kind == "folder").collect::<Vec<_>>();
    let parent = |random: &mut Seeded| match random.below(folders.len() + 2) {
        0 => json!("bar"),
        1 => json!("other"),
        n => json!(folders[n - 2].id),
    };
    let any = |random: &mut Seeded| {
        if nodes.is_empty() { id(0xdead) } else { nodes[random.below(nodes.len())].id.clone() }
    };
    match random.below(7) {
        0 => {
            json!({"op": "create", "id": id(step + 1), "browser_profile_id": PROFILE, "parent": parent(random),
                    "index": random.below(5), "kind": "folder", "title": format!("f{step}"), "created_ms": 1})
        }
        1 => {
            json!({"op": "create", "id": id(step + 1), "browser_profile_id": PROFILE, "parent": parent(random),
                    "kind": "url", "title": format!("u{step}"), "url": format!("https://e.example/{step}"),
                    "created_ms": 1})
        }
        2 | 3 => {
            json!({"op": "move", "bookmark": any(random), "parent": parent(random), "index": random.below(6)})
        }
        4 => json!({"op": "delete", "bookmark": any(random)}),
        5 => json!({"op": "update", "bookmark": any(random), "title": format!("t{step}")}),
        _ => {
            json!({"op": "import", "browser_profile_id": PROFILE, "parent": parent(random), "index": random.below(4),
                    "source_key": "chrome", "replace": random.below(2) == 0,
                    "nodes": [{"kind": "folder", "title": format!("i{step}"), "children": [
                        {"kind": "url", "title": "a", "url": "https://a.example"},
                        {"kind": "folder", "title": "b", "children": []}]}]})
        }
    }
}

#[test]
fn a_read_model_fed_only_by_deltas_equals_the_shown_tree() {
    let mut applied = 0;
    for seed in [0x9e37_79b9_7f4a_7c15_u64, 0x2545_f491_4f6c_dd1d, 0xdead_beef_cafe_f00d] {
        let mut mirror = Mirror::new(seed);
        let mut model = ReadModel::default();
        call(&mut mirror, "load", json!({"browser_profile_id": PROFILE, "bookmarks": []}));
        let mut random = Seeded(seed);
        for step in 0..300u64 {
            let nodes = view(&mut mirror);
            let op = random_op(&mut random, &nodes, step << 8);
            let reply = call(
                &mut mirror,
                "apply",
                json!({"browser_profile_id": PROFILE, "key": format!("k{step}"), "op": op, "now_ms": 5}),
            );
            if let Some(delta) = reply.get("delta") {
                applied += 1;
                model.apply(&serde_json::from_value(delta.clone()).unwrap());
            } else {
                assert!(reply.get("error_code").is_some(), "seed {seed} step {step}: {reply}");
            }
            assert_eq!(model.listing(), view(&mut mirror), "seed {seed} step {step}: {op}");
        }
    }
    assert!(applied > 300, "applied {applied}");
}

fn page(n: u64, parent: &str) -> Value {
    json!({"op": "create", "id": id(n), "browser_profile_id": PROFILE, "parent": parent, "kind": "url",
           "title": format!("p{n}"), "url": format!("https://p.example/{n}"), "created_ms": 1})
}

/// V-11: a second quick edit no longer flickers away when the first one's
/// echo lands before the second one's.
#[test]
fn a_pending_edit_survives_an_echo_that_lacks_it() {
    let mut mirror = Mirror::new(1);
    call(&mut mirror, "load", json!({"browser_profile_id": PROFILE, "bookmarks": []}));
    call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "a", "op": page(1, "bar"), "now_ms": 1}),
    );
    call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "b", "op": page(2, "bar"), "now_ms": 1}),
    );
    let first_echo =
        view(&mut mirror).into_iter().filter(|node| node.id == id(1)).collect::<Vec<_>>();
    call(&mut mirror, "settle", json!({"browser_profile_id": PROFILE, "key": "a"}));
    let reply =
        call(&mut mirror, "load", json!({"browser_profile_id": PROFILE, "bookmarks": first_echo}));
    assert_eq!(reply["dropped"], json!(["a"]));
    let ids = view(&mut mirror).into_iter().map(|node| node.id).collect::<Vec<_>>();
    assert_eq!(ids, [id(1), id(2)], "the second edit still shows");
}

#[test]
fn a_rejected_edit_goes_away_and_the_others_stay() {
    let mut mirror = Mirror::new(1);
    call(&mut mirror, "load", json!({"browser_profile_id": PROFILE, "bookmarks": []}));
    call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "a", "op": page(1, "bar"), "now_ms": 1}),
    );
    call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "b", "op": page(2, "bar"), "now_ms": 1}),
    );
    let reply = call(&mut mirror, "reject", json!({"browser_profile_id": PROFILE, "key": "a"}));
    let ids =
        reply["tree"].as_array().unwrap().iter().map(|node| node["id"].clone()).collect::<Vec<_>>();
    assert_eq!(ids, [json!(id(2))]);
}

#[test]
fn a_refused_edit_names_its_rule_and_a_key_is_used_once() {
    let mut mirror = Mirror::new(1);
    let refused = call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "a", "op": {"op": "delete", "bookmark": id(9)}, "now_ms": 1}),
    );
    assert_eq!(refused["error_code"], "not_found");
    assert_eq!(refused["reason"], "not_found");
    call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "b", "op": page(1, "bar"), "now_ms": 1}),
    );
    let again = call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "b", "op": page(2, "bar"), "now_ms": 1}),
    );
    assert_eq!(again["error_code"], "invalid_params");
    assert!(call(&mut mirror, "nope", json!({}))["error"].is_string());
}

/// A rename sends one node and no order step; a delete of a folder sends
/// its subtree's ids and one order step, never the tree.
#[test]
fn a_delta_holds_only_what_changed() {
    let mut mirror = Mirror::new(1);
    let mut listing = vec![
        json!({"id": id(1), "parent": "bar", "kind": "folder", "index": 0, "title": "F", "created_ms": 1}),
    ];
    for n in 0..500u64 {
        listing.push(
            json!({"id": id(100 + n), "parent": id(1), "kind": "url", "index": n, "title": "x",
                            "url": "https://x.example", "created_ms": 1}),
        );
    }
    call(&mut mirror, "load", json!({"browser_profile_id": PROFILE, "bookmarks": listing}));
    let rename = call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "r",
        "op": {"op": "update", "bookmark": id(300), "title": "y"}, "now_ms": 1}),
    );
    assert_eq!(rename["delta"]["upserted"].as_array().unwrap().len(), 1);
    assert_eq!(rename["delta"]["order"], json!([]));
    let moved = call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "m",
        "op": {"op": "move", "bookmark": id(100), "parent": id(1), "index": 499}, "now_ms": 1}),
    );
    assert_eq!(moved["delta"]["order"].as_array().unwrap().len(), 2);
    assert!(moved["delta"]["upserted"].as_array().unwrap().is_empty());
    let deleted = call(
        &mut mirror,
        "apply",
        json!({"browser_profile_id": PROFILE, "key": "d",
        "op": {"op": "delete", "bookmark": id(1)}, "now_ms": 1}),
    );
    assert_eq!(deleted["delta"]["deleted"].as_array().unwrap().len(), 501);
    assert_eq!(deleted["delta"]["order"], json!([{"parent": "bar", "remove": id(1)}]));
    assert!(deleted["delta"]["upserted"].as_array().unwrap().is_empty());
}
