//! What `composerStatus` costs a session list at 5,000 chats, in one harness: the same rows
//! without it (before), with the whole status on every row (after), and as a census row carries
//! it (`composer_status::census`, after mitigation). Prints the numbers; holds the census form to
//! 2% of a row's bytes.
//! `cargo test -p acpmux --release --lib composer_status_cost -- --nocapture`

use super::*;
use crate::config::Config;
use std::time::Instant;

const CHATS: usize = 5_000;

/// A home of `CHATS` chats as a person's looks: most closed, each in its own worktree on its own
/// branch, with a model, a title and a reply.
fn home() -> Arc<Hub> {
    let store = crate::store::MemoryStore::default();
    for n in 0..CHATS {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("chat-{n:05}"),
            "name": format!("claude-{n}"), "harness": "claude", "family": "claude",
            "agentSessionId": format!("5f0c1d2e-{n:05}-4a7b-9c3d-2e1f0a9b8c7d"),
            "cwd": format!("/Users/leo/.wt/checkouts/cmux/lane--composer-topic-{n}"),
            "gitBranch": format!("lane/composer-topic-{n}"),
            "modelRequest": "claude-opus-5-5",
            "status": if n % 10 == 0 { "idle" } else { "closed" },
            "createdAt": 1_795_000_000_000u64 + n as u64, "updatedAt": 1_795_000_100_000u64 + n as u64,
            "title": format!("Fix the composer footer status dot, part {n}"),
            "preview": "Done: the footer shows one dot, and the rundown lists each item.",
        }))
        .unwrap();
        crate::store::Store::save(&store, &meta).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

fn bytes(rows: &[Value]) -> usize {
    rows.iter().map(|row| row.to_string().len()).sum()
}

fn ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1000.0
}

#[test]
fn composer_status_cost() {
    let hub = home();
    let sessions = hub.sessions();
    assert_eq!(sessions.len(), CHATS);

    let start = Instant::now();
    let census: Vec<Value> = sessions.iter().map(|s| hub.session_list_summary(s)).collect();
    let build_ms = ms(start);
    let before: Vec<Value> = census
        .iter()
        .cloned()
        .map(|mut row| {
            row.as_object_mut().unwrap().remove("composerStatus");
            row
        })
        .collect();

    // The status alone, whole and census, on the same rows (the clones made before the clock).
    let mut whole = before.clone();
    let start = Instant::now();
    for row in &mut whole {
        set_composer_status(row, true);
    }
    let whole_ms = ms(start);
    let mut cut = before.clone();
    let start = Instant::now();
    for row in &mut cut {
        set_composer_status(row, false);
    }
    let census_ms = ms(start);
    assert_eq!(cut, census, "the census form is what a list row carries");

    let serialize = |rows: &[Value]| {
        let start = Instant::now();
        let text = serde_json::to_string(rows).unwrap();
        (text.len(), ms(start))
    };
    let (before_bytes, before_ser) = serialize(&before);
    let (whole_bytes, whole_ser) = serialize(&whole);
    let (census_bytes, census_ser) = serialize(&census);
    let row = |total: usize| total as f64 / CHATS as f64;
    let share = |total: usize| (total as f64 - before_bytes as f64) / before_bytes as f64 * 100.0;
    let per_row_us = |ms: f64| ms * 1000.0 / CHATS as f64;
    eprintln!("PERF composer_status chats={CHATS} list build {build_ms:.1} ms (census rows)");
    eprintln!(
        "PERF composer_status before: {before_bytes} B ({:.0} B/row), serialize {before_ser:.1} ms",
        row(before_bytes)
    );
    eprintln!(
        "PERF composer_status after (whole): {whole_bytes} B ({:.0} B/row, +{:.1}%), status {:.2} us/row, serialize {whole_ser:.1} ms",
        row(whole_bytes),
        share(whole_bytes),
        per_row_us(whole_ms)
    );
    eprintln!(
        "PERF composer_status after (census): {census_bytes} B ({:.0} B/row, +{:.1}%), status {:.2} us/row, serialize {census_ser:.1} ms",
        row(census_bytes),
        share(census_bytes),
        per_row_us(census_ms)
    );
    assert_eq!(bytes(&before), bytes(&census), "a quiet census row carries no status");
    assert!(share(census_bytes) <= 2.0, "census rows grew {:.1}%", share(census_bytes));
    // Loose, for a debug build on a loaded runner: the status is a fixed set of key reads.
    assert!(per_row_us(whole_ms) < 200.0, "{:.1} us/row", per_row_us(whole_ms));

    // The open chat's read (tools) still carries every fact.
    let open = hub.session_summary(&sessions[0]);
    let kinds: Vec<&str> = open["composerStatus"]["facts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|fact| fact["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["folder", "branch", "harness", "model"], "{open}");
}

/// A census row keeps a status worth showing, without the facts that repeat the row.
#[test]
fn a_census_row_keeps_items_and_live_facts_only() {
    let mut row = json!({
        "cwd": "/x", "harness": "claude", "model": "opus", "queued": 2, "rateLimitedUntil": 9,
    });
    set_composer_status(&mut row, false);
    let status = &row["composerStatus"];
    assert_eq!(status["items"][0]["words"], "status.rateLimited.until");
    assert_eq!(status["facts"], json!([{"kind": "queued", "count": 2, "live": true}]));
    let mut quiet = json!({"cwd": "/x", "harness": "claude", "queued": 0});
    set_composer_status(&mut quiet, false);
    assert!(quiet.get("composerStatus").is_none(), "{quiet}");
    // A peer's whole row, cut for a list the same way with and without a parse.
    let mut whole = json!({"sessionId": "a", "cwd": "/x", "harness": "claude", "queued": 0});
    set_composer_status(&mut whole, true);
    assert!(whole["composerStatus"]["facts"].as_array().is_some_and(|f| f.len() == 2));
    let packed = PeerRow::new(&whole);
    let listed: Value = serde_json::from_str(&packed.changed_text(false)).unwrap();
    assert!(listed.get("composerStatus").is_none(), "{listed}");
    assert_eq!(without_summary_tools(whole.clone()), listed);
    let attached: Value = serde_json::from_str(&packed.changed_text(true)).unwrap();
    assert_eq!(attached["composerStatus"], whole["composerStatus"]);
}
