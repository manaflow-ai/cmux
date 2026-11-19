//! Bench (`#[ignore]`): the acpmux reads the cmux NEXT app waits on at launch, at 5 and at 500
//! chats (a dogfood daemon held 524 on 2026-11-19), 90% of them closed, each with a session.json
//! shaped like a real one (about 5 KB: agent info, capabilities, modes, config options, models,
//! usage, last turn) and a small event log.
//! - `store_list`: `LocalStore::list` on a new store (what a daemon start reads first).
//! - `hub_load_deferred`: `Hub::new_deferred` on that store, which runs `load_from_store` (the
//!   daemon's hub before its ready line; the logs load after it).
//! - `hub_load_with_logs`: `Hub::new`, `load_from_store` and `load_logs`.
//! - `first_page`: the app's first page, `_acpmux/watch` with `limit: 200`
//!   (`Hub::session_page_rows` plus `serialize_in_order`, as `server/list_reply.rs` `page`).
//! - `v2_window`: the bounded v2 list window (`acpmux_core::hub::Hub::subscribe`, 100 rows), on
//!   the index the tee fills from the hub.
//!
//! Prints one `TTI-BENCH <name> sessions=<n> n=<iterations> median_ms=<ms>` line for each.
//!
//! cd cmux-tui && cargo test --release -p acpmux --lib launch_read_bench -- --ignored --nocapture

use super::*;
use crate::store::LocalStore;
use std::time::Instant;

const ITERATIONS: usize = 20;
const SIZES: [usize; 2] = [5, 500];

fn median_ms(mut times: Vec<f64>) -> f64 {
    times.sort_by(f64::total_cmp);
    times[times.len() / 2]
}

