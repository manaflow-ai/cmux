//! The outbox (`hub/outbox.rs`) under load: a change costs the same with thousands of
//! deliveries kept, a day of sends leaves only the last day on disk, restarts and torn appends
//! lose nothing a sender was told is kept, and a restart loop holds no file or memory.

use super::*;
use crate::hub::outbox::{Delivery, KEEP_SETTLED_MS, Outbox, State};
use proptest::prelude::*;
use serde_json::json;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const HOUR_MS: u64 = 60 * 60 * 1000;

fn delivery(id: &str, state: State, at: u64) -> Delivery {
    Delivery {
        id: id.to_owned(),
        target: "lane".into(),
        request: json!({
            "sessionId": "lane",
            "prompt": [{"type": "text", "text": "A synthetic message of a usual length, to a lane."}],
            "_meta": {"acpmux": {"promptId": format!("p-{id}")}},
        }),
        caller: Some("chief".into()),
        unproven_caller: None,
        not_terminal: false,
        state,
        attempts: 1,
        never_sent: false,
        relay_post: None,
        error: None,
        accepted: None,
        created_at: at,
        updated_at: at,
    }
}

/// `outbox.json` holding `kept` settled deliveries of the last hour, and one queued, `live`.
fn outbox_with(dir: &Path, kept: usize) -> (Outbox, PathBuf) {
    let path = dir.join("outbox.json");
    let now = crate::store::now_ms();
    let mut book: BTreeMap<String, Delivery> = (0..kept)
        .map(|i| {
            let id = format!("d-{i:06}");
            (id.clone(), delivery(&id, State::Delivered, now - HOUR_MS))
        })
        .collect();
    book.insert("live".into(), delivery("live", State::Queued, now));
    std::fs::write(&path, serde_json::to_vec(&book).unwrap()).unwrap();
    let outbox = Outbox::default();
    outbox.open(&path);
    (outbox, path)
}

/// Bytes this thread writes for each of `ops` changes of the live delivery, after a warm-up.
fn written_per_change(kept: usize) -> Option<f64> {
    let dir = tempfile::tempdir().unwrap();
    let (outbox, _) = outbox_with(dir.path(), kept);
    let change = |n: u32| {
        outbox.update("live", |d| {
            d.attempts = n;
            d.state = if n.is_multiple_of(2) { State::Queued } else { State::Delivering };
        })
    };
    // Warm-up: the first change after open writes the journal's header whole.
    for n in 0..10 {
        change(n);
    }
    let ops = 300;
    let before = thread_written()?;
    for n in 0..ops {
        change(n);
    }
    Some((thread_written()? - before) as f64 / f64::from(ops))
}

/// cmuxterm-hq#8660's class: a change rewrote and synced the whole file, so its cost grew with
/// every delivery of the last day (2.1 to 34 GB of writes in hours on a busy machine).
#[test]
fn a_change_costs_the_same_with_thousands_of_deliveries_kept() {
    let (Some(small), Some(god)) = (written_per_change(100), written_per_change(5_000)) else {
        return; // No per-thread write counter (not Linux).
    };
    assert_flat_with_size("outbox write bytes per change (100 vs 5000 kept)", small, god, 64.0);
}

/// A day and a half of sends, one a minute, on this thread's compressed clock
/// (`store::test_clock`): once the first sends are a day old, each new one replaces one that
/// expires, so what is on disk stops growing.
#[test]
fn a_compressed_day_of_sends_stops_growing_on_disk_after_a_day() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("outbox.json");
    let outbox = Outbox::default();
    outbox.open(&path);
    let minute = 60 * 1000;
    let day = (KEEP_SETTLED_MS / minute) as usize;
    let sends = day * 3 / 2;
    let every = 60;
    let mut sizes = Vec::new();
    for i in 0..sends {
        crate::store::test_clock::advance(minute);
        let id = format!("s-{i:06}");
        outbox.add(delivery(&id, State::Queued, crate::store::now_ms())).unwrap();
        outbox.update(&id, |d| d.state = State::Delivered);
        if i % every == every - 1 {
            // A snapshot alone, so the sample is the book's size, not where the journal is
            // between two snapshots.
            outbox.compact();
            sizes.push(disk_bytes(dir.path()) as f64);
        }
    }
    let (kept, _) = outbox.list(None, usize::MAX);
    assert!(kept.len().abs_diff(day) <= 2, "kept {} sends, a day is {day}", kept.len());
    let one_copy: BTreeMap<&String, &Delivery> = kept.iter().map(|d| (&d.id, d)).collect();
    let one_copy = serde_json::to_vec(&one_copy).unwrap().len() as f64;
    let on_disk = disk_bytes(dir.path()) as f64;
    eprintln!(
        "STRESS outbox compressed day: kept={} one_copy={one_copy} disk={on_disk}",
        kept.len()
    );
    assert!(on_disk <= one_copy * 3.0 + 4096.0, "{on_disk} bytes on disk for {one_copy}");
    // Past the first day (and one sample for the expiry to catch up), no growth beyond the
    // width of one id more or less.
    let past_a_day = &sizes[day / every + 1..];
    assert_no_growth("outbox disk bytes per hour of sends, past a day", past_a_day, 512.0);
}

