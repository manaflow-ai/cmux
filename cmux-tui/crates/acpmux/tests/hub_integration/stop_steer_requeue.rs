//! Another agent's message is never lost to a Stop (`hub/cancel.rs` module docs). 2026-11-02:
//! `acpmux session cancel`, then a second later `acpmux send --from coordinator` (a steer, so an
//! inbox notice into the running turn). The notice went into the cancelling turn, the agent
//! never read it, the forced end answered it (`inbox_answered` with `cancelForced`), and the chat
//! sat idle with the message unread. Now it is not answered: it starts the next turn.

use super::*;

/// `acpmux send --from AGENT`: another agent's message, steering by default.
fn from_agent(id: &str, prompt_id: &str, text: &str, steer: bool) -> Value {
    let meta = json!({"promptId": prompt_id, "fromAgent": "coordinator", "steer": steer});
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": meta}})
}

/// A FIFO nobody writes: the fake Claude Code never reads a steer (its next tool step never
/// comes), as a harness that stopped answering does.
fn fifo() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!("acpmux-stop-steer-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&path).status().unwrap().success());
    path
}

/// Inbox notices' `user_message` records.
fn notices(hub: &Arc<Hub>, id: &str) -> Vec<Value> {
    let records = hub.events(id, 0, 1_000_000).unwrap();
    records
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg)
        .filter(|m| m["_meta"]["provenance"]["kind"] == "inbox_notice")
        .collect()
}

/// Whether notice `n` carries message `prompt_id`.
fn carries(n: &Value, prompt_id: &str) -> bool {
    let threads = n["_meta"]["provenance"]["threads"].as_array().cloned().unwrap_or_default();
    threads
        .iter()
        .any(|t| t["promptIds"].as_array().is_some_and(|ids| ids.iter().any(|v| v == prompt_id)))
}

/// A chat whose agent (fake Claude Code, steering) runs the coordinator's first work, which never
/// answers a cancel; its stopped turn's id.
async fn deaf_turn(step: &std::path::Path) -> (Arc<Hub>, TestClient, String, String) {
    deaf_turn_with(step, &[]).await
}

async fn deaf_turn_with(
    step: &std::path::Path,
    extra: &[(&str, &str)],
) -> (Arc<Hub>, TestClient, String, String) {
    let mut env = BTreeMap::from([
        ("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned()),
        ("FAKE_STEER_STEP".to_owned(), step.display().to_string()),
    ]);
    env.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let id = new_session(&mut c, "lane").await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "w-first", "deaf-to-cancel", false)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let turn = hub.resolve(&id).unwrap().turn().unwrap().turn_id;
    (hub, c, id, turn)
}

/// A Stop that is not the person's (another agent's `acpmux session cancel`): it holds nothing,
/// so what it sends back starts the next turn at once. The person's holds the other agents'
/// messages ([`a_message_the_persons_stop_sent_back_waits_for_the_person`]).
async fn stop(hub: &Arc<Hub>, id: &str) {
    hub.cancel(&hub.resolve(id).unwrap()).await.expect("the Stop is refused");
}

/// Waits for the stopped turn's forced end.
async fn forced_end(c: &mut TestClient) {
    let ended = tokio::time::timeout(
        Duration::from_secs(20),
        c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_result"),
    )
    .await
    .expect("the stopped turn never ended");
    assert_eq!(ended["msg"]["cancelForced"], true, "{ended}");
}

