//! Scratch measurement, never lands: how long the event journal store's open takes after a kill,
//! with N chats that each have lines and a metadata image past the checkpoint (review 3 of #34901,
//! follow-up 4: the start budget is 8 s). Real files for the journal and the logs. Each size runs
//! `RUNS` times in this process, each run in its own home, sizes interleaved, so the lines give a
//! distribution: `open_ms` is the open alone (the daemon binds its socket after it); `ack_ms` the
//! person's first change right after it (a line to a replayed chat) until the S2c gate passes it
//! (its record durable), while the open's checkpoint may still run; `new_chat_ms` the same for a
//! new chat (its folder synced too); `ready_ms` the start to that first acknowledged change
//! (`open_ms` + `ack_ms`); `durable_ms` the start until a checkpoint after both changes ends
//! (every replayed record durable and retired).

use super::journal_store::FencedStorage;
use super::*;
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::Ordering;
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

/// Waits until the gate's durable LSN reaches `lsn` (the outbound gate's own test).
fn wait_gate(durability: &Durability, lsn: u64) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while *durability.durable.borrow() < lsn {
        assert!(Instant::now() < deadline, "the gate never passed LSN {lsn}");
        std::thread::sleep(Duration::from_micros(100));
    }
}

fn ms(elapsed: Duration) -> f64 {
    elapsed.as_secs_f64() * 1000.0
}

/// One kill and reopen with `chats` replayed chats: open, ack, new chat, durable (ms).
fn open_once(config: &StoreConfig, chats: usize) -> [f64; 4] {
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
    let durability = store.durability().unwrap_or_else(|| panic!("no durability"));
    let at = Instant::now();
    store.append("chat-0", &record(11)).unwrap_or_else(|e| panic!("{e:#}"));
    wait_gate(&durability, durability.acked.load(Ordering::SeqCst));
    let ack = at.elapsed();
    let at = Instant::now();
    store.save(&meta("chat-new", 0)).unwrap_or_else(|e| panic!("{e:#}"));
    store.append("chat-new", &record(1)).unwrap_or_else(|e| panic!("{e:#}"));
    wait_gate(&durability, durability.acked.load(Ordering::SeqCst));
    let new_chat = at.elapsed();
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    let durable = started.elapsed();
    drop(store);
    [ms(opened), ms(ack), ms(new_chat), ms(durable)]
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
    const WHAT: [&str; 5] = ["open_ms", "ack_ms", "new_chat_ms", "ready_ms", "durable_ms"];
    let mut samples: BTreeMap<(usize, usize), Vec<f64>> = BTreeMap::new();
    for run in 0..RUNS {
        for chats in SIZES {
            let [open_ms, ack_ms, new_chat_ms, durable_ms] = open_once(&config, chats);
            let ready_ms = open_ms + ack_ms;
            eprintln!(
                "ACPMUX-PERF openbench run={run} chats={chats} open_ms={open_ms:.1} ack_ms={ack_ms:.1} new_chat_ms={new_chat_ms:.1} ready_ms={ready_ms:.1} durable_ms={durable_ms:.1}"
            );
            for (what, value) in
                [open_ms, ack_ms, new_chat_ms, ready_ms, durable_ms].into_iter().enumerate()
            {
                samples.entry((what, chats)).or_default().push(value);
            }
        }
    }
    for ((what, chats), ms) in samples {
        summary(WHAT.get(what).copied().unwrap_or("?"), chats, ms);
    }
}