/// Restarts (the daemon killed and started again) in the middle of the work hold no file
/// descriptor or memory: in a process of its own, as both are counted for the whole process.
#[test]
fn a_restart_loop_holds_no_files_or_memory() {
    isolated("stress::outbox::restart_loop_alone");
}

#[test]
fn restart_loop_alone() {
    if !in_child() {
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("outbox.json");
    let (mut fds, mut rss) = (Vec::new(), Vec::new());
    for round in 0..14u64 {
        // A day passes between rounds: the last round's deliveries expire, so the book stays
        // the same size and any growth is held memory, not more deliveries.
        crate::store::test_clock::advance(KEEP_SETTLED_MS + 1);
        for i in 0..40u64 {
            let outbox = Outbox::default();
            outbox.open(&path);
            let id = format!("r-{round}-{i}");
            let now = crate::store::now_ms();
            outbox.add(delivery(&id, State::Queued, now)).unwrap();
            outbox.update(&id, |d| d.state = State::Delivered);
            if i % 8 == 0 {
                outbox.compact();
            }
        }
        // Warm-up: the first rounds fill the allocator's pools.
        if round >= 5 {
            fds.push(open_fds().unwrap() as f64);
            rss.push(rss_bytes().unwrap() as f64);
        }
    }
    assert_no_growth("outbox restart loop fds per 40 restarts", &fds, 0.0);
    assert_no_growth("outbox restart loop RSS per 40 restarts", &rss, 64.0 * 1024.0);
}

#[derive(Clone, Debug)]
enum Op {
    Add(u8),
    Settle(u8),
    Retry(u8),
    /// The daemon is killed and starts again.
    Restart,
    /// Killed in the middle of an append no sender was told about: a torn line at the end.
    TornRestart(usize),
}

fn op() -> impl Strategy<Value = Op> {
    prop_oneof![
        4 => (0u8..24).prop_map(Op::Add),
        3 => (0u8..24).prop_map(Op::Settle),
        3 => (0u8..24).prop_map(Op::Retry),
        1 => Just(Op::Restart),
        1 => (1usize..200).prop_map(Op::TornRestart),
    ]
}

fn reopen(path: &Path) -> Outbox {
    let outbox = Outbox::default();
    outbox.open(path);
    outbox
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, ..ProptestConfig::default() })]

    /// Whatever order adds, settles, retries, restarts and torn appends come in, the outbox
    /// read back after a restart is the one its callers were answered with: every delivery
    /// and its state, none twice, and the files hold no more than a snapshot's worth past it.
    #[test]
    fn what_was_answered_comes_back_after_any_restart(ops in proptest::collection::vec(op(), 1..60)) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("outbox.json");
        let journal = dir.path().join("outbox.journal");
        let mut outbox = reopen(&path);
        let mut model: BTreeMap<String, (State, u32)> = BTreeMap::new();
        let now = crate::store::now_ms();
        for op in ops {
            match op {
                Op::Add(k) => {
                    let id = format!("m-{k}");
                    let d = outbox.add(delivery(&id, State::Queued, now)).unwrap();
                    // The same prompt id answers with the first delivery.
                    model.entry(d.id.clone()).or_insert((State::Queued, 1));
                }
                Op::Settle(k) | Op::Retry(k) => {
                    let id = format!("m-{k}");
                    let Some(entry) = model.get_mut(&id) else { continue };
                    let settle = matches!(op, Op::Settle(_));
                    outbox.update(&id, |d| {
                        if settle { d.state = State::Delivered } else { d.attempts += 1 }
                    });
                    if settle { entry.0 = State::Delivered } else { entry.1 += 1 }
                }
                Op::Restart => {
                    drop(outbox);
                    outbox = reopen(&path);
                }
                Op::TornRestart(n) => {
                    drop(outbox);
                    use std::io::Write;
                    let mut f = std::fs::OpenOptions::new().append(true).create(true).open(&journal).unwrap();
                    let line = serde_json::to_vec(&delivery("torn", State::Queued, now)).unwrap();
                    f.write_all(&line[..n.min(line.len() - 1)]).unwrap();
                    drop(f);
                    outbox = reopen(&path);
                }
            }
        }
        drop(outbox);
        let back = reopen(&path);
        let (all, _) = back.list(None, usize::MAX);
        let got: BTreeMap<String, (State, u32)> =
            all.iter().map(|d| (d.id.clone(), (d.state, d.attempts))).collect();
        prop_assert_eq!(got.len(), all.len(), "a delivery came back twice");
        prop_assert_eq!(&got, &model);
        back.compact();
        let one_copy = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let total = disk_bytes(dir.path());
        prop_assert!(total <= one_copy * 3 + 65_536, "{} bytes on disk for a {}-byte snapshot", total, one_copy);
    }
}