fn time<T>(mut body: impl FnMut() -> T) -> f64 {
    std::hint::black_box(body());
    let times = (0..ITERATIONS)
        .map(|_| {
            let started = Instant::now();
            std::hint::black_box(body());
            started.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    median_ms(times)
}

fn report(name: &str, sessions: usize, median: f64) {
    let profile = if cfg!(debug_assertions) { "debug" } else { "release" };
    println!(
        "TTI-BENCH {name} sessions={sessions} n={ITERATIONS} median_ms={median:.3} profile={profile}"
    );
}

/// A session.json shaped like a dogfood one: the same fields, about the same sizes.
fn meta_json(n: usize, sessions: usize) -> Value {
    let status = if n < sessions.div_ceil(10) { "idle" } else { "closed" };
    let option = |id: &str| {
        json!({"id": id, "name": id, "type": "select", "currentValue": "default",
               "options": (0..6).map(|o| json!({"value": format!("{id}-{o}"),
                   "name": format!("Option {o}"), "description": "A synthetic option description"}))
                   .collect::<Vec<_>>()})
    };
    let config_options = ["model", "effort", "mode", "sandbox"].map(option);
    json!({
        "schema": META_SCHEMA, "id": format!("01a16d59-e46e-7240-8571-{n:012}"),
        "name": format!("chat-{n}"), "harness": "codex", "harnessArgv": ["codex-acp", "--flag"],
        "family": "codex", "cwd": "/home/user/Projects/checkout",
        "agentSessionId": format!("01a16d59-e500-7251-b228-{n:012}"),
        "status": status, "createdAt": 1_792_835_970_162_u64 + n as u64,
        "updatedAt": 1_792_875_068_380_u64 + n as u64, "lastSeq": 8316, "transcriptSeq": 0,
        "agentInfo": {"name": "codex-acp", "title": "Codex", "version": "0.1.0"},
        "agentCapabilities": {"loadSession": true, "mcpCapabilities": {"http": true, "sse": false},
            "promptCapabilities": {"audio": true, "embeddedContext": true, "image": true},
            "sessionCapabilities": {"close": {}, "fork": {}, "list": {}, "resume": {}}},
        "modes": {"currentModeId": "default", "availableModes": (0..4).map(|m| json!({
            "id": format!("mode-{m}"), "name": format!("Mode {m}"),
            "description": "A synthetic mode description of a typical length"})).collect::<Vec<_>>()},
        "configOptions": config_options,
        "models": {"currentModelId": "model-a", "availableModels": (0..6).map(|m| json!({
            "modelId": format!("model-{m}"), "name": format!("Model {m}"),
            "description": "A synthetic model description"})).collect::<Vec<_>>()},
        "title": format!("A synthetic chat title of a typical length, number {n}"),
        "titleSource": "agent", "lastPrompt": "x".repeat(200), "preview": "",
        "eventCount": 8316, "turnCount": 4,
        "usage": {"sessionUpdate": "usage_update", "size": 258_400, "used": 199_670,
            "_meta": {"tokenUsage": {"last": {"inputTokens": 199_632, "outputTokens": 38},
                "total": {"inputTokens": 22_505_375, "outputTokens": 40_704}}}},
        "lastTurn": {"endedAt": 1_792_875_068_380_u64, "promptId": format!("p-{n}"),
            "status": "completed", "stopReason": "end_turn", "turnId": format!("t-{n}")},
        "tools": {"mutable": false, "off": ["tool:AskUserQuestion"]},
    })
}

/// A store on a new temporary directory with `sessions` chats and a small log each.
fn store_dir(sessions: usize) -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    let store = LocalStore::new(dir.path().to_path_buf(), 1 << 20).unwrap();
    for n in 0..sessions {
        let meta: SessionMeta = serde_json::from_value(meta_json(n, sessions)).unwrap();
        Store::save(&store, &meta).unwrap();
        for seq in 1..=8_u64 {
            let record = EventRecord {
                seq,
                at: seq,
                dir: "in".into(),
                kind: if seq == 8 { "turn_result".into() } else { "agent_message_chunk".into() },
                msg: json!({"text": "a synthetic agent message chunk of a typical length"}),
                host_seq: None,
            };
            Store::append(&store, &meta.id, &record).unwrap();
        }
    }
    Store::flush(&store).unwrap();
    dir
}

fn config() -> Config {
    serde_json::from_value(json!({})).unwrap()
}

#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn launch_read_bench() {
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    for sessions in SIZES {
        let dir = store_dir(sessions);
        let root = dir.path().to_path_buf();
        let open = || LocalStore::new(root.clone(), 1 << 20).unwrap();
        assert_eq!(Store::list(&open()).unwrap().len(), sessions);

        report("store_list", sessions, time(|| Store::list(&open()).unwrap().len()));
        report(
            "hub_load_deferred",
            sessions,
            time(|| Hub::new_deferred(config(), Box::new(open()), Mailbox::memory())),
        );
        report("hub_load_with_logs", sessions, time(|| Hub::new(config(), Box::new(open()))));

        let hub = Hub::new(config(), Box::new(open()));
        assert_eq!(hub.sessions().len(), sessions);
        let params = json!({"enabled": true, "limit": 200});
        report(
            "first_page",
            sessions,
            time(|| {
                let (built, _) = hub.session_page_rows(&params, false).unwrap();
                crate::hub::list_guard::serialize_in_order(&built)
            }),
        );
        drop(hub);

        // The v2 index the tee fills from the same rows (memory store: the window reads the
        // index, never the store).
        let window = runtime.block_on(async {
            let metas = Store::list(&open()).unwrap();
            let daemon = crate::test_support::list_daemon::serve(
                crate::test_support::list_daemon::Serves::List,
                move |hub| {
                    let count = metas.len();
                    for meta in metas {
                        crate::test_support::list_daemon::insert(hub, meta);
                    }
                    count
                },
            )
            .await
            .unwrap();
            let v2 = daemon.v2.clone().unwrap();
            let sub = acpmux_core::wire::Sub::new("bench", "list");
            let median = time(|| v2.hub.subscribe(&sub).unwrap().window);
            drop(daemon);
            median
        });
        report("v2_window", sessions, window);
    }
}
