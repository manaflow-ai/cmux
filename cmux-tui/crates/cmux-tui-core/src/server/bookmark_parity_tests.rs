//! The daemon and cmux-bookmarks-core agree (layer-ownership.md V-11): the
//! app shows its pending bookmark edits through `Tree::apply`, so every op
//! must give the tree, result and refusal the daemon's SQLite path gives.
//! Each step reads the daemon's listing, applies one random op to both, and
//! compares. Only an import's new ids differ (each side mints its own);
//! they are compared by position.

use std::collections::{HashMap, HashSet};

use cmux_bookmarks_core::preview::IdMint;
use cmux_bookmarks_core::{
    Bookmark, BookmarkImport, BookmarkImportNode, BookmarkInput, BookmarkOp, BookmarkUpdate, Tree,
};

use super::*;

const PROFILE: &str = "default";

/// The command line of `op`, as the app sends it.
fn wire(op: &BookmarkOp) -> Value {
    let mut request = serde_json::to_value(op).unwrap();
    let object = request.as_object_mut().unwrap();
    object.remove("op");
    if matches!(op, BookmarkOp::Create(_) | BookmarkOp::Import(_)) {
        object.retain(|_, value| !value.is_null());
    }
    if let Some(id) = object.remove("id") {
        object.insert("bookmark".into(), id);
    }
    object.insert("cmd".into(), json!(op.name()));
    request
}

fn nodes_of(listing: &Value) -> Vec<Bookmark> {
    serde_json::from_value(listing["bookmarks"].clone()).unwrap()
}

/// New ids (not in `known`) become `new-<n>` in listing order, parents too.
fn normalized(
    nodes: Vec<Bookmark>,
    known: &HashSet<String>,
) -> (Vec<Bookmark>, HashMap<String, String>) {
    let mut names = HashMap::new();
    for node in &nodes {
        if !known.contains(&node.id) {
            let name = format!("new-{}", names.len());
            names.insert(node.id.clone(), name);
        }
    }
    let rename = |id: &str| names.get(id).cloned().unwrap_or_else(|| id.to_string());
    let nodes = nodes
        .into_iter()
        .map(|mut node| {
            node.id = rename(&node.id);
            node.parent = rename(&node.parent);
            node
        })
        .collect();
    (nodes, names)
}

fn fresh_id(random: &mut Seeded) -> String {
    format!("bm_{:016x}{:016x}", random.below(usize::MAX) as u64, random.below(usize::MAX) as u64)
}

fn some_id(random: &mut Seeded, nodes: &[Bookmark]) -> String {
    if nodes.is_empty() || random.below(8) == 0 {
        return fresh_id(random);
    }
    nodes[random.below(nodes.len())].id.clone()
}

/// A root, a folder, or now and then a parent the daemon refuses.
fn some_parent(random: &mut Seeded, nodes: &[Bookmark]) -> String {
    let folders = nodes.iter().filter(|node| node.kind == "folder").collect::<Vec<_>>();
    match random.below(folders.len() + 4) {
        0 => "bar".into(),
        1 => "other".into(),
        2 => match random.below(3) {
            0 => "nope".into(),
            1 => fresh_id(random),
            _ => some_id(random, nodes),
        },
        3 => "bar".into(),
        n => folders[n - 4].id.clone(),
    }
}

fn some_index(random: &mut Seeded) -> Option<usize> {
    (random.below(4) != 0).then(|| random.below(6))
}

fn import_node(
    kind: &str,
    title: String,
    url: Option<String>,
    created_ms: u64,
    children: Option<Vec<BookmarkImportNode>>,
) -> BookmarkImportNode {
    BookmarkImportNode { kind: kind.into(), title, url, created_ms: Some(created_ms), children }
}

