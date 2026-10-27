//! A daemon restart on a home with hundreds of stored chats reattaches the agents that kept
//! running before it reads the other chats' logs (claude-sr2, 2026-10-26: "After each restart,
//! the daemon reads all 685 sessions' logs (453 of them closed) before it reattaches any agent.
//! For about 3–7 minutes every live session shows idle and the daemon reports 0 live agents,
//! while the agents keep working ... Fix: reattach running and waiting sessions first, from a
//! small index, and load closed or idle sessions' logs lazily").
//!
//! The harness: a daemon starts `ACPMUX_REATTACH_LIVE` chats whose turns wait on a FIFO, stops
//! the way an update stops it (their agents outlive it), and the store gets
//! `ACPMUX_REATTACH_CLOSED` closed and `ACPMUX_REATTACH_IDLE` idle chats with
//! `ACPMUX_REATTACH_RECORDS` records each. `ACPMUX_TEST_SCAN_DELAY_MS` (debug builds) holds
//! each log scan of the store, as a slow disk or a long log does. The test prints
//! `acpmux-reattach: {...}`: the time from the daemon's start to every live agent reattached
//! (each live chat shows its turn and `liveAgents` counts it), and how long an idle chat's
//! first open took.

use super::*;
use acpmux::config::{Config, StoreMode};
use acpmux::store::{EventRecord, META_SCHEMA, SessionMeta};

fn env_or(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn record(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord {
        seq,
        at: 1_791_540_000_000 + seq,
        dir: dir.into(),
        kind: kind.into(),
        msg,
        host_seq: None,
    }
}

/// Writes a stored chat with `records` records: turns of agent output, each settled, so a
/// restart finds nothing to resume in it.
fn stored_chat(store: &dyn acpmux::store::Store, id: &str, cwd: &Path, status: &str, records: u64) {
    let chunk = "x".repeat(240);
    let mut seq = 0;
    while seq < records {
        let turn = format!("t-{seq}");
        seq += 1;
        store.append(id, &record(seq, "mux", "turn_started", json!({"turnId": turn, "promptId": format!("p-{seq}"), "prompt": "go", "client": "cli"}))).unwrap();
        for _ in 0..48 {
            seq += 1;
            let update = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}});
            let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id, "update": update}});
            store.append(id, &record(seq, "in", "update", msg)).unwrap();
        }
        seq += 1;
        store
            .append(
                id,
                &record(seq, "mux", "turn_result", json!({"turnId": turn, "status": "completed"})),
            )
            .unwrap();
    }
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "fake", "cwd": cwd,
        "status": status, "createdAt": 1, "updatedAt": 1, "lastSeq": seq, "eventCount": seq,
    }))
    .unwrap();
    store.save(&meta).unwrap();
}

