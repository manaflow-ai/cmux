//! A prompt or steer a client sent is applied once, never lost and never twice, across a cancel,
//! a client reconnect and a daemon restart (HQ#6740: "Each prompt or steer carries a
//! client-generated id. The daemon acks on durable append. The client retries until acked, and
//! the daemon dedupes by id"). A client's retry is the same prompt under the same id with
//! `_meta.acpmux.resend` (the web pane's `resendLost`, the Mac journal); an id reused without it
//! after a restart is a new prompt (`prompt_approval.rs`).

use super::*;
use acpmux::store::EventRecord;

/// A daemon config on the fake agent whose log is on disk under `dir`, so a second `Hub` over
/// the same `dir` is the daemon after a restart.
fn on_disk(env: BTreeMap<String, String>) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env,
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Local;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn dir(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("acpmux-delivery-{name}-{}", uuid::Uuid::now_v7()))
}

/// The daemon over `dir`, and a person's client of it.
async fn daemon(cfg: &Config, dir: &std::path::Path) -> (Arc<Hub>, TestClient) {
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, dir).unwrap());
    let c = connect(&hub).await;
    (hub, c)
}

/// The records of `kind` in chat `id` that name prompt `prompt_id`.
fn naming(hub: &Arc<Hub>, id: &str, kind: &str, prompt_id: &str) -> usize {
    let records = hub.events(id, 0, 1_000_000).unwrap();
    records.iter().filter(|r| r.kind == kind && r.msg["promptId"] == prompt_id).count()
}

