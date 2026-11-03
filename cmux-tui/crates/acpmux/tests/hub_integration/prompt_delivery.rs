//! A prompt or steer a client sent is applied once, never lost and never twice, across a cancel,
//! a client reconnect and a daemon restart (HQ#6740: "Each prompt or steer carries a
//! client-generated id. The daemon acks on durable append. The client retries until acked, and
//! the daemon dedupes by id"). A retry is the same prompt under the same id, with or without
//! `_meta.acpmux.resend`: the web pane cannot set that flag.

use super::*;
use acpmux::store::{EventRecord, Store as _};

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

/// A duplicate id is applied once: the client retries a prompt it sent before the daemon
/// restarted, under the same id and without the resend flag, and gets the first run's outcome.
#[tokio::test]
async fn a_retry_after_a_restart_without_the_resend_flag_is_applied_once() {
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
        c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-dup", false)).await.unwrap();
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
        msg: json!({"text": "hi", "client": "test", "promptId": "p-cut", "turnId": "t-cut", "control": "local"}),
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
        c.request(method::SESSION_PROMPT, prompt_with_id(&id, "hi", "p-cut", false)).await.unwrap();
    let turns = naming(&hub, &id, "turn_started", "p-cut");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(result["stopReason"], "end_turn", "{result}");
    assert_eq!(retry["_meta"]["acpmux"]["duplicate"], true, "{retry}");
    assert_eq!(turns, 1, "the accepted prompt ran {turns} times");
}

/// Cancel during a steer: the person's steer is taken, then Stop ends the turn before the agent
/// reads it. The steer settles with the stopped turn, and its retry after a restart (the page
/// never saw the answer) is answered from the log: it is not run as a new prompt.
#[tokio::test]
async fn a_steer_a_stop_cut_off_is_not_run_again_by_its_retry() {
    let step = std::env::temp_dir().join(format!("acpmux-delivery-step-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&step).status().unwrap().success());
    let env = BTreeMap::from([
        ("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned()),
        ("FAKE_STEER_STEP".to_owned(), step.display().to_string()),
    ]);
    let (cfg, dir) = (on_disk(env), dir("steer"));
    let (hub, mut c) = daemon(&cfg, &dir).await;
    let id = new_session(&mut c, "steer").await;
    let steer = |text: &str| {
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}],
            "_meta": {"acpmux": {"promptId": "p-steer", "steer": true}}})
    };
    c.send(method::SESSION_PROMPT, prompt_with_id(&id, "until-cancel", "p-run", false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let sent = c.send(method::SESSION_PROMPT, steer("also this")).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-steer").await;
    hub.cancel(&hub.resolve(&id).unwrap()).await.expect("the Stop is refused");
    let (answer, _) = tokio::time::timeout(Duration::from_secs(30), c.response(sent))
        .await
        .expect("the steer was never answered");
    ran(&hub, &id, "p-run").await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let (hub, mut c) = daemon(&cfg, &dir).await;
    let retry = c.request(method::SESSION_PROMPT, steer("also this")).await;
    let (messages, turns) = (
        naming(&hub, &id, "user_message", "p-steer"),
        naming(&hub, &id, "turn_started", "p-steer"),
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_file(&step);
    // The first answer says it did not run on: the stopped turn's, or a refusal.
    if let Ok(answer) = &answer {
        assert_eq!(answer["stopReason"], "cancelled", "{answer}");
    }
    match &retry {
        Ok(v) => assert_eq!(v["_meta"]["acpmux"]["duplicate"], true, "{v}"),
        Err(e) => assert!(answer.is_err(), "a refusal the first time only: {e:?}"),
    }
    assert_eq!((messages, turns), (1, 0), "the steer's retry ran it again");
}
