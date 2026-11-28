//! The chat activity cost with a long history: 9,000 closed sessions and 50 live ones, read by 8
//! chats watchers on every one-chat change batch while another thread resolves sessions (a peer
//! notice's lookup). The output supplies the PR's before/after table.

use super::*;
use crate::config::Config;
use crate::hub::peer_snapshot::thread_allocations;
use crate::store::{MemoryStore, Store};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};

const WATCHERS: usize = 8;
const BATCHES: usize = 20;

fn scale_hub(closed_count: usize, live_count: usize) -> Arc<Hub> {
    let store = MemoryStore::default();
    for n in 0..closed_count + live_count {
        let live = n >= closed_count;
        // Every tenth closed session continues the chat before it; a third were started by a
        // live session's agent.
        let chat = if !live && n % 10 == 9 { n - 1 } else { n };
        let mut row = json!({"schema": crate::store::META_SCHEMA, "id": format!("s-{n:05}"),
            "name": format!("s-{n:05}"), "harness": "claude", "family": "claude",
            "agentSessionId": format!("chat-{chat:05}"), "cwd": "/nonexistent",
            "status": if !live { "closed" } else if n % 5 == 0 { "waiting" } else { "idle" },
            "createdAt": 1, "updatedAt": n + 1, "unread": n % 7 == 0,
            "preview": "A short synthetic reply\nover two lines",
            "configOptions": [{"payload": "x".repeat(2_048)}]});
        if !live && n % 3 == 0 {
            let parent = closed_count + n % live_count;
            row.set("tags", json!({"spawnedBy": {"value": format!("s-{parent:05}")}}));
        }
        store.save(&serde_json::from_value(row).unwrap()).unwrap();
    }
    Hub::new(Config::default(), Box::new(store))
}

fn process_cpu() -> Duration {
    let mut value = std::mem::MaybeUninit::<libc::timespec>::uninit();
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, value.as_mut_ptr()) },
        0
    );
    let value = unsafe { value.assume_init() };
    Duration::new(u64::try_from(value.tv_sec).unwrap(), u32::try_from(value.tv_nsec).unwrap())
}

/// What one watcher does with a one-chat batch: the activity, then the chat's value decorated.
fn one_watcher(hub: &Hub, batch: &Arc<Vec<SeqChange>>, n: usize, total: usize) -> Value {
    let activity = hub.chat_activity_for_batch(batch);
    let mut chat = json!({"key": format!("claude-code:chat-{:05}", n % total)});
    activity.decorate(&mut chat);
    chat
}

fn percentile(sorted: &[Duration], p: f64) -> f64 {
    let at = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted.get(at).map_or(0.0, |d| d.as_secs_f64() * 1e6)
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "manual chat activity measurement"]
fn measure_chat_activity_9000_closed_8_watchers() {
    measure_scale("9k", 9_000, 50);
}

#[cfg(target_os = "linux")]
#[test]
#[ignore = "manual chat activity measurement"]
fn measure_chat_activity_500_closed_7_live_8_watchers() {
    measure_scale("500", 493, 7);
}