/// Live chats reattach within the budget however many other chats the store holds, and an
/// idle chat opened while the rest still load answers without waiting for them.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restart_reattaches_live_agents_before_reading_the_other_chats_logs() {
    let live = env_or("ACPMUX_REATTACH_LIVE", 3) as usize;
    let idle = env_or("ACPMUX_REATTACH_IDLE", 100);
    let closed = env_or("ACPMUX_REATTACH_CLOSED", 450);
    let records = env_or("ACPMUX_REATTACH_RECORDS", 500);
    let scan_delay_ms = env_or("ACPMUX_REATTACH_SCAN_DELAY_MS", 100);
    let budget_ms = env_or("ACPMUX_REATTACH_BUDGET_MS", 4_000) as u128;
    // An idle chat's first open reads that chat's log only.
    let open_budget_ms = env_or("ACPMUX_REATTACH_OPEN_BUDGET_MS", 1_500) as u128;

    let mut daemon = Daemon::new("rt", "approve-all");
    let mut live_ids = Vec::new();
    let mut clients = Vec::new();
    for _ in 0..live {
        let mut rpc = daemon.rpc().await;
        let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
        let session = created["sessionId"].as_str().unwrap().to_owned();
        let gate = daemon.home.join(format!("gate-{session}"));
        make_fifo(&gate);
        let text = format!("gate: {}", gate.display());
        rpc.send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
        daemon.wait_event(&session, "before-gate chunk", |e| {
            e["msg"]["params"]["update"]["content"]["text"] == "before-gate"
        });
        live_ids.push(session);
        clients.push(rpc);
    }
    daemon.sigterm();
    drop(clients);

    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Local;
    let mut idle_ids = Vec::new();
    {
        let store = acpmux::store::open(&cfg.store, &daemon.home).unwrap();
        for i in 0..closed {
            let id = format!("01a15800-0000-7000-8000-{i:012}");
            stored_chat(&*store, &id, &daemon.home, "closed", records);
        }
        for i in 0..idle {
            let id = format!("01a15800-0000-7000-9000-{i:012}");
            stored_chat(&*store, &id, &daemon.home, "idle", records);
            idle_ids.push(id);
        }
        store.flush().unwrap();
    }

    daemon.env = vec![("ACPMUX_TEST_SCAN_DELAY_MS".into(), scan_delay_ms.to_string())];
    let started = Instant::now();
    daemon.start();
    let ready_ms = started.elapsed().as_millis();
    let mut rpc = daemon.rpc().await;
    let deadline = Instant::now() + Duration::from_secs(600);
    let reattach_ms = loop {
        let status = rpc.call("_acpmux/status", json!({})).await;
        let all = rpc.call("_acpmux/sessions", json!({})).await;
        let running = live_ids
            .iter()
            .filter(|id| {
                all["sessions"].as_array().into_iter().flatten().any(|s| {
                    s["sessionId"] == id.as_str() && !s["turn"].is_null() && s["status"] != "idle"
                })
            })
            .count();
        if status["liveAgents"].as_u64() == Some(live as u64) && running == live {
            break started.elapsed().as_millis();
        }
        assert!(Instant::now() < deadline, "the live agents never reattached: {status:#}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    // An idle chat's first open, while the others may still be loading.
    let opened = Instant::now();
    let last_idle = idle_ids.last().cloned().unwrap_or_else(|| live_ids[0].clone());
    let attached = rpc.call("_acpmux/attach", json!({"sessionId": last_idle, "limit": 0})).await;
    let open_ms = opened.elapsed().as_millis();
    assert!(attached["session"]["queue"].is_array(), "{attached:#}");
    println!(
        "acpmux-reattach: {}",
        json!({"live": live, "idle": idle, "closed": closed, "records_per_chat": records,
               "scan_delay_ms": scan_delay_ms, "ready_ms": ready_ms, "reattach_ms": reattach_ms,
               "idle_open_ms": open_ms, "budget_ms": budget_ms})
    );

    // The adopted turns still end normally.
    for id in &live_ids {
        std::fs::write(daemon.home.join(format!("gate-{id}")), b"go").unwrap();
    }
    for id in &live_ids {
        daemon.wait_event(id, "turn_result", |e| {
            e["kind"] == "turn_result" && e["msg"]["status"] == "completed"
        });
    }
    assert!(
        reattach_ms <= budget_ms,
        "the live agents reattached {reattach_ms} ms after the start over {closed} closed and {idle} idle chats (budget {budget_ms} ms)"
    );
    assert!(
        open_ms <= open_budget_ms,
        "an idle chat's first open took {open_ms} ms while the other logs loaded (budget {open_budget_ms} ms)"
    );
}

/// Starts a chat whose turn waits on a FIFO and stops the daemon the way an update does (the
/// agent outlives it); the next start holds its log load and adoption 3 s
/// (`ACPMUX_TEST_DELAY_LOAD_LOGS_MS`). Returns the chat and its gate.
async fn kept_turn(daemon: &mut Daemon) -> (String, PathBuf) {
    let mut rpc = daemon.rpc().await;
    let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let gate = daemon.home.join(format!("gate-{session}"));
    make_fifo(&gate);
    let text = format!("gate: {}", gate.display());
    rpc.send(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
    )
    .await;
    daemon.wait_event(&session, "before-gate chunk", |e| {
        e["msg"]["params"]["update"]["content"]["text"] == "before-gate"
    });
    daemon.sigterm();
    drop(rpc);
    daemon.env = vec![("ACPMUX_TEST_DELAY_LOAD_LOGS_MS".into(), "3000".into())];
    (session, gate)
}

/// The seq of the first record `pred` accepts.
fn seq_of(events: &[Value], pred: impl Fn(&Value) -> bool) -> Option<u64> {
    events.iter().find(|e| pred(e)).and_then(|e| e["seq"].as_u64())
}

/// A prompt sent to a chat whose agent still runs, while the restarted daemon has not adopted
/// it yet, waits for adoption and queues behind the turn adoption recovers. Read on demand
/// before adoption, its chat's log let it take the turn first, and it went to the agent while
/// the recovered turn still ran (review of the lazy load).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_prompt_sent_before_adoption_queues_behind_the_adopted_turn() {
    let mut daemon = Daemon::new("rq", "approve-all");
    let (session, gate) = kept_turn(&mut daemon).await;
    let cut = daemon
        .events(&session)
        .into_iter()
        .find(|e| e["kind"] == "turn_started")
        .and_then(|e| e["msg"]["turnId"].as_str().map(str::to_owned))
        .expect("the gated turn started");
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "after adoption"}],
                        "_meta": {"acpmux": {"promptId": "p-after"}}});
    rpc.send("session/prompt", prompt).await;
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    tokio::time::sleep(Duration::from_millis(500)).await;
    std::fs::write(&gate, b"go").unwrap();
    daemon.wait_event(&session, "p-after's turn result", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "p-after"
    });
    let events = daemon.events(&session);
    let ended =
        seq_of(&events, |e| e["kind"] == "turn_result" && e["msg"]["turnId"] == cut.as_str())
            .expect("the adopted turn ended");
    let started =
        seq_of(&events, |e| e["kind"] == "turn_started" && e["msg"]["promptId"] == "p-after")
            .expect("p-after started");
    assert!(
        started > ended,
        "p-after started (seq {started}) before the adopted turn ended (seq {ended})"
    );
}

