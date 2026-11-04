//! Scratch measurement, never lands: how long the event journal store's open takes after a kill,
//! with N chats that each have lines and a metadata image past the checkpoint (review 3 of #34901,
//! follow-up 4: the start budget is 8 s). Real files for the journal and the logs. Each size runs
//! `RUNS` times in this process, each run in its own home, sizes interleaved, so the lines give a
//! distribution: `open_ms` is the open alone (the daemon binds its socket after it), `durable_ms`
//! the open plus a checkpoint (every replayed record durable and retired).

use super::journal_store::FencedStorage;
use super::*;
use serde_json::json;
use std::sync::Arc;
use std::time::{Duration, Instant};

const RUNS: usize = 10;
const SIZES: [usize; 3] = [10, 100, 300];

fn meta(id: &str, last_seq: u64) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "family": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1, "lastSeq": last_seq,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"))
}

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "mux".into(),
        kind: "queued".into(),
        msg: json!({ "n": seq, "text": "x".repeat(400) }),
        host_seq: None,
    }
}

/// One kill and reopen with `chats` replayed chats: (open ms, open plus checkpoint ms).
fn open_once(config: &StoreConfig, chats: usize) -> (f64, f64) {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let open = || {
        open_with_journal(
            config,
            home.path(),
            Arc::new(FencedStorage::daemon()),
            cmux_journal::Config::default(),
        )
        .unwrap_or_else(|e| panic!("open: {e:#}"))
    };
    let store = open();
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        store.save(&meta(&id, 0)).unwrap_or_else(|e| panic!("{e:#}"));
        for seq in 1..=5 {
            store.append(&id, &record(seq)).unwrap_or_else(|e| panic!("{e:#}"));
        }
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    for chat in 0..chats {
        let id = format!("chat-{chat}");
        for seq in 6..=10 {
            store.append(&id, &record(seq)).unwrap_or_else(|e| panic!("{e:#}"));
        }
        store.save(&meta(&id, 10)).unwrap_or_else(|e| panic!("{e:#}"));
    }
    assert!(store.wait_durable(Duration::from_secs(60)).unwrap_or_else(|e| panic!("{e:#}")));
    // A kill: no checkpoint, so the next open replays 5 lines and an image per chat.
    drop(store);
    let started = Instant::now();
    let store = open();
    let opened = started.elapsed();
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let durable = started.elapsed();
    drop(store);
    (opened.as_secs_f64() * 1000.0, durable.as_secs_f64() * 1000.0)
}

/// The nearest-rank `q` quantile of sorted `ms`.
fn quantile(ms: &[f64], q: f64) -> f64 {
    let rank = (q * ms.len() as f64).ceil() as usize;
    ms.get(rank.clamp(1, ms.len()).saturating_sub(1)).copied().unwrap_or(f64::NAN)
}

fn summary(what: &str, chats: usize, mut ms: Vec<f64>) {
    ms.sort_by(f64::total_cmp);
    eprintln!(
        "ACPMUX-PERF openbench-dist {what} chats={chats} runs={} min={:.1} p50={:.1} p90={:.1} max={:.1} all={:?}",
        ms.len(),
        ms.first().copied().unwrap_or(f64::NAN),
        quantile(&ms, 0.5),
        quantile(&ms, 0.9),
        ms.last().copied().unwrap_or(f64::NAN),
        ms.iter().map(|ms| (ms * 10.0).round() / 10.0).collect::<Vec<_>>(),
    );
}

#[test]
fn open_time_after_a_kill_with_replayed_chats() {
    if !std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|key| key.contains("openbench")) {
        eprintln!("ACPMUX-PERF openbench SKIP (runs in a fleet step whose key contains openbench)");
        return;
    }
    let config = StoreConfig { journal: true, ..StoreConfig::default() };
    let mut opens: BTreeMap<usize, Vec<f64>> = BTreeMap::new();
    let mut durables: BTreeMap<usize, Vec<f64>> = BTreeMap::new();
    for run in 0..RUNS {
        for chats in SIZES {
            let (open_ms, durable_ms) = open_once(&config, chats);
            eprintln!(
                "ACPMUX-PERF openbench run={run} chats={chats} open_ms={open_ms:.1} durable_ms={durable_ms:.1}"
            );
            opens.entry(chats).or_default().push(open_ms);
            durables.entry(chats).or_default().push(durable_ms);
        }
    }
    for (chats, ms) in opens {
        summary("open_ms", chats, ms);
    }
    for (chats, ms) in durables {
        summary("durable_ms", chats, ms);
    }
}
