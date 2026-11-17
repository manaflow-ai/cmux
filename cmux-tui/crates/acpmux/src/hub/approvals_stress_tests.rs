//! Pending permission requests under scale: 10, 100 and 1,000 asks waiting across 1, 50 and 200
//! agents. What a person waits on: one more ask reaching the queue, one answer, the review queue a
//! client reads (`_acpmux/review_queue`), and every session's summary with its badge
//! (`pendingPermissions`, `waitingOn`), which the sidebar's approvals and each list read carry.
//! Then every agent exits with its asks pending, and nothing of them may stay behind.
//!
//! The timing sweep runs only when asked: `CMUX_STRESS=1`, or a plain `cargo test` whose filter
//! names `stress_bench` (nextest's `--exact` run skips it). It prints one `STRESS-APPROVALS` JSON
//! line per size. The ungated tests count allocations, not time: a session's summary must cost
//! the same with 10 or 1,000 asks waiting.

use super::*;
use crate::hub::peer_snapshot::thread_allocations;
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Instant;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("stress_bench")) && !args.iter().any(|a| a == "--exact")
}

/// Microseconds, as sampled.
#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1_000_000.0);
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 10.0).round() / 10.0
        };
        json!({ "n": v.len(), "p50_us": at(0.5), "p95_us": at(0.95), "max_us": at(1.0) })
    }
}

/// A hub (memory store, `ask` policy) with `agents` sessions.
fn hub_with(agents: usize) -> (tempfile::TempDir, Arc<Hub>, Vec<Arc<Session>>) {
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().canonicalize().unwrap();
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config, store);
    let sessions = (0..agents)
        .map(|n| {
            let meta: SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": format!("agent-{n:03}"),
                "name": format!("Agent {n}"), "harness": "claude", "cwd": cwd,
                "status": "running", "createdAt": 1, "updatedAt": 1
            }))
            .unwrap();
            hub.store.save(&meta).unwrap();
            let session = hub.make_session(meta);
            // Listed, as a started chat is: the queue reads the hub's sessions.
            hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
            session
        })
        .collect();
    (dir, hub, sessions)
}