/// The message starts the next turn: a notice that carries it is a turn of its own, after the
/// stopped one, and no notice that carried it was answered by the stopped turn's end.
async fn starts_the_next_turn(hub: &Arc<Hub>, id: &str, stopped: &str, prompt_id: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let next = loop {
        let found = notices(hub, id)
            .into_iter()
            .find(|n| carries(n, prompt_id) && n["steer"] != true && n["turnId"] != stopped);
        if let Some(n) = found {
            break n;
        }
        let records = hub.events(id, 0, 1_000_000).unwrap();
        assert!(
            tokio::time::Instant::now() < deadline,
            "the message never started the next turn: {:#?}",
            records
                .iter()
                .filter(|r| r.kind.starts_with("inbox")
                    || r.kind.starts_with("steer")
                    || r.kind == "user_message"
                    || r.kind == "turn_end")
                .map(|r| (&r.kind, &r.msg))
                .collect::<Vec<_>>()
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    let records = hub.events(id, 0, 1_000_000).unwrap();
    let answered: Vec<&Value> = records
        .iter()
        .filter(|r| r.kind == "inbox_answered")
        .map(|r| &r.msg)
        .filter(|m| m["answer"]["_meta"]["acpmux"]["cancelForced"] == true)
        .collect();
    assert!(answered.is_empty(), "the forced end answered it: {answered:?}");
    let ended = records.iter().find(|r| r.kind == "turn_end" && r.msg["turnId"] == stopped);
    let started =
        records.iter().find(|r| r.kind == "user_message" && r.msg["promptId"] == next["promptId"]);
    let (ended, started) = (ended.expect("no turn_end"), started.unwrap());
    assert!(started.seq > ended.seq, "it starts after the stopped turn: {next}");
}

/// The 2026-11-02 sequence: Stop, the message a second later (inside the cancel's grace), the
/// forced end. The message never goes into the stopping turn and starts the next one at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_sent_while_stop_cancels_starts_the_next_turn() {
    let step = fifo();
    let (hub, mut c, id, stopped) = deaf_turn(&step).await;
    stop(&hub, &id).await;
    let mut state = Value::Null;
    for _ in 0..200 {
        state = hub.session_summary(&hub.resolve(&id).unwrap())["state"].clone();
        if state == "stopping" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(state, "stopping");
    tokio::time::sleep(Duration::from_millis(1_000)).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-1", "please rebase #42", true)).await;
    forced_end(&mut c).await;
    starts_the_next_turn(&hub, &id, &stopped, "m-1").await;
    let into_stopped = notices(&hub, &id).into_iter().any(|n| n["turnId"] == stopped.as_str());
    assert!(!into_stopped, "no notice goes into the stopping turn: {:?}", notices(&hub, &id));
    let _ = std::fs::remove_file(step);
}

/// The message went in before the Stop, and the agent never read it before the forced end: it
/// comes back and starts the next turn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_the_agent_never_read_before_a_forced_stop_starts_the_next_turn() {
    let step = fifo();
    let (hub, mut c, id, stopped) = deaf_turn(&step).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-1", "please rebase #42", true)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !notices(&hub, &id).iter().any(|n| n["steer"] == true && carries(n, "m-1")) {
        assert!(tokio::time::Instant::now() < deadline, "the notice never steered in");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    stop(&hub, &id).await;
    forced_end(&mut c).await;
    starts_the_next_turn(&hub, &id, &stopped, "m-1").await;
    let records = hub.events(&id, 0, 1_000_000).unwrap();
    assert!(records.iter().any(|r| r.kind == "steer_returned"), "the log says it came back");
    let _ = std::fs::remove_file(step);
}

/// The message went in before the Stop and its agent cannot say it dropped it (codex-acp answers
/// steers only at the turn's end; a batched line stays queued): it may have been read, so it ends
/// with the turn as before and is never sent a second time.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_its_agent_cannot_take_back_is_not_sent_twice() {
    let step = fifo();
    let (hub, mut c, id, stopped) = deaf_turn_with(&step, &[("FAKE_STEER_KEEP", "1")]).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-1", "please rebase #42", true)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !notices(&hub, &id).iter().any(|n| n["steer"] == true && carries(n, "m-1")) {
        assert!(tokio::time::Instant::now() < deadline, "the notice never steered in");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    stop(&hub, &id).await;
    forced_end(&mut c).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let records = hub.events(&id, 0, 1_000_000).unwrap();
        if records.iter().any(|r| r.kind == "inbox_answered") {
            assert!(!records.iter().any(|r| r.kind == "steer_returned"), "it never comes back");
            break;
        }
        assert!(tokio::time::Instant::now() < deadline, "the stopped turn never answered it");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(500)).await;
    let again =
        notices(&hub, &id).into_iter().any(|n| carries(&n, "m-1") && n["turnId"] != stopped);
    assert!(!again, "a second copy went in: {:?}", notices(&hub, &id));
    let _ = std::fs::remove_file(step);
}

/// The person's Stop holds the other agents' messages (`cancel.rs` `hold_agent_messages`): one it
/// sent back waits too, starts no turn and releases nothing, and goes in once the person resumes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_the_persons_stop_sent_back_waits_for_the_person() {
    let step = fifo();
    let (hub, mut c, id, stopped) = deaf_turn(&step).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-1", "please rebase #42", true)).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !notices(&hub, &id).iter().any(|n| n["steer"] == true && carries(n, "m-1")) {
        assert!(tokio::time::Instant::now() < deadline, "the notice never steered in");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let session = hub.resolve(&id).unwrap();
    hub.person_stop(&session).await.expect("the Stop is refused");
    forced_end(&mut c).await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    while !hub.events(&id, 0, 1_000_000).unwrap().iter().any(|r| r.kind == "steer_returned") {
        assert!(tokio::time::Instant::now() < deadline, "it never came back");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    tokio::time::sleep(Duration::from_millis(1_500)).await;
    let early =
        notices(&hub, &id).into_iter().any(|n| carries(&n, "m-1") && n["turnId"] != stopped);
    assert!(!early, "it went in under the Stop's hold: {:?}", notices(&hub, &id));
    assert!(session.turn().is_none(), "a turn started under the Stop's hold");
    let resume = json!({"sessionId": id, "op": "resume"});
    c.request(method::MUX_QUEUE_EDIT, resume).await.expect("the resume is refused");
    starts_the_next_turn(&hub, &id, &stopped, "m-1").await;
    let _ = std::fs::remove_file(step);
}
