//! The bookmark mirror at 100,000 bookmarks: the cost of one `apply` call
//! as the app makes it (JSON in, the delta out), per op kind, and of
//! `load` (the echo path). It checks results only and gates no time: the
//! numbers go to `cmux-tui/target/bookmark-mirror-bench.txt` (a fleet step
//! returns it with `--artifact`). Tests build at the dev profile
//! (opt-level 1), so these are upper bounds of a release build.

use std::fmt::Write as _;
use std::time::{Duration, Instant};

use cmux_bookmarks_core::mirror::Mirror;
use serde_json::{Value, json};

const PROFILE: &str = "default";

fn id(n: u64) -> String {
    format!("bm_{n:032x}")
}

fn node(n: u64, parent: &str, kind: &str, index: u64) -> Value {
    let mut node = json!({"id": id(n), "parent": parent, "kind": kind, "index": index,
                          "title": format!("Bookmark {n}"), "created_ms": 1_700_000_000_000_u64});
    if kind == "url" {
        node["url"] = json!(format!("https://example.com/page/{n}"));
        node["favicon_key"] = json!("https://example.com");
    }
    node
}

/// Ten folders of 9,000 bookmarks, one wide folder of `wide`, and a chain
/// of 64 nested folders (the depth limit) under Other: 100,000 nodes with
/// `wide` 9,925.
fn listing(wide: u64) -> Vec<Value> {
    let mut nodes = Vec::with_capacity(100_000);
    let mut next = 1_000_000u64;
    for folder in 0..10u64 {
        nodes.push(node(folder + 1, "bar", "folder", folder));
        for i in 0..9_000 {
            next += 1;
            nodes.push(node(next, &id(folder + 1), "url", i));
        }
    }
    nodes.push(node(100, "bar", "folder", 10));
    for i in 0..wide {
        next += 1;
        nodes.push(node(next, &id(100), "url", i));
    }
    let mut parent = "other".to_string();
    for level in 0..64u64 {
        nodes.push(node(200 + level, &parent, "folder", 0));
        parent = id(200 + level);
    }
    nodes
}

fn summary(name: &str, mut samples: Vec<Duration>) -> String {
    samples.sort();
    let at =
        |q: f64| samples[((samples.len() as f64 - 1.0) * q).round() as usize].as_secs_f64() * 1e3;
    format!(
        "{name:<34} n={:<4} p50 {:>8.3} ms  p95 {:>8.3} ms  p99 {:>8.3} ms  max {:>8.3} ms\n",
        samples.len(),
        at(0.5),
        at(0.95),
        at(0.99),
        at(1.0)
    )
}

fn apply(mirror: &mut Mirror, key: &str, op: Value) -> (Duration, Value) {
    let input = serde_json::to_vec(
        &json!({"browser_profile_id": PROFILE, "key": key, "op": op, "now_ms": 1}),
    )
    .unwrap();
    let start = Instant::now();
    let reply = mirror.call("apply", &input);
    let reply_bytes = serde_json::to_vec(&reply).unwrap();
    let took = start.elapsed();
    assert!(reply.get("delta").is_some(), "{key}: {reply}");
    assert!(!reply_bytes.is_empty());
    (took, reply)
}

#[test]
fn bookmark_mirror_at_100k_bookmarks() {
    const N: u64 = 100;
    let nodes = listing(9_925);
    assert_eq!(nodes.len(), 100_000);
    let load_input =
        serde_json::to_vec(&json!({"browser_profile_id": PROFILE, "bookmarks": nodes})).unwrap();
    let mut mirror = Mirror::new(7);
    let mut report = String::new();

    let mut loads = Vec::new();
    for _ in 0..3 {
        let start = Instant::now();
        let reply = mirror.call("load", &load_input);
        let bytes = serde_json::to_vec(&reply).unwrap();
        loads.push(start.elapsed());
        assert_eq!(reply["tree"].as_array().map(Vec::len), Some(100_000));
        assert!(!bytes.is_empty());
    }
    report += &summary("load (echo path, 100,000 nodes)", loads);

    // The edits run on 99,800 nodes, so the 200 creates fill the profile to its
    // 100,000-node limit instead of being refused by it.
    let edit_input =
        serde_json::to_vec(&json!({"browser_profile_id": PROFILE, "bookmarks": listing(9_725)}))
            .unwrap();
    assert_eq!(mirror.call("load", &edit_input)["tree"].as_array().map(Vec::len), Some(99_800));

    let mut renames = Vec::new();
    let mut creates = Vec::new();
    let mut same_parent = Vec::new();
    let mut across = Vec::new();
    let mut deep = Vec::new();
    let mut delta_bytes = 0usize;
    for k in 0..N {
        let (took, reply) = apply(
            &mut mirror,
            &format!("r{k}"),
            json!({"op": "update", "bookmark": id(1_090_001 + k * 7), "title": format!("Renamed {k}")}),
        );
        renames.push(took);
        delta_bytes = delta_bytes.max(serde_json::to_vec(&reply["delta"]).unwrap().len());
        let (took, _) = apply(
            &mut mirror,
            &format!("c{k}"),
            json!({"op": "create", "id": id(5_000_000 + k), "browser_profile_id": PROFILE, "parent": id(100),
                   "index": 0, "kind": "url", "title": "New", "url": "https://new.example/", "created_ms": 1}),
        );
        creates.push(took);
        let (took, _) = apply(
            &mut mirror,
            &format!("s{k}"),
            json!({"op": "move", "bookmark": id(5_000_000 + k), "parent": id(100), "index": 20_000}),
        );
        same_parent.push(took);
        let (took, _) = apply(
            &mut mirror,
            &format!("a{k}"),
            json!({"op": "move", "bookmark": id(1_000_001 + k), "parent": id(2 + k % 9), "index": 4_500}),
        );
        across.push(took);
        let (took, _) = apply(
            &mut mirror,
            &format!("d{k}"),
            json!({"op": "create", "id": id(6_000_000 + k), "browser_profile_id": PROFILE, "parent": id(262),
                   "kind": "url", "title": "Deep", "url": "https://deep.example/", "created_ms": 1}),
        );
        deep.push(took);
    }
    report += &summary("rename (1 node)", renames);
    report += &summary("create at index 0 of ~9,725", creates);
    report += &summary("move in one parent (to the end)", same_parent);
    report += &summary("move across folders (to 4,500)", across);
    report += &summary("create at depth 64 (in the 63rd folder)", deep);

    let mut deletes = Vec::new();
    for folder in 0..10u64 {
        let (took, reply) = apply(
            &mut mirror,
            &format!("x{folder}"),
            json!({"op": "delete", "bookmark": id(folder + 1)}),
        );
        deletes.push(took);
        assert!(reply["delta"]["deleted"].as_array().map_or(0, Vec::len) >= 8_000);
    }
    report += &summary("delete a folder of ~9,000", deletes);
    writeln!(report, "largest rename delta: {delta_bytes} bytes").unwrap();

    let out = concat!(env!("CARGO_MANIFEST_DIR"), "/../../target/bookmark-mirror-bench.txt");
    if let Some(dir) = std::path::Path::new(out).parent() {
        std::fs::create_dir_all(dir).unwrap();
    }
    std::fs::write(out, &report).unwrap();
    eprintln!("{report}");
}
