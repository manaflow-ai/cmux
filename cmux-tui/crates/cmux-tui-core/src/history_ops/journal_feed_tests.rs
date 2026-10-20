//! The history feed reads the journal off the registry lock (daemon slow
//! tab writes, 2026-10-20). On a restart its cursor starts at 0, behind the
//! shared journal's in-memory window, so it reads the journal from SQLite.
//! The live app daemon's journal held 4.57M records in 4,527 gzip segments
//! (7 GB unpacked): read through the registry connection, every 512-record
//! page held the registry lock about 53 ms, 36% of the daemon's uptime,
//! and every write (`tab.update`: Cmd-Opt-U) queued behind it (lock wait
//! p50 98 ms, p99 2.6 s).

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use cmux_history::HistoryKind;
use serde_json::{Value, json};

use super::{catch_up, page};
use crate::mux::ProviderWorkspaceState;
use crate::resource::TerminalPublicId;
use crate::resource_router::handle_resource_message;
use crate::workspace_registry::WorkspaceRegistry;
use crate::{Mux, SurfaceOptions};

/// A temp state root removed on drop.
struct Root(PathBuf);

impl Root {
    fn new(name: &str) -> Self {
        Self(
            std::env::temp_dir().join(format!(
                "cmux-history-feed-{name}-{}",
                crate::workspace_registry::new_uuid_v4()
            )),
        )
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn open(session: &str, root: &Path) -> Arc<Mux> {
    let registry = WorkspaceRegistry::open(root, session).unwrap();
    Mux::from_workspace_registry(
        session.to_owned(),
        SurfaceOptions::default(),
        registry,
        ProviderWorkspaceState::default(),
        true,
    )
    .unwrap()
}

fn append_agent_hook(mux: &Arc<Mux>, terminal: &TerminalPublicId, session_id: &str) {
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        "SessionStart",
        Some(terminal.as_str()),
        json!({ "session_id": session_id }),
    )
    .unwrap();
    let key = format!("history-feed-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// `count` terminal output records of `bytes` bytes each, one per flush.
fn append_output(mux: &Mux, terminal: &TerminalPublicId, count: usize, bytes: usize) {
    let terminal = Arc::new(terminal.clone());
    for index in 0..count {
        let line = format!("{index:08} {}\r\n", "x".repeat(bytes.saturating_sub(11)));
        mux.journal_terminal_output(terminal.clone(), Arc::from("history-feed"), line.into_bytes());
        mux.flush_terminal_journal().unwrap();
    }
}

/// Checkpoint and seal the whole journal into gzip segments, as journal
/// maintenance does on a long-running daemon.
fn seal(mux: &Mux, key: &str) {
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("{key}_checkpoint")).unwrap();
    let sealed = mux
        .seal_journal_segments(
            checkpoint.checkpoint.source_sequence,
            "client_test",
            &format!("{key}_seal"),
        )
        .unwrap();
    assert!(!sealed.segments.is_empty(), "the journal sealed into segments");
}

/// A session whose sealed journal holds terminal output around one agent
/// session start, reopened like a daemon restart: the history cursor is 0
/// and the shared journal's window starts after the stored head.
fn restarted_session(name: &'static str, root: &Path, outputs: usize, bytes: usize) -> Arc<Mux> {
    let mux = open(name, root);
    let surface = mux.new_workspace(None, None).unwrap();
    let terminal = surface.terminal_public_id().cloned().expect("workspace terminal");
    append_output(&mux, &terminal, outputs / 2, bytes);
    append_agent_hook(&mux, &terminal, "history-feed-agent");
    append_output(&mux, &terminal, outputs - outputs / 2, bytes);
    seal(&mux, name);
    mux.shutdown();
    drop(mux);
    let mux = open(name, root);
    assert!(
        !matches!(
            mux.shared_journal_after(0, 1),
            crate::journal_kernel::SharedJournalRead::Page(_)
        ),
        "after a restart the shared journal window must not reach back to sequence 1"
    );
    mux
}

/// The history feed reads a journal page behind the in-memory window while
/// another thread holds the registry lock (a writer mid-commit), and the
/// catch-up still folds the agent record. (Saving the fold's cursor is a
/// short registry write after the read; it may wait for the lock.)
#[test]
fn history_feed_reads_the_journal_without_the_registry_lock() {
    let root = Root::new("lock");
    let mux = restarted_session("history-feed-lock", &root.0, 40, 64);
    let head = mux.session_journal_head().unwrap();

    let writer = mux.workspace_registry.lock().unwrap();
    let (sent, received) = mpsc::channel();
    let feed = {
        let mux = mux.clone();
        std::thread::spawn(move || {
            let _ = sent.send(page(&mux, 0).map_err(|error| format!("{error:#}")));
        })
    };
    let result = received.recv_timeout(Duration::from_secs(10));
    drop(writer);
    feed.join().unwrap();
    let (records, scanned) = result
        .expect("the history feed's journal read waited on the registry lock")
        .expect("the history feed's journal read failed");
    assert!(
        records.iter().any(|(kind, _)| *kind == HistoryKind::Agent),
        "the page holds the agent record"
    );
    assert!(scanned > 0, "the page scanned past sequence 0");

    let caught = catch_up(&mux, None).unwrap();
    assert!(caught.changed.contains(&HistoryKind::Agent), "the agent record folds");
    assert_eq!(mux.history.cursor(), head, "the feed reaches the journal head");
    mux.shutdown();
}

fn tab_update(mux: &Arc<Mux>, tab: &str, unread: bool, key: &str) -> Value {
    let envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": key,
        "operation": "tab.update",
        "idempotency_key": key,
        "params": {
            "machine": "current",
            "session": "current",
            "tab": tab,
            "marked_unread": unread,
        },
    });
    let response = handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "tab.update failed: {response}");
    response
}

