//! The owned-tasks number (cmuxterm-hq#9096, proposal 2): open and close 50 chats on one hub,
//! then shut the hub down as the daemon does and drop it, counting the runtime's live tasks and
//! this process's live descendant processes before the hub and after each step. Everything the
//! hub started must be gone once it is: no task parked on a wake nobody sends, no agent process
//! left running or unreaped.
//!
//! `cargo test -p acpmux --lib owned_scope_bench_tests -- --ignored --exact --nocapture
//! hub::owned_scope_bench_tests::open_and_close_50_chats_then_the_hub_leaves_no_task_or_process`
//! (Linux: the processes are read from /proc). It prints one `owned-scope-bench` line.

use super::*;
use std::time::Duration;

const CYCLES: usize = 50;

/// How long the tasks and processes the shutdown ended get to finish ending.
const SETTLE: Duration = Duration::from_secs(3);

fn live_tasks() -> usize {
    tokio::runtime::Handle::current().metrics().num_alive_tasks()
}

/// This process's descendants (zombies too: an unreaped child is a leak as well), from /proc.
fn descendants() -> usize {
    let me = std::process::id();
    let mut parent_of = HashMap::new();
    let Ok(entries) = std::fs::read_dir("/proc") else { return 0 };
    for entry in entries.flatten() {
        let Some(pid) = entry.file_name().to_str().and_then(|n| n.parse::<u32>().ok()) else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else { continue };
        // `pid (comm) state ppid ...`: the fields after the last `)`.
        let ppid = stat
            .rsplit_once(')')
            .and_then(|(_, rest)| rest.split_whitespace().nth(1))
            .and_then(|ppid| ppid.parse::<u32>().ok());
        if let Some(ppid) = ppid {
            parent_of.insert(pid, ppid);
        }
    }
    parent_of
        .keys()
        .filter(|&&pid| {
            let mut at = pid;
            for _ in 0..64 {
                match parent_of.get(&at) {
                    Some(&ppid) if ppid == me => return true,
                    Some(&ppid) if ppid > 1 => at = ppid,
                    _ => return false,
                }
            }
            false
        })
        .count()
}

/// Wait (by short sleeps: these are other tasks' and processes' ends, with no one event to wait
/// on) until both counts are at most the baseline's, or [`SETTLE`] passes. The last counts.
async fn settle(tasks: usize, children: usize) -> (usize, usize) {
    let deadline = tokio::time::Instant::now() + SETTLE;
    loop {
        let now = (live_tasks(), descendants());
        if (now.0 <= tasks && now.1 <= children) || tokio::time::Instant::now() >= deadline {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "bench: spawns 50 stand-in agents (owned-scope-bench)"]
async fn open_and_close_50_chats_then_the_hub_leaves_no_task_or_process() {
    use crate::config::{Config, StoreMode};
    let (tasks_before, children_before) = (live_tasks(), descendants());
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (mut tasks_open_max, mut children_open_max) = (0, 0);
    for _ in 0..CYCLES {
        let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let session = hub.new_session(req).await.unwrap();
        tasks_open_max = tasks_open_max.max(live_tasks());
        children_open_max = children_open_max.max(descendants());
        hub.kill(&session, false).await.unwrap();
    }
    let (tasks_closed, children_closed) = (live_tasks(), descendants());

    // The daemon's shutdown order (`daemon.rs`): the fence, the idle reaper and peer notices,
    // the agents and the seal, then the hub's own tasks.
    hub.begin_shutdown();
    hub.stop_idle_reaper();
    let _ = hub.shutdown_all().await;
    hub.close_owned_tasks().await;
    let hub_refs = Arc::strong_count(&hub);
    drop(hub);
    let (tasks_after, children_after) = settle(tasks_before, children_before).await;

    println!(
        "owned-scope-bench cycles={CYCLES} tasks_before={tasks_before} tasks_after={tasks_after} \
         children_before={children_before} children_after={children_after}"
    );
    println!(
        "owned-scope-bench detail: open max tasks={tasks_open_max} children={children_open_max}; \
         after 50 closes tasks={tasks_closed} children={children_closed}; \
         hub handles at its drop={hub_refs}"
    );
    assert!(tasks_after <= tasks_before, "the hub left {} task(s)", tasks_after - tasks_before);
    assert!(
        children_after <= children_before,
        "the hub left {} process(es)",
        children_after - children_before
    );
}