/// Waits until chat `id` holds a `turn_result` for prompt `prompt_id`.
async fn ran(hub: &Arc<Hub>, id: &str, prompt_id: &str) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let records = hub.events(id, 0, 1_000_000).unwrap();
        if let Some(r) =
            records.iter().find(|r| r.kind == "turn_result" && r.msg["promptId"] == prompt_id)
        {
            return r.msg.clone();
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "{prompt_id} never ran: {:?}",
            records.iter().map(|r| (&r.kind, &r.msg["promptId"])).collect::<Vec<_>>()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// Waits until chat `id` holds a `prompt_refused` for prompt `prompt_id`, and returns it.
async fn refused(hub: &Arc<Hub>, id: &str, prompt_id: &str) -> Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(30);
    loop {
        let records = hub.events(id, 0, 1_000_000).unwrap();
        if let Some(r) =
            records.iter().find(|r| r.kind == "prompt_refused" && r.msg["promptId"] == prompt_id)
        {
            return r.msg.clone();
        }
        assert!(tokio::time::Instant::now() < deadline, "{prompt_id} in {id} was never refused");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A duplicate id is applied once: the client retries a prompt it sent before the daemon
/// restarted, under the same id, and gets the first run's outcome.
#[tokio::test]
async fn a_retry_after_a_restart_is_applied_once() {
    let (cfg, dir) = (on_disk(BTreeMap::new()), dir("dup"));
    let (hub, mut c) = daemon(&cfg, &dir).await;
    let id = new_session(&mut c, "dup").await;
    let first =
        c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-dup", false)).await.unwrap();
    assert_eq!(first["stopReason"], "end_turn", "{first}");
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let (hub, mut c) = daemon(&cfg, &dir).await;
    let again =
        c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-dup", true)).await.unwrap();
    let (messages, turns) =
        (naming(&hub, &id, "user_message", "p-dup"), naming(&hub, &id, "turn_started", "p-dup"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(again["_meta"]["acpmux"]["duplicate"], true, "{again}");
    assert_eq!(again["stopReason"], "end_turn", "{again}");
    assert_eq!((messages, turns), (1, 1), "the retry ran the prompt again");
}

/// A client reconnect with an unacked send: the connection that sent the prompt closes before
/// its answer, and the client's next connection sends it again under the same id. It joins the
/// run the daemon already took, and the prompt runs once.
#[tokio::test]
async fn a_send_retried_on_a_new_connection_joins_the_run_it_already_started() {
    let (cfg, dir) = (on_disk(BTreeMap::new()), dir("reconnect"));
    let (hub, mut c) = daemon(&cfg, &dir).await;
    let id = new_session(&mut c, "reconnect").await;
    c.send(method::SESSION_PROMPT, prompt_with_id(&id, "slow", "p-lost", false)).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-lost").await;
    // The page reloaded: its socket is gone and it never read the answer.
    drop(c);
    let mut again = connect(&hub).await;
    let reply = again
        .request(method::SESSION_PROMPT, prompt_with_id(&id, "slow", "p-lost", false))
        .await
        .unwrap();
    let turns = naming(&hub, &id, "turn_started", "p-lost");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(reply["_meta"]["acpmux"]["duplicate"], true, "{reply}");
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert_eq!(turns, 1, "the retry started a second turn");
}

/// A daemon restart mid-turn, between the prompt's acceptance and its turn's start (its agent
/// was still starting): the accepted prompt runs once after the restart, by itself, and the
/// client's retry joins that run instead of running it again.
#[tokio::test]
async fn a_prompt_accepted_before_its_turn_started_runs_once_after_a_restart() {
    let (cfg, dir) = (on_disk(BTreeMap::new()), dir("cut"));
    let (hub, mut c) = daemon(&cfg, &dir).await;
    let id = new_session(&mut c, "cut").await;
    let last = hub.session_summary(&hub.resolve(&id).unwrap())["lastSeq"].as_u64().unwrap();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    // What the stopped daemon wrote: the prompt's record, acknowledged, and no turn yet.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let record = EventRecord {
        seq: last + 1,
        at: acpmux::store::now_ms(),
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": "hi", "client": "test", "promptId": "p-cut", "turnId": "t-cut", "control": "local", "cloudMobile": true}),
        host_seq: None,
    };
    store.append(&id, &record).unwrap();
    store.flush().unwrap();
    drop(store);

    let (hub, mut c) = daemon(&cfg, &dir).await;
    let _ = hub.resolve(&id).unwrap();
    hub.resume_queues();
    let result = ran(&hub, &id, "p-cut").await;
    let retry =
        c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-cut", true)).await.unwrap();
    let turns = naming(&hub, &id, "turn_started", "p-cut");
    // It went back as it came: the mobile asking-mode rule still applies to its run.
    let requeued: Vec<Value> = hub
        .events(&id, 0, 1_000_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "queued" && r.msg["promptId"] == "p-cut")
        .map(|r| r.msg)
        .collect();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result["stopReason"], "end_turn", "{result}");
    assert_eq!(retry["_meta"]["acpmux"]["duplicate"], true, "{retry}");
    assert_eq!(turns, 1, "the accepted prompt ran {turns} times");
    assert_eq!(requeued.len(), 1, "{requeued:?}");
    assert_eq!(requeued[0]["cloudMobile"], true, "{requeued:?}");
    assert_eq!(requeued[0]["restored"], "unstarted", "{requeued:?}");
}

/// cmux#37231: a prompt from the CLI's unix socket (a Cloud machine's chat relay), accepted just
/// before a daemon restart while its agent was still starting, runs after the restart in a folder
/// nobody answered the trust question for: the socket is never trust-gated, and the restart does
/// not make it so. A gated prompt (the app's pane, a Web client) cut the same way, or one from a
/// log that did not record its gate, is still held until the folder is trusted.
#[tokio::test]
async fn a_prompt_cut_by_a_restart_keeps_the_trust_gate_it_came_with() {
    let (cfg, dir) = (on_disk(BTreeMap::new()), dir("trust"));
    std::fs::create_dir_all(&dir).unwrap();
    // No agent's file and no record: every folder's trust question is open.
    let gate = acpmux::trust::Paths {
        claude_json: dir.join("claude.json"),
        codex_config: dir.join("config.toml"),
        record: dir.join("trust.json"),
        agent_home: None,
        cmux_worktrees: None,
        peer_scratch: None,
    };
    let (hub, mut c) = daemon(&cfg, &dir).await;
    hub.set_trust_gate(Some(gate.clone()));
    // The CLI's prompt runs, and its record says it was not gated.
    let probe = new_session(&mut c, "probe").await;
    let first = c
        .request(method::SESSION_PROMPT, prompt_with_id(&probe, "hi", "p-first", false))
        .await
        .unwrap();
    assert_eq!(first["stopReason"], "end_turn", "{first}");
    let logged = hub
        .events(&probe, 0, 1_000_000)
        .unwrap()
        .into_iter()
        .find(|r| r.kind == "user_message" && r.msg["promptId"] == "p-first")
        .unwrap();
    assert_eq!(logged.msg["trustGate"], false, "{}", logged.msg);
    // Each cut prompt is its chat's first: no turn of it ran yet (`trust_gate.rs` `running`).
    let cli = new_session(&mut c, "cli").await;
    let gated = new_session(&mut c, "gated").await;
    let legacy = new_session(&mut c, "legacy").await;
    let last =
        |id: &str| hub.session_summary(&hub.resolve(id).unwrap())["lastSeq"].as_u64().unwrap();
    let seqs = [last(&cli), last(&gated), last(&legacy)];
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    // What the stopped daemon wrote for each: the prompt, acknowledged, and no turn yet.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let cut = [
        (&cli, json!(false)),
        (&gated, json!(true)),
        // A log from before `user_message` recorded the gate.
        (&legacy, Value::Null),
    ];
    for ((id, gate), seq) in cut.iter().zip(seqs) {
        let mut msg = json!({"text": "hi", "client": "test", "promptId": "p-cut", "turnId": "t-cut", "control": "local"});
        if !gate.is_null() {
            msg["trustGate"] = gate.clone();
        }
        let record = EventRecord {
            seq: seq + 1,
            at: acpmux::store::now_ms(),
            dir: "mux".into(),
            kind: "user_message".into(),
            msg,
            host_seq: None,
        };
        store.append(id, &record).unwrap();
    }
    store.flush().unwrap();
    drop(store);

    let (hub, _c) = daemon(&cfg, &dir).await;
    hub.set_trust_gate(Some(gate));
    for id in [&cli, &gated, &legacy] {
        let _ = hub.resolve(id).unwrap();
    }
    hub.resume_queues();
    let result = ran(&hub, &cli, "p-cut").await;
    let held = [refused(&hub, &gated, "p-cut").await, refused(&hub, &legacy, "p-cut").await];
    let refused_cli = naming(&hub, &cli, "prompt_refused", "p-cut");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result["stopReason"], "end_turn", "{result}");
    assert_eq!(refused_cli, 0, "the CLI's prompt was held on the folder's trust question");
    for msg in held {
        assert_eq!(msg["data"]["reason"], "trust.pending", "{msg}");
    }
}