fn percentile(sorted: &[f64], fraction: f64) -> f64 {
    let index = ((sorted.len() as f64 * fraction).ceil() as usize).clamp(1, sorted.len()) - 1;
    sorted[index]
}

/// Bench: `tab.update` (Cmd-Opt-U) latency while the history feed pages
/// through a sealed journal far behind its cursor (a restart), as the live
/// daemon did. It reports, it does not gate: on shared fleet Macs the p99
/// moved 141-829 ms with the feed under the registry lock and 50-125 ms
/// off it, so a p99 assert would flake; the lock test above is the gate.
/// The p99 goal is 20 ms. Writes `.build/bench/history-feed-tab-update.json`
/// at the repository root.
#[test]
fn tab_update_latency_while_the_history_feed_catches_up() {
    const WRITES: usize = 120;
    const P99_GOAL_MS: f64 = 20.0;
    let root = Root::new("bench");
    let mux = restarted_session("history-feed-bench", &root.0, 3000, 2048);
    let tab = mux.with_state(|state| {
        state.resource_indexes.tab_ids.values().next().expect("one tab").to_string()
    });

    let stop = Arc::new(AtomicBool::new(false));
    let pages = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let reader = {
        let (mux, stop, pages) = (mux.clone(), stop.clone(), pages.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                page(&mux, 0).unwrap();
                pages.fetch_add(1, Ordering::Relaxed);
            }
        })
    };
    while pages.load(Ordering::Relaxed) == 0 {
        std::thread::yield_now();
    }
    let mut samples = Vec::with_capacity(WRITES);
    for index in 0..WRITES {
        let started = Instant::now();
        tab_update(&mux, &tab, index % 2 == 0, &format!("bench-unread-{index}"));
        samples.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    stop.store(true, Ordering::Relaxed);
    reader.join().unwrap();
    samples.sort_by(f64::total_cmp);
    let (p50, p99, max) =
        (percentile(&samples, 0.50), percentile(&samples, 0.99), samples[samples.len() - 1]);
    let report = json!({
        "bench": "tab.update while the history feed pages a sealed journal",
        "writes": WRITES,
        "feed_pages": pages.load(Ordering::Relaxed),
        "p50_ms": p50,
        "p99_ms": p99,
        "max_ms": max,
        "p99_goal_ms": P99_GOAL_MS,
    });
    eprintln!("{report}");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/bench");
    if std::fs::create_dir_all(&out).is_ok() {
        let _ = std::fs::write(out.join("history-feed-tab-update.json"), report.to_string());
    }
    mux.shutdown();
    assert_eq!(samples.len(), WRITES, "every write answered");
}