/// A chat whose agent host ran when the restarted daemon read its index, and ended before
/// adoption reached it: the chat does not stay "running" with no agent. Its cut turn settles
/// `outcome_unknown` and its continuation runs, as for any chat whose agent died with the daemon.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_host_that_ends_before_adoption_settles_its_chat() {
    let mut daemon = Daemon::new("rd", "approve-all");
    let (session, _gate) = kept_turn(&mut daemon).await;
    let record: Value = serde_json::from_slice(
        &std::fs::read(daemon.home.join("hosts").join(format!("{session}.json"))).unwrap(),
    )
    .unwrap();
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let listed = rpc.call("_acpmux/sessions", json!({})).await;
    let entry = listed["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == session.as_str())
        .cloned();
    assert_eq!(entry.as_ref().map(|e| e["status"].clone()), Some(json!("running")), "{entry:?}");
    // The host and its agent end inside the 3 s hold, before adoption.
    for pid in [record["harness_pid"].as_i64(), record["host_pid"].as_i64()].into_iter().flatten() {
        // SAFETY: process groups this test's daemon created.
        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
    }
    // Its log is read on demand while it still counts as hosted (no cut turn settled then),
    // and a prompt comes before adoption: the settling after adoption still settles the cut
    // turn, and its continuation runs ahead of the prompt.
    rpc.call("_acpmux/info", json!({"sessionId": session})).await;
    let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": "after the settle"}],
                        "_meta": {"acpmux": {"promptId": "p-new"}}});
    rpc.send("session/prompt", prompt).await;
    daemon.wait_event(&session, "outcome_unknown", |e| {
        e["kind"] == "turn_result" && e["msg"]["detail"] == "outcome_unknown"
    });
    daemon.wait_event(&session, "p-new's turn result", |e| {
        e["kind"] == "turn_result" && e["msg"]["promptId"] == "p-new"
    });
    let events = daemon.events(&session);
    let resumed = |e: &Value| e["msg"]["promptId"].as_str().is_some_and(|p| p.contains("~resume-"));
    let continued = seq_of(&events, |e| e["kind"] == "turn_started" && resumed(e))
        .expect("the continuation started");
    let new = seq_of(&events, |e| e["kind"] == "turn_started" && e["msg"]["promptId"] == "p-new")
        .expect("p-new started");
    assert!(continued < new, "p-new (seq {new}) ran ahead of the continuation (seq {continued})");
}
