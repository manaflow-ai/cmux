//! Row 3b's gates for the tee (`benches/v2/mod.rs`), each a run of its own:
//! `cargo test --profile gate -p acpmux --lib v2_pr03b_<name> -- --ignored --nocapture`.
//!
//! - `tee_append_added`: the hook's time inside `write_record_locked`, in the god home against
//!   the small one, `books` on, each chat's book caught up first (steady state). The hook is
//!   under 100 µs, so the best p95 of five rounds, and the p95 of every sample beside it.
//! - `append_on_off`: v1's append in the god home with `books` off (the small side) against on
//!   (the god side); the hook's own time is inside it.
//! - `catchup_ack`: v1's ack of an agent host's line (`append_logged(..).1`, as the tap takes
//!   it) on a live chat while the god chat catches up from nothing, against the same with no
//!   catch-up.
//!
//! Rounds alternate between the two sides. `ACPMUX_GOD_SCALE` shrinks the god home.

use super::tests::{Home, home};
use super::*;
use crate::god_fixture::{Shape, chat_id};
use serde_json::json;
use std::time::{Duration, Instant};

const ROUNDS: usize = 5;
const APPENDS: usize = 2_000;

fn p95(values: &[u64]) -> u64 {
    let mut values = values.to_vec();
    values.sort_unstable();
    values.get((values.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap_or(0)
}

/// The best p95 of the rounds, and the p95 of every sample of them.
fn measures(rounds: &[Vec<u64>]) -> (u64, u64) {
    let best = rounds.iter().map(|round| p95(round)).min().unwrap_or(0);
    let all: Vec<u64> = rounds.iter().flatten().copied().collect();
    (best, p95(&all))
}

/// Prints the row's line (so a red run still has its numbers) and writes it to `V2_GATE_OUT`,
/// then holds the best p95 to 1.2x and, when the row has one, every sample's to `all_limit`.
fn emit(name: &str, small: &[Vec<u64>], god: &[Vec<u64>], all_limit: Option<f64>) {
    let (small_p95, small_all) = measures(small);
    let (god_p95, god_all) = measures(god);
    let line = json!({
        "name": name,
        "small_p95": small_p95,
        "god_p95": god_p95,
        "god_p95_all": god_all,
        "small_p95_all": small_all,
        "rounds": ROUNDS,
        "unit": "ns",
    })
    .to_string();
    eprintln!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(file, "{line}").unwrap();
    }
    assert!(small_p95 > 0, "{name}: small p95 is zero");
    let ratio = god_p95 as f64 / small_p95 as f64;
    assert!(ratio <= 1.2, "{name}: best p95 ratio {ratio:.3} (small {small_p95}, god {god_p95})");
    if let Some(limit) = all_limit {
        let ratio_all = god_all as f64 / small_p95 as f64;
        assert!(ratio_all <= limit, "{name}: every sample's p95 ratio {ratio_all:.3}");
    }
}

/// A home of `shape`'s chats: chat 0 is its long chat, the rest of `chat_messages` each.
async fn shaped(shape: &Shape, books: bool) -> Home {
    let mut chats = vec![(chat_id(0), shape.god_messages, shape.god_bytes)];
    chats.extend((1..shape.chats).map(|n| (chat_id(n), shape.chat_messages, 32 << 10)));
    home(&chats, books).await
}

/// The drain, running for as long as the gate: the scope owns it.
fn drained(home: &Home) -> cmux_scope::Scope {
    let (hub, tee) = (home.hub.clone(), home.tee().clone());
    let scope = cmux_scope::Scope::new("book-tee-gate");
    scope.spawn_named("drain", async move { drain(&hub, &tee).await });
    scope
}

/// Every chat of the home caught up to a book, then left to the drain.
async fn caught_up(home: &Home) {
    pass(home.hub.clone(), home.tee().clone()).await;
}

fn take_hook_samples() -> Vec<u64> {
    std::mem::take(&mut *HOOK_NS.lock().unwrap())
}

/// The hook's time is kept while this lives: a gate round that panics clears `HOOK_RECORDING`
/// as it unwinds, so no later test in the process grows the samples (cmux#43100).
struct Recording;

impl Recording {
    fn start() -> Self {
        HOOK_RECORDING.store(true, Ordering::Relaxed);
        Self
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        HOOK_RECORDING.store(false, Ordering::Relaxed);
    }
}

#[test]
fn a_panic_while_recording_clears_the_flag() {
    let panicked = std::panic::catch_unwind(|| {
        let _recording = Recording::start();
        assert!(HOOK_RECORDING.load(Ordering::Relaxed));
        panic!("a gate round failed");
    });
    assert!(panicked.is_err());
    assert!(!HOOK_RECORDING.load(Ordering::Relaxed), "the flag outlived the panic");
}

/// One round of prompts to `id`, each timed through v1's append.
fn appends(home: &Home, id: &str, round: usize) -> Vec<u64> {
    let session = home.session(id);
    (0..APPENDS)
        .map(|n| {
            let started = Instant::now();
            let (_, stored) = home.hub.append_logged(
                &session,
                "mux",
                "user_message",
                json!({ "text": format!("round {round} prompt {n}") }),
                None,
            );
            let took = started.elapsed();
            assert!(stored);
            u64::try_from(took.as_nanos()).unwrap_or(u64::MAX)
        })
        .collect()
}

/// One round of an agent host's lines to `id`, each timed to the ack the tap reads.
fn acks(home: &Home, id: &str, round: usize, host_seq: &mut u64) -> Vec<u64> {
    let session = home.session(id);
    (0..APPENDS)
        .map(|n| {
            *host_seq += 1;
            let line = json!({
                "jsonrpc": "2.0", "method": "session/update",
                "params": {"update": {"sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": format!("round {round} chunk {n}")}}},
            });
            let started = Instant::now();
            let acked =
                home.hub.append_logged(&session, "in", "session/update", line, Some(*host_seq)).1;
            let took = started.elapsed();
            assert!(acked);
            u64::try_from(took.as_nanos()).unwrap_or(u64::MAX)
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate: what the tee adds to a v1 append, god against small"]
async fn v2_pr03b_tee_append_added() {
    let small = shaped(&Shape::small(), true).await;
    let god = shaped(&Shape::god_from_env(), true).await;
    let (small_drain, god_drain) = (drained(&small), drained(&god));
    caught_up(&small).await;
    caught_up(&god).await;
    let (mut small_rounds, mut god_rounds) = (Vec::new(), Vec::new());
    take_hook_samples();
    let recording = Recording::start();
    for round in 0..ROUNDS {
        appends(&small, &chat_id(0), round);
        small_rounds.push(take_hook_samples());
        appends(&god, &chat_id(0), round);
        god_rounds.push(take_hook_samples());
    }
    drop(recording);
    let _ = small_drain.close(Duration::from_secs(1)).await;
    let _ = god_drain.close(Duration::from_secs(1)).await;
    emit("v2.pr03b.tee_append_added", &small_rounds, &god_rounds, Some(2.0));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate: v1's append with books on against off, both in the god home"]
async fn v2_pr03b_append_on_off() {
    let shape = Shape::god_from_env();
    let off = shaped(&shape, false).await;
    let on = shaped(&shape, true).await;
    let drain_task = drained(&on);
    caught_up(&on).await;
    let (mut off_rounds, mut on_rounds) = (Vec::new(), Vec::new());
    for round in 0..ROUNDS {
        off_rounds.push(appends(&off, &chat_id(0), round));
        on_rounds.push(appends(&on, &chat_id(0), round));
    }
    let _ = drain_task.close(Duration::from_secs(1)).await;
    emit("v2.pr03b.append_on_off", &off_rounds, &on_rounds, None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "release gate: v1's ack on a live chat while the god chat catches up"]
async fn v2_pr03b_catchup_ack() {
    let home = shaped(&Shape::god_from_env(), true).await;
    let tee = home.tee().clone();
    let drain_task = drained(&home);
    let (god, live) = (chat_id(0), chat_id(1));
    // The live chat follows its book; the god chat has none until a round starts its catch-up.
    tee.tell(&home.hub, &live);
    let handle = tee.registry().get(&live).unwrap();
    assert!(handle.wait_ready().await);
    let book = home.book(&god);
    let mut host_seq = 0;
    let (mut quiet_rounds, mut catching_rounds) = (Vec::new(), Vec::new());
    for round in 0..ROUNDS {
        quiet_rounds.push(acks(&home, &live, round, &mut host_seq));
        // A catch-up from nothing: the god chat's book is removed while no actor holds it.
        tee.registry().evict(&god);
        let _ = std::fs::remove_dir_all(&book);
        tee.tell(&home.hub, &god);
        let catching = tee.registry().get(&god).unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        let samples = acks(&home, &live, round, &mut host_seq);
        assert!(!catching.ready(), "round {round}: the catch-up ran through the whole round");
        catching_rounds.push(samples);
    }
    tee.registry().evict(&god);
    let _ = drain_task.close(Duration::from_secs(1)).await;
    emit("v2.pr03b.catchup_ack", &quiet_rounds, &catching_rounds, None);
}