#[cfg(target_os = "linux")]
fn measure_scale(label: &str, closed_count: usize, live_count: usize) {
    let hub = scale_hub(closed_count, live_count);
    let total = closed_count + live_count;
    assert_eq!(hub.sessions().len(), total);
    // Same answers at base and head: a closed chat keeps its preview and parent, a waiting live
    // one needs input.
    let initial = Arc::new(Vec::new());
    let closed = one_watcher(&hub, &initial, 3, total);
    assert_eq!(closed["preview"], json!("A short synthetic reply over two lines"));
    assert_eq!(closed["parent"], json!(format!("claude-code:chat-{:05}", closed_count + 3)));

    // One watcher, one batch: time, CPU and allocations on this thread.
    let rounds = 20;
    let (start, cpu) = (Instant::now(), process_cpu());
    let mut allocations = 0;
    let stable = Arc::new(Vec::new());
    for n in 0..rounds {
        let (value, made) = thread_allocations(|| one_watcher(&hub, &stable, n * 97, total));
        std::hint::black_box(value);
        allocations += made;
    }
    let wall = start.elapsed().as_secs_f64() * 1000.0 / rounds as f64;
    let cpu = (process_cpu() - cpu).as_secs_f64() * 1000.0 / rounds as f64;
    eprintln!(
        "chat activity, stable cache hit, 1 watcher: {wall:.3} wall ms/batch, {cpu:.3} CPU ms/batch, {} allocations/batch",
        allocations / rounds
    );

    // 8 watchers on every batch, as `forward` runs one task per chats-watching connection, while
    // a ninth thread resolves a live session by id over and over (the sessions map lock a peer
    // notice takes).
    let stop = Arc::new(AtomicBool::new(false));
    let contender = {
        let (hub, stop) = (hub.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut waits = Vec::new();
            let id = format!("s-{closed_count:05}");
            while !stop.load(Ordering::Relaxed) {
                let start = Instant::now();
                std::hint::black_box(hub.resolve(&id).unwrap());
                waits.push(start.elapsed());
                std::thread::yield_now();
            }
            waits
        })
    };
    let barrier = Arc::new(Barrier::new(WATCHERS + 1));
    let changes = Arc::new(Vec::new());
    let stable_allocations = Arc::new(AtomicUsize::new(0));
    let invalid_allocations = Arc::new(AtomicUsize::new(0));
    let watchers: Vec<_> = (0..WATCHERS)
        .map(|w| {
            let (hub, barrier, changes, stable_allocations, invalid_allocations) = (
                hub.clone(),
                barrier.clone(),
                changes.clone(),
                stable_allocations.clone(),
                invalid_allocations.clone(),
            );
            std::thread::spawn(move || {
                for batch in 0..BATCHES * 2 {
                    barrier.wait();
                    let (_, made) =
                        thread_allocations(|| one_watcher(&hub, &changes, batch * 31 + w, total));
                    let counter =
                        if batch < BATCHES { &stable_allocations } else { &invalid_allocations };
                    counter.fetch_add(made, Ordering::Relaxed);
                    barrier.wait();
                }
            })
        })
        .collect();
    let mut stable_batches = Vec::new();
    let mut invalid_batches = Vec::new();
    let cpu_start = process_cpu();
    let mut cpu_split = None;
    for batch in 0..BATCHES * 2 {
        let start = Instant::now();
        if batch >= BATCHES {
            // A mux activity record is the one-chat mutation that invalidates the batch. The
            // benchmark uses the cache's production mutation hook so the watchers see its version.
            hub.chat_activity_cache.note(&format!("s-{closed_count:05}"), "status", false);
        }
        barrier.wait();
        barrier.wait();
        if batch == BATCHES {
            cpu_split = Some(process_cpu());
        }
        if batch < BATCHES {
            stable_batches.push(start.elapsed());
        } else {
            invalid_batches.push(start.elapsed());
        }
    }
    let cpu_end = process_cpu();
    for watcher in watchers {
        watcher.join().unwrap();
    }
    stop.store(true, Ordering::Relaxed);
    let mut waits = contender.join().unwrap();
    stable_batches.sort();
    invalid_batches.sort();
    waits.sort();
    eprintln!(
        "chat activity, {label} sessions, {WATCHERS} watchers, stable hit: p50 {:.3} ms, p99 {:.3} ms, {:.3} CPU ms/batch, {} allocations/batch",
        percentile(&stable_batches, 0.5) / 1000.0,
        percentile(&stable_batches, 0.99) / 1000.0,
        (cpu_split.unwrap() - cpu_start).as_secs_f64() * 1000.0 / BATCHES as f64,
        stable_allocations.load(Ordering::Relaxed) / BATCHES / WATCHERS,
    );
    eprintln!(
        "chat activity, {label} sessions, {WATCHERS} watchers, invalidated batch: p50 {:.3} ms, p99 {:.3} ms, {:.3} CPU ms/batch, {} allocations/batch",
        percentile(&invalid_batches, 0.5) / 1000.0,
        percentile(&invalid_batches, 0.99) / 1000.0,
        (cpu_end - cpu_split.unwrap()).as_secs_f64() * 1000.0 / BATCHES as f64,
        invalid_allocations.load(Ordering::Relaxed) / BATCHES / WATCHERS,
    );
    eprintln!(
        "session resolve under {WATCHERS} watchers: p50 {:.1} us, p99 {:.1} us, max {:.1} us, n {}",
        percentile(&waits, 0.5),
        percentile(&waits, 0.99),
        percentile(&waits, 1.0),
        waits.len(),
    );
}