fn random_op(random: &mut Seeded, nodes: &[Bookmark], step: usize) -> BookmarkOp {
    let created_ms = 1_000 + step as u64;
    let update = |bookmark: String, update: BookmarkUpdate| BookmarkOp::Update { bookmark, update };
    match random.below(10) {
        0 | 1 => {
            let folder = random.below(2) == 0;
            let url = match random.below(10) {
                0 => "relative/path".to_string(),
                1 => "http://exa mple.com".to_string(),
                _ => format!("https://example.com/{step}"),
            };
            BookmarkOp::Create(BookmarkInput {
                id: Some(if random.below(6) == 0 {
                    some_id(random, nodes)
                } else {
                    fresh_id(random)
                }),
                browser_profile_id: PROFILE.into(),
                parent: some_parent(random, nodes),
                index: some_index(random),
                kind: if folder { "folder" } else { "url" }.into(),
                title: if random.below(20) == 0 { "nul\0".into() } else { format!("n{step}") },
                url: (!folder || random.below(10) == 0).then_some(url),
                favicon_key: (random.below(3) == 0).then(|| "https://example.com".into()),
                source_key: (random.below(10) == 0).then(|| "chrome".into()),
                created_ms: Some(created_ms),
            })
        }
        2 | 3 => BookmarkOp::Move {
            bookmark: some_id(random, nodes),
            parent: some_parent(random, nodes),
            index: random.below(6),
        },
        4 => BookmarkOp::Delete { bookmark: some_id(random, nodes) },
        5 => update(
            some_id(random, nodes),
            BookmarkUpdate {
                title: (random.below(2) == 0).then(|| format!("t{step}")),
                url: (random.below(3) == 0).then(|| format!("https://u.example/{step}")),
                ..BookmarkUpdate::default()
            },
        ),
        6 => update(
            some_id(random, nodes),
            BookmarkUpdate {
                favicon_key: match random.below(3) {
                    0 => Some(None),
                    1 => Some(Some("https://f.example".into())),
                    _ => None,
                },
                last_used_ms: (random.below(2) == 0)
                    .then(|| (random.below(2) == 0).then_some(created_ms)),
                ..BookmarkUpdate::default()
            },
        ),
        7 => update(
            some_id(random, nodes),
            BookmarkUpdate {
                icon: Some((random.below(2) == 0).then(|| "star".into())),
                ..BookmarkUpdate::default()
            },
        ),
        _ => {
            let replace = random.below(2) == 0;
            let mut roots = vec![import_node(
                "folder",
                format!("i{step}"),
                None,
                10_000 + step as u64,
                Some(vec![
                    import_node(
                        "url",
                        "a".into(),
                        Some(format!("https://a.example/{step}")),
                        5,
                        None,
                    ),
                    import_node(
                        "folder",
                        "b".into(),
                        None,
                        6,
                        Some(vec![import_node(
                            "url",
                            "c".into(),
                            Some("https://c.example".into()),
                            7,
                            None,
                        )]),
                    ),
                ]),
            )];
            if random.below(2) == 0 {
                roots.push(import_node(
                    "url",
                    "next".into(),
                    Some("https://next.example".into()),
                    8,
                    None,
                ));
            }
            if random.below(12) == 0 {
                roots.clear();
            }
            BookmarkOp::Import(BookmarkImport {
                browser_profile_id: PROFILE.into(),
                parent: some_parent(random, nodes),
                index: some_index(random),
                source_key: (random.below(6) != 0).then(|| "chrome".into()),
                replace,
                nodes: roots,
            })
        }
    }
}

#[test]
fn the_daemon_and_the_shared_reducer_give_the_same_tree_result_and_refusal() {
    let mut refused = 0;
    let mut applied = 0;
    for seed in [
        0x9e37_79b9_7f4a_7c15_u64,
        0x2545_f491_4f6c_dd1d,
        0xdead_beef_cafe_f00d,
        0x0123_4567_89ab_cdef,
    ] {
        let mux = bookmarks_mux();
        let mut random = Seeded(seed);
        let mut ids = IdMint::new(seed);
        for step in 0..250 {
            let before = listed(&mux, PROFILE);
            let nodes = nodes_of(&before);
            let known = nodes.iter().map(|node| node.id.clone()).collect::<HashSet<_>>();
            let op = random_op(&mut random, &nodes, step);
            let context = format!("seed {seed:#x} step {step}: {}", wire(&op));
            let mut tree = Tree::from_listing(PROFILE, nodes.clone());
            assert_eq!(
                tree.listing(),
                nodes,
                "{context}: the tree reads the listing back as it is"
            );
            let expected = tree.apply(op.clone(), 0, &mut || ids.next_id());
            let actual = run(&mux, wire(&op));
            let after = listed(&mux, PROFILE);
            match (expected, actual) {
                (Ok(shared), Ok(daemon)) => {
                    applied += 1;
                    let (daemon_tree, daemon_names) = normalized(nodes_of(&after), &known);
                    let (shared_tree, shared_names) = normalized(tree.listing(), &known);
                    assert_eq!(shared_tree, daemon_tree, "{context}");
                    let daemon = without_replayed(&daemon);
                    if let BookmarkOp::Import(_) = op {
                        let roots = |result: &Value, names: &HashMap<String, String>| {
                            result["root_ids"]
                                .as_array()
                                .unwrap()
                                .iter()
                                .map(|id| {
                                    names
                                        .get(id.as_str().unwrap())
                                        .cloned()
                                        .unwrap_or_else(|| id.as_str().unwrap().into())
                                })
                                .collect::<Vec<_>>()
                        };
                        assert_eq!(shared.result["count"], daemon["count"], "{context}");
                        assert_eq!(
                            roots(&shared.result, &shared_names),
                            roots(&daemon, &daemon_names),
                            "{context}"
                        );
                    } else {
                        assert_eq!(shared.result, daemon, "{context}");
                    }
                    assert_eq!(
                        shared.changed,
                        after != before,
                        "{context}: changed matches the revision bump"
                    );
                }
                (Err(shared), Err(daemon)) => {
                    refused += 1;
                    assert_eq!(
                        response_error_code(&daemon).as_deref(),
                        Some(shared.code()),
                        "{context}: {daemon}"
                    );
                    assert_eq!(shared.to_string(), daemon.to_string(), "{context}");
                    assert_eq!(after, before, "{context}: a refusal writes nothing");
                }
                (shared, daemon) => {
                    panic!("{context}: the shared reducer gave {shared:?}, the daemon {daemon:?}")
                }
            }
        }
    }
    // The corpus reaches both outcomes (the counts are fixed by the seeds).
    assert!(applied > 100 && refused > 30, "applied {applied}, refused {refused}");
}