/// Cancel during a steer: the person steers into the running turn, then Stops it. The steer
/// settles with the stopped turn, and its retry after a restart (the page never saw the answer)
/// is answered from the log: it is not run again as a prompt of its own.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_steer_into_a_stopped_turn_is_not_run_again_by_its_retry() {
    let env = BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())]);
    let (cfg, dir) = (on_disk(env), dir("steer"));
    let (hub, mut c) = daemon(&cfg, &dir).await;
    let id = new_session(&mut c, "steer").await;
    let steer = |resend: bool| {
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "also this"}],
            "_meta": {"acpmux": {"promptId": "p-steer", "steer": true, "resend": resend}}})
    };
    c.send(method::SESSION_PROMPT, prompt_with_id(&id, "until-cancel", "p-run", false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    // The steer's own answer, not the turn's "steer: also this" update, says the agent read it:
    // the answer (`steered`) comes on the request's reply path and can reach this client before
    // the update does, and a wait for the update passed over it (a base red under load: the
    // reply was never seen again, "timeout waiting for response").
    let sent = c.send(method::SESSION_PROMPT, steer(false)).await;
    let (answer, _) = c.response(sent).await;
    hub.cancel(&hub.resolve(&id).unwrap()).await.expect("the Stop is refused");
    ran(&hub, &id, "p-run").await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let (hub, mut c) = daemon(&cfg, &dir).await;
    let retry = c.request(method::SESSION_PROMPT, steer(true)).await;
    let (messages, turns) = (
        naming(&hub, &id, "user_message", "p-steer"),
        naming(&hub, &id, "turn_started", "p-steer"),
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    let answer = answer.expect("the steer failed");
    let retry = retry.expect("the retry failed");
    assert_eq!(retry["_meta"]["acpmux"]["duplicate"], true, "{retry}");
    // The first answer was the agent's `steered`; the retry answers for the turn it went into,
    // which the Stop ended.
    assert_eq!(retry["stopReason"], "cancelled", "{retry}");
    assert_eq!(
        retry["_meta"]["acpmux"]["turnId"], answer["_meta"]["acpmux"]["turnId"],
        "{retry} vs {answer}"
    );
    assert_eq!((messages, turns), (1, 0), "the steer's retry ran it again");
}
