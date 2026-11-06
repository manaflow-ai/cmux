//! A measurement, not a check: how long Fork Conversation (`acp.session.fork`) takes to answer
//! on a Claude chat of `FORK_LATENCY_EVENTS` log records (default 2000, 20000 and 60000), on the
//! disk store, `FORK_LATENCY_RUNS` (default 5) forks each. The answer is what the pane waits
//! for before it opens the fork (Leo, 2026-11-06: "it's so SLOW").
//! `cargo test -p acpmux --test hub_integration fork_latency -- --ignored --nocapture`

use super::*;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn fork_latency() {
    let var = |k: &str| std::env::var(k).ok();
    let sizes: Vec<usize> = var("FORK_LATENCY_EVENTS")
        .map(|v| v.split(',').filter_map(|n| n.trim().parse().ok()).collect())
        .unwrap_or_else(|| vec![2_000, 20_000, 60_000]);
    let runs: usize = var("FORK_LATENCY_RUNS").and_then(|v| v.parse().ok()).unwrap_or(5);
    for size in sizes {
        let root = std::env::temp_dir().join(format!("acpmux-fork-bench-{}", uuid::Uuid::now_v7()));
        let claude = root.join("claude");
        std::fs::create_dir_all(&claude).unwrap();
        let (hub, mut c) = disk_claude_setup(&root, &claude).await;
        let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await;
        let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
        for text in ["first".to_owned(), format!("burst: {size}")] {
            let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
            c.request(method::SESSION_PROMPT, prompt).await.unwrap();
        }
        let events = hub.session_summary(&hub.resolve(&id).unwrap())["eventCount"].clone();
        for (label, params) in [
            ("live", json!({"sessionId": id, "live": true})),
            ("reply", json!({"sessionId": id, "throughSeq": last_turn_result(&hub, &id)})),
        ] {
            let mut took = Vec::with_capacity(runs);
            for _ in 0..runs {
                let started = std::time::Instant::now();
                let f = c.request(FORK_OP, params.clone()).await.unwrap();
                took.push(started.elapsed());
                let fid = f["sessionId"].as_str().unwrap().to_owned();
                // The fork holds the chat's history, whenever it reads it.
                assert!(!hub.events(&fid, 0, 10).unwrap().is_empty());
            }
            took.sort();
            let at =
                |q: f64| took[((took.len() as f64 * q).ceil() as usize).clamp(1, took.len()) - 1];
            println!(
                "fork_latency {label}: events={events} runs={runs} p50={:?} p95={:?} max={:?}",
                at(0.50),
                at(0.95),
                took[took.len() - 1]
            );
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
}

fn last_turn_result(hub: &Arc<Hub>, id: &str) -> u64 {
    let mut after = 0;
    let mut last = 0;
    loop {
        let page = hub.events(id, after, 1000).unwrap();
        let Some(end) = page.last() else { return last };
        after = end.seq;
        if let Some(r) = page.iter().rev().find(|e| e.kind == "turn_result") {
            last = r.seq;
        }
    }
}

/// [`super::claude_setup`] on the disk store under `root`, as a real daemon keeps it.
async fn disk_claude_setup(
    root: &std::path::Path,
    claude: &std::path::Path,
) -> (Arc<Hub>, TestClient) {
    let fake_claude = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
    let env =
        BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), claude.to_string_lossy().into_owned())]);
    let profile = HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), fake_claude.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("claude".to_owned(), profile)]),
        default_harness: Some("claude".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store_root = root.join("store");
    std::fs::create_dir_all(&store_root).unwrap();
    let store = acpmux::store::open(&cfg.store, &store_root).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(1 << 16);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    (hub, c)
}