/// A tool ask of a usual size ("fetch" skips the repository barrier, so nothing waits on disk).
fn ask(session: &str, n: usize) -> Value {
    json!({"sessionId": session, "toolCall": {
    "toolCallId": format!("call-{n}"), "title": format!("Fetch https://example.invalid/{n} — ✅"),
    "kind": "fetch", "rawInput": {"url": format!("https://example.invalid/{n}"),
    "prompt": "Summarize the page in a few lines for the change under review."}},
    "options": [
        {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
        {"optionId": "allow_always", "name": "Always", "kind": "allow_always"},
        {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
    ]})
}

fn pending_len(session: &Session) -> usize {
    session.permissions.lock().unwrap().pending.len()
}

fn pending_ids(session: &Session) -> Vec<String> {
    session.permissions.lock().unwrap().pending.keys().cloned().collect()
}

/// Puts `count` asks straight into `session`'s pending map, as an asking task would (no task
/// waits on them): for the read paths alone.
fn insert_pending(session: &Session, count: usize) {
    let mut state = session.permissions.lock().unwrap();
    for n in 0..count {
        let (reply, receiver) = oneshot::channel();
        std::mem::forget(receiver);
        state.pending.insert(
            format!("perm-{n:05}"),
            PendingPermission {
                request: ask(&session.id, n),
                reply,
                decision_nonce: format!("nonce-{n}"),
                ancestor_may_answer: false,
                prev_status: SessionStatus::Running,
                agent_request: None,
                agent_host_incarnation: None,
            },
        );
    }
}

/// Raises one ask the real way (the asking task waits for its answer) and yields until it waits.
async fn raise(hub: &Arc<Hub>, session: &Arc<Session>, n: usize) -> tokio::task::JoinHandle<Value> {
    let before = pending_len(session);
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    let (hub_task, session_task) = (hub.clone(), session.clone());
    let request = ask(&session.id, n);
    let task = tokio::spawn(async move {
        hub_task.handle_permission(&session_task, request, epoch, None).await
    });
    let mut spins = 0;
    while pending_len(session) == before {
        tokio::task::yield_now().await;
        spins += 1;
        assert!(spins < 100_000, "ask {n} never reached the pending map");
    }
    task
}

async fn answer(hub: &Hub, session: &Session, id: &str) {
    hub.respond_permission(
        session,
        id,
        Some("allow_once".into()),
        None,
        None,
        person::Answerer { person: true, ..Default::default() },
        Control::Local,
    )
    .await
    .expect("the person answers a waiting ask");
}

/// The review queue page a client reads.
fn queue_page(hub: &Hub, limit: usize) -> (usize, usize) {
    let (mut items, visited) = hub.review_queue_local(crate::store::now_ms());
    let total = items.len();
    review_queue::sort_items(&mut items, limit);
    (total, visited)
}

// MARK: Ungated: counted work stays flat as asks pile up

#[test]
fn a_queue_page_builds_its_page_not_every_waiting_ask() {
    let cost = |waiting: usize| {
        let (_dir, hub, sessions) = hub_with(4);
        for session in &sessions {
            insert_pending(session, waiting / 4);
            for n in 0..waiting / 4 {
                let msg =
                    json!({"permissionId": format!("perm-{n:05}"), "request": ask(&session.id, n)});
                hub.review_index.note_ask(&session.id, &msg, 1);
            }
        }
        queue_page(&hub, 50);
        let ((total, _), made) = thread_allocations(|| queue_page(&hub, 50));
        assert_eq!(total, waiting);
        made
    };
    let page = cost(40);
    let many = cost(4_000);
    // Ranking may keep a small key per waiting ask (its id); building, copying or serializing
    // each one is what grew with the queue.
    let per_ask = (many.saturating_sub(page)) as f64 / (4_000 - 40) as f64;
    assert!(
        per_ask <= 4.0,
        "queue page: {per_ask:.1} allocations per waiting ask ({many} vs {page})"
    );
}

#[test]
fn a_summary_costs_the_same_with_a_thousand_asks_waiting() {
    let cost = |waiting: usize| {
        let (_dir, hub, sessions) = hub_with(1);
        insert_pending(&sessions[0], waiting);
        // Warm once: first reads fill caches that are not per ask.
        let first = hub.session_summary(&sessions[0]);
        assert_eq!(first["pendingPermissions"], json!(waiting));
        let (summary, made) = thread_allocations(|| hub.session_summary(&sessions[0]));
        assert_eq!(summary["pendingPermissions"], json!(waiting));
        assert_eq!(summary["waitingOn"], json!("permission"));
        made
    };
    let few = cost(10);
    let many = cost(1_000);
    // The badge is a count and `waitingOn` names one ask: no copy of each waiting request.
    assert!(many <= few + 16, "summary: {many} allocations with 1000 asks vs {few} with 10");
}

#[tokio::test]
async fn agents_that_exit_with_asks_pending_leave_nothing_behind() {
    let (_dir, hub, sessions) = hub_with(50);
    let mut tasks = Vec::new();
    for (index, session) in sessions.iter().enumerate() {
        for n in 0..4 {
            tasks.push(raise(&hub, session, index * 10 + n).await);
        }
    }
    let (total, _) = queue_page(&hub, 50);
    assert_eq!(total, 200, "every waiting ask is in the queue");
    // Every agent exits (`Inbound::Exited` drains its asks).
    for session in &sessions {
        hub.cancel_pending_permissions(session);
    }
    for task in tasks {
        let out = task.await.unwrap();
        assert_eq!(out.pointer("/outcome/outcome"), Some(&json!("cancelled")));
    }
    for session in &sessions {
        assert_eq!(pending_len(session), 0);
        assert_eq!(hub.session_summary(session)["pendingPermissions"], json!(0));
    }
    let (total, _) = queue_page(&hub, 50);
    assert_eq!(total, 0, "no ask outlives its agent in the queue");
    assert_eq!(hub.review_index.sizes().0, 0, "the queue's index holds no exited agent's asks");
}

#[test]
fn degenerate_asks_read_back() {
    let (_dir, hub, sessions) = hub_with(1);
    // No asks: no badge, no queue item.
    assert_eq!(hub.session_summary(&sessions[0])["pendingPermissions"], json!(0));
    assert_eq!(queue_page(&hub, 50).0, 0);
    // One huge ask with unicode, and a question among plain asks names the question.
    {
        let mut state = sessions[0].permissions.lock().unwrap();
        let (reply, receiver) = oneshot::channel();
        std::mem::forget(receiver);
        let mut request = ask(&sessions[0].id, 0);
        request["toolCall"]["rawInput"]["prompt"] = json!("é✅".repeat(100_000));
        state.pending.insert(
            "huge".into(),
            PendingPermission {
                request,
                reply,
                decision_nonce: "n".into(),
                ancestor_may_answer: false,
                prev_status: SessionStatus::Running,
                agent_request: None,
                agent_host_incarnation: None,
            },
        );
    }
    let summary = hub.session_summary(&sessions[0]);
    assert_eq!(summary["pendingPermissions"], json!(1));
    assert_eq!(summary["waitingOn"], json!("permission"));
}

// MARK: Gated timing sweep

#[tokio::test]
async fn stress_bench_pending_asks() {
    if !bench_selected() {
        return;
    }
    for agents in [1usize, 50, 200] {
        for waiting in [10usize, 100, 1_000] {
            let (_dir, hub, sessions) = hub_with(agents);
            let mut tasks = Vec::new();
            let mut enqueue = Samples::default();
            for n in 0..waiting {
                let session = &sessions[n % agents];
                let started = Instant::now();
                tasks.push(raise(&hub, session, n).await);
                enqueue.push(started);
            }
            let (mut resolve, mut list, mut badges, mut one_summary) =
                (Samples::default(), Samples::default(), Samples::default(), Samples::default());
            let rounds = 50.min(waiting);
            for round in 0..rounds {
                // The client's reads: the queue page and every session's summary (its badge).
                let started = Instant::now();
                std::hint::black_box(queue_page(&hub, 50));
                list.push(started);
                let started = Instant::now();
                for session in &sessions {
                    std::hint::black_box(hub.session_summary(session));
                }
                badges.push(started);
                let started = Instant::now();
                std::hint::black_box(hub.session_summary(&sessions[0]));
                one_summary.push(started);
                // Answer one ask, and another takes its place, so the queue length holds.
                let session = &sessions[round % agents];
                if let Some(id) = pending_ids(session).into_iter().next() {
                    let started = Instant::now();
                    answer(&hub, session, &id).await;
                    resolve.push(started);
                }
                tasks.push(raise(&hub, session, waiting + round).await);
            }
            // Every agent exits with its asks pending.
            let started = Instant::now();
            for session in &sessions {
                hub.cancel_pending_permissions(session);
            }
            let exit_us = started.elapsed().as_secs_f64() * 1_000_000.0;
            for task in tasks {
                let _ = task.await;
            }
            let (left, _) = queue_page(&hub, 50);
            let index_left = hub.review_index.sizes().0;
            println!(
                "STRESS-APPROVALS {}",
                json!({
                    "agents": agents, "waiting": waiting,
                    "enqueue": enqueue.summary(), "resolve": resolve.summary(),
                    "queue_page_50": list.summary(), "all_summaries": badges.summary(),
                    "one_summary": one_summary.summary(), "exit_all_us": exit_us.round(),
                    "queue_left": left, "index_left": index_left,
                })
            );
        }
    }
}
