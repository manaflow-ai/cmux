//! The order of a failed subagent's retry records when Stop, close and the retry's own task
//! race (`subagent_retry.rs`, `Retries::steps`). Each test drives the hub's observer directly,
//! so the interleaving is fixed: the spawned retry task runs only when the test awaits.

use super::*;
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use std::path::Path;
use tokio::sync::mpsc;

/// A hub with one chat (a stand-in agent) and `delays` as `autoResumeDelaysMs`.
async fn chat(delays: Vec<u64>) -> (Arc<Hub>, Arc<Session>, mpsc::Sender<String>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.auto_resume_delays_ms = Some(delays);
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut out_rx) = mpsc::channel(256);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    loop {
        let reply: Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        if reply["id"] == 1 {
            let session = hub.resolve(reply["result"]["sessionId"].as_str().unwrap()).unwrap();
            return (hub, session, in_tx);
        }
    }
}

/// A top-level subagent's end on SR2's 503, as the subagent tree reports it.
fn failed(id: &str) -> Value {
    json!({"id": id, "parent": null, "state": "failed", "task": "Push relay",
        "agentId": format!("agent-{id}"),
        "error": "API Error: 503 no non-exhausted claude accounts available"})
}

/// The chat's `subagent_retry` outcomes, `skipped:<why>` for a skip.
fn outcomes(hub: &Hub, session: &Session) -> Vec<String> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records
        .into_iter()
        .filter(|e| e.kind == "subagent_retry")
        .map(|e| match e.msg["skipped"].as_str() {
            Some(why) => format!("skipped:{why}"),
            None => e.msg["outcome"].as_str().unwrap_or_default().to_owned(),
        })
        .collect()
}

/// The subagent's last entry acpmux logged.
fn last_entry(hub: &Hub, session: &Session, id: &str) -> Option<Value> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records
        .into_iter()
        .rev()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .find(|e| e["id"] == id && e.get("retryable").is_some())
}

/// Lets the spawned retry tasks run.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(150)).await;
}

/// Stop before the first wait is planned: nothing is scheduled, fired or given up after it.
#[tokio::test]
async fn stop_before_the_first_wait_is_planned_leaves_no_later_record() {
    // `[0]`: it would fire at once; `[]`: it would be given up at once.
    for delays in [vec![0], vec![]] {
        let (hub, session, _conn) = chat(delays.clone()).await;
        hub.observe_subagents(&session, &[failed("s/t1")]);
        hub.stop_subagent_retries(&session, false);
        settle().await;
        assert_eq!(outcomes(&hub, &session), Vec::<String>::new(), "{delays:?}");
        let entry = last_entry(&hub, &session, "s/t1").expect("its entry after the Stop");
        assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(true)));
    }
}

/// Stop while the wait runs: skipped, and the woken task never fires it afterwards.
#[tokio::test]
async fn a_stopped_wait_never_fires_once_woken() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled"]);
    let wake = {
        let all = hub.subagent_retries.lock();
        let failed = all.subs[&session.id]["s/t1"].failed.as_ref().unwrap();
        failed.wait.as_ref().unwrap().wake.clone()
    };
    hub.stop_subagent_retries(&session, false);
    wake.notify_one();
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled", "skipped:stopped"]);
    let users = hub.events(&session.id, 0, 10_000).unwrap();
    assert!(!users.iter().any(|e| e.kind == "user_message"), "no retry prompt went out");
}

/// A failure that arrives while the chat closes (`closing` set, its retries taken) is not
/// retried.
#[tokio::test]
async fn a_failure_while_the_chat_closes_is_not_retried() {
    let (hub, session, _conn) = chat(vec![0]).await;
    session.closing.store(true, Ordering::SeqCst);
    hub.stop_subagent_retries(&session, true);
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    assert_eq!(outcomes(&hub, &session), Vec::<String>::new());
    assert!(!hub.subagent_retries.lock().subs.contains_key(&session.id), "nothing kept");
}

/// A wait planned before close began is skipped by close and never fires.
#[tokio::test]
async fn close_after_the_wait_was_planned_skips_it() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    session.closing.store(true, Ordering::SeqCst);
    hub.stop_subagent_retries(&session, true);
    hub.observe_subagents(&session, &[failed("s/t2")]);
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled", "skipped:closed"]);
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!(entry["retryable"], false, "{entry}");
}

/// Sends a prompt as a subagent retry does, with `prompt_id`.
fn send(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    prompt_id: &str,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, session) = (hub.clone(), session.clone());
    let opts = PromptOptions { prompt_id: Some(prompt_id.to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "Resume it"})];
    tokio::spawn(async move { hub.prompt_with(&session, blocks, "acpmux", false, opts).await })
}

/// A sent retry prompt (`fire_wait` records it) about to start while Claude Code runs a turn of
/// its own: it waits for that turn's end, then starts.
#[tokio::test]
async fn a_retry_prompt_waits_out_claudes_own_turn_at_its_start() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let key = (session.id.clone(), "subagent-retry-t1-1".to_owned());
    hub.subagent_retries.lock().sent.insert(key.clone(), false);
    session.harness_turn.store(true, Ordering::SeqCst);
    let sent = send(&hub, &session, &key.1);
    settle().await;
    assert!(!sent.is_finished(), "it started inside Claude Code's own turn");
    assert!(session.turn().is_none());
    // That turn's `result`.
    session.harness_turn.store(false, Ordering::SeqCst);
    hub.append(&session, "mux", "test_tick", json!({}));
    sent.await.unwrap().expect("it ran once that turn ended");
    // Another prompt never waits.
    session.harness_turn.store(true, Ordering::SeqCst);
    send(&hub, &session, "p-person").await.unwrap().expect("a person's prompt runs");
}

/// A retry skipped while its prompt waits to start is refused there.
#[tokio::test]
async fn a_retry_prompt_skipped_while_it_waits_to_start_is_refused() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let key = (session.id.clone(), "subagent-retry-t1-1".to_owned());
    hub.subagent_retries.lock().sent.insert(key.clone(), false);
    session.harness_turn.store(true, Ordering::SeqCst);
    let sent = send(&hub, &session, &key.1);
    settle().await;
    hub.subagent_retries.lock().sent.insert(key, true);
    hub.append(&session, "mux", "test_tick", json!({}));
    let refused = sent.await.unwrap().unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "subagent_retry.skipped");
    assert!(session.turn().is_none());
}

/// A forgotten agent resumed, then its raw 503 arriving while the chat closes: its entry ends
/// not retryable.
#[tokio::test]
async fn a_raw_failure_while_the_chat_closes_leaves_it_not_retryable() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let raw = |subtype: &str| {
        json!({"type": "system", "subtype": subtype, "task_id": "agent-s/t1", "status": "failed",
            "summary": "API Error: 503 no non-exhausted claude accounts available"})
    };
    hub.observe_task_line(&session, &raw("task_started"));
    session.closing.store(true, Ordering::SeqCst);
    hub.observe_task_line(&session, &raw("task_notification"));
    hub.stop_subagent_retries(&session, true);
    settle().await;
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!(entry["retryable"], false, "{entry}");
    let got = outcomes(&hub, &session);
    assert_eq!(got, ["scheduled", "skipped:resumed"], "nothing scheduled after close began");
}

/// A person's retry, under the local caller's rules.
fn by_person() -> crate::hub::auto_resume::retry_turn::RetryBy {
    crate::hub::auto_resume::retry_turn::RetryBy {
        control: crate::hub::Control::Local,
        trust_gate: false,
        full_access_device: None,
        from: None,
    }
}

/// A person's retry says why a subagent can't be retried: replaced by a new one of its name (by
/// its id or its agent id), running, or its chat closing.
#[tokio::test]
async fn a_person_retry_says_why_a_subagent_cannot_be_retried() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let running =
        |id: &str| json!({"id": id, "parent": null, "state": "running", "task": "Push relay"});
    // Named by its start, as the translator reports it.
    hub.observe_subagents(&session, &[running("s/t1"), failed("s/t1")]);
    settle().await;
    hub.observe_subagents(&session, &[running("s/t2")]);
    let why = |e: RpcError| {
        let data = e.data.unwrap();
        assert_eq!(data["reason"], "retry.nothing_failed", "{data}");
        data["why"].as_str().unwrap().to_owned()
    };
    for named in ["s/t1", "agent-s/t1"] {
        let refused = hub.retry_subagent(&session, named, by_person()).await.unwrap_err();
        assert_eq!(why(refused), "replaced", "{named}");
    }
    let refused = hub.retry_subagent(&session, "s/t2", by_person()).await.unwrap_err();
    assert_eq!(why(refused), "running");
    let refused = hub.retry_subagent(&session, "s/t9", by_person()).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "retry.unknown_subagent");
    session.closing.store(true, Ordering::SeqCst);
    let refused = hub.retry_subagent(&session, "s/t2", by_person()).await.unwrap_err();
    assert_eq!(why(refused), "closed");
    assert_eq!(outcomes(&hub, &session), ["scheduled", "skipped:replaced"]);
}

/// A stopped subagent a person retries, whose turn ends with it still failed, gets no automatic
/// attempts after it: it stays stopped, and a person can retry it again.
#[tokio::test]
async fn a_stopped_subagent_a_person_retried_stays_stopped() {
    // `[0]`: an automatic attempt would fire at once.
    let (hub, session, _conn) = chat(vec![0]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    hub.stop_subagent_retries(&session, false);
    settle().await;
    let v = hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap();
    assert_eq!(v["kind"], "subagent", "{v}");
    let idle = || {
        let all = hub.subagent_retries.lock();
        let failed = all.subs[&session.id]["s/t1"].failed.clone().unwrap();
        failed.idle && failed.wait.is_none()
    };
    for _ in 0..100 {
        if idle() {
            break;
        }
        settle().await;
    }
    assert!(idle(), "its turn ended and it is stopped again");
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["fired"]);
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(true)));
    let again = hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap();
    assert_ne!(again["promptId"], v["promptId"]);
}

/// A person's retry whose prompt is refused at dispatch (here: the sub-session that asked is
/// gone) answers with the refusal at once, never after the next automatic attempt's wait.
#[tokio::test]
async fn a_refused_person_retry_answers_at_once() {
    let (hub, session, _conn) = chat(vec![60_000, 60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let by =
        crate::hub::auto_resume::retry_turn::RetryBy { from: Some("gone".into()), ..by_person() };
    let answer = hub.retry_subagent(&session, "s/t1", by);
    let refused = tokio::time::timeout(Duration::from_secs(10), answer).await;
    let refused = refused.expect("answered at once").unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "subsessions.sender_gone");
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled", "fired", "scheduled"]);
}

/// The chat's `user_message` records.
fn prompts(hub: &Hub, session: &Session) -> Vec<Value> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records.into_iter().filter(|e| e.kind == "user_message").map(|e| e.msg).collect()
}

/// The subagent's retry state: its attempts so far, and its wait's attempt and whether it fired.
fn wait_of(hub: &Hub, session: &Session, id: &str) -> (usize, Option<(usize, bool)>) {
    let all = hub.subagent_retries.lock();
    let sub = &all.subs[&session.id][id];
    let wait = sub.failed.as_ref().and_then(|f| f.wait.as_ref()).map(|w| (w.attempt, w.fired));
    (sub.attempts, wait)
}

/// A prompt that takes the chat between a person's claim and its send (here: one holding the
/// turn lock, about to start; then Claude Code's own turn): `retry.busy`, nothing queued or sent,
/// and the automatic retry it took over waits again, at its attempt.
#[tokio::test]
async fn a_person_retry_overtaken_after_its_claim_is_busy_and_gives_the_wait_back() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    for overtaken in ["turn_lock", "harness_turn"] {
        let claim = hub.claim_subagent(&session, "s/t1", 1).unwrap();
        assert_eq!(wait_of(&hub, &session, "s/t1"), (1, Some((1, true))));
        let lock = (overtaken == "turn_lock").then(|| session.turn_lock.try_lock().unwrap());
        session.harness_turn.store(overtaken == "harness_turn", Ordering::SeqCst);
        let refused = hub.send_claim(&session, "s/t1", claim, by_person()).await.unwrap_err();
        drop(lock);
        session.harness_turn.store(false, Ordering::SeqCst);
        assert_eq!(refused.data.unwrap()["reason"], "retry.busy", "{overtaken}");
        assert!(session.queue().is_empty(), "{overtaken}: nothing queued");
        assert!(prompts(&hub, &session).is_empty(), "{overtaken}: nothing sent");
        settle().await;
        assert_eq!(wait_of(&hub, &session, "s/t1"), (0, Some((1, false))), "{overtaken}");
    }
    assert_eq!(outcomes(&hub, &session), ["scheduled", "fired", "scheduled", "fired", "scheduled"]);
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(true)));
    assert!(entry["retry"].is_object(), "it waits again: {entry}");
    // The wait it gave back still fires, now.
    hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap();
}

/// Stop, a resume or a replacement between a person's claim and its prompt's start: the prompt
/// never runs, and the retry answers `retry.nothing_failed` (`skipped`), never a promptId.
#[tokio::test]
async fn a_person_retry_skipped_before_its_prompt_starts_is_refused() {
    for skip in ["stop", "resume", "replace"] {
        let (hub, session, _conn) = chat(vec![60_000]).await;
        let running =
            json!({"id": "s/t1", "parent": null, "state": "running", "task": "Push relay"});
        hub.observe_subagents(&session, &[running, failed("s/t1")]);
        settle().await;
        let claim = hub.claim_subagent(&session, "s/t1", 1).unwrap();
        match skip {
            "stop" => hub.stop_subagent_retries(&session, false),
            "resume" => hub.observe_subagents(
                &session,
                &[json!({"id": "s/t1", "parent": null, "state": "running"})],
            ),
            _ => hub.observe_subagents(
                &session,
                &[json!({"id": "s/t2", "parent": null, "state": "running", "task": "Push relay"})],
            ),
        }
        let refused = hub.send_claim(&session, "s/t1", claim, by_person()).await.unwrap_err();
        let data = refused.data.unwrap();
        assert_eq!(
            (&data["reason"], &data["why"]),
            (&json!("retry.nothing_failed"), &json!("skipped")),
            "{skip}"
        );
        assert!(prompts(&hub, &session).is_empty(), "{skip}: nothing ran");
        assert!(session.turn().is_none(), "{skip}");
    }
}

/// A double click: the second retry while the first one's prompt is under way is `retry.busy`,
/// and only one prompt goes.
#[tokio::test]
async fn a_second_person_retry_while_the_first_is_under_way_is_busy() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let first = hub.claim_subagent(&session, "s/t1", 1).unwrap();
    let second = hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap_err();
    assert_eq!(second.data.unwrap()["reason"], "retry.busy");
    let v = hub.send_claim(&session, "s/t1", first, by_person()).await.unwrap();
    assert_eq!(v["kind"], "subagent", "{v}");
    settle().await;
    assert_eq!(prompts(&hub, &session).len(), 1);
    assert_eq!(outcomes(&hub, &session).iter().filter(|o| *o == "fired").count(), 1);
}

/// A sub-session's retry (`from` its parent) passes the family check at dispatch, and its prompt
/// names the sender.
#[tokio::test]
async fn a_sub_session_retry_runs_and_names_its_sender() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let (out_tx, mut out_rx) = mpsc::channel(64);
    let (in_tx, in_rx) = mpsc::channel(8);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(2, method::SESSION_NEW, new).to_line()).await.unwrap();
    let parent = loop {
        let reply: Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        if reply["id"] == 2 {
            break reply["result"]["sessionId"].as_str().unwrap().to_owned();
        }
    };
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let by =
        crate::hub::auto_resume::retry_turn::RetryBy { from: Some(parent.clone()), ..by_person() };
    let v = hub.retry_subagent(&session, "s/t1", by).await.unwrap();
    assert_eq!(v["kind"], "subagent", "{v}");
    let sent = prompts(&hub, &session);
    let provenance = &sent[0]["_meta"]["provenance"];
    assert_eq!(provenance["from"], parent.as_str(), "{provenance}");
    assert_eq!(provenance["manual"], true, "{provenance}");
    assert_eq!(provenance["kind"], "subagent_retry", "{provenance}");
}

/// A turn continuation that becomes pending between a person's claim and its start (here: its
/// cut turn ending, not settled yet): refused `retry.busy` at the start, under the continuation's
/// own lock, and the claim given back.
#[tokio::test]
async fn a_person_retry_is_busy_once_a_continuation_is_pending_at_its_start() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let claim = hub.claim_subagent(&session, "s/t1", 1).unwrap();
    hub.set_ending_for_test(&session, Some("t-cut"));
    let refused = hub.send_claim(&session, "s/t1", claim, by_person()).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "retry.busy");
    assert!(prompts(&hub, &session).is_empty(), "nothing sent");
    assert!(session.turn().is_none());
    settle().await;
    assert_eq!(wait_of(&hub, &session, "s/t1"), (0, Some((1, false))), "the wait is given back");
    hub.set_ending_for_test(&session, None);
    hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap();
}

/// A prompt that comes into the queue between a person's claim and its slot, which the `queued`
/// count does not show yet (a queue change in flight): read under the queue's lock, the retry is
/// `retry.busy` and never starts ahead of it.
#[tokio::test]
async fn a_person_retry_is_busy_behind_a_queued_prompt_the_count_misses() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let queued = queued_prompt("p-waits", None);
    // Claimed with the queue empty; the prompt comes in before the retry's slot.
    let claim = hub.claim_subagent(&session, "s/t1", 1).unwrap();
    session.queue.lock().unwrap().push(queued);
    assert_eq!(session.queued(), 0, "the count does not show it");
    let refused = hub.send_claim(&session, "s/t1", claim, by_person()).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "retry.busy");
    assert!(prompts(&hub, &session).is_empty(), "it never started ahead of the queue");
    settle().await;
    assert_eq!(wait_of(&hub, &session, "s/t1"), (0, Some((1, false))), "the wait is given back");
    session.queue.lock().unwrap().clear();
    hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap();
    assert_eq!(prompts(&hub, &session).len(), 1);
}

/// Another chat on `hub`, and the connection that keeps it.
async fn another_chat(hub: &Arc<Hub>) -> (Arc<Session>, mpsc::Sender<String>) {
    let (out_tx, mut out_rx) = mpsc::channel(64);
    let (in_tx, in_rx) = mpsc::channel(8);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(2, method::SESSION_NEW, new).to_line()).await.unwrap();
    loop {
        let reply: Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        if reply["id"] == 2 {
            let session = hub.resolve(reply["result"]["sessionId"].as_str().unwrap()).unwrap();
            return (session, in_tx);
        }
    }
}

/// A sub-session's subagent retry, asked for by its parent, takes one of the parent's run slots
/// as its family prompts do: with them all taken it is `retry.busy`, never queued, and goes once
/// one frees.
#[tokio::test]
async fn a_sub_session_retry_is_busy_while_its_parents_run_slots_are_full() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let (parent, _parent_conn) = another_chat(&hub).await;
    let (sibling, _sibling_conn) = another_chat(&hub).await;
    parent.meta.lock().unwrap().subsession_limits.max_running = Some(1);
    for child in [&session, &sibling] {
        child.meta.lock().unwrap().subsession = Some(crate::store::SubsessionLink {
            started_by: parent.id.clone(),
            short_name: child.id.clone(),
            depth: 1,
            offered: false,
        });
    }
    let family = json!({"kind": crate::hub::subsessions::PROVENANCE_KIND, "from": parent.id});
    let slot = hub.take_run_slot(&sibling, Some(&family)).unwrap().expect("the one slot");
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let by = || crate::hub::auto_resume::retry_turn::RetryBy {
        from: Some(parent.id.clone()),
        ..by_person()
    };
    let refused = hub.retry_subagent(&session, "s/t1", by()).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "retry.busy");
    assert!(session.queue().is_empty(), "never queued for a slot");
    assert!(prompts(&hub, &session).is_empty());
    settle().await;
    assert_eq!(wait_of(&hub, &session, "s/t1"), (0, Some((1, false))), "the wait is given back");
    drop(slot);
    let v = hub.retry_subagent(&session, "s/t1", by()).await.unwrap();
    assert_eq!(v["kind"], "subagent", "{v}");
}

/// A queue entry as `enqueue` makes it, with `provenance`, that no task waits on.
fn queued_prompt(prompt_id: &str, provenance: Option<Value>) -> crate::hub::queue::QueuedPrompt {
    let run = crate::hub::queue::PromptRun {
        size: Default::default(),
        blocks: vec![json!({"type": "text", "text": "waits"})],
        display_parts: None,
        control: crate::hub::Control::Local,
        trust_gate: false,
        provenance,
        agent: None,
        class: None,
        supersede: None,
        full_access_device: None,
        message_id: None,
        message_sender: None,
    };
    crate::hub::queue::QueuedPrompt {
        prompt_id: prompt_id.into(),
        turn_id: format!("t-{prompt_id}"),
        client: "test".into(),
        preview: "waits".into(),
        queued_at: 0,
        withdraw: Arc::new(Notify::new()),
        run: Arc::new(run),
        restored: false,
        resume: false,
        steer: false,
        held: false,
        awaiting_owner: false,
        revision: 0,
        declined: Default::default(),
        sent_now: false,
        joined: Arc::new(std::sync::Mutex::new(None)),
        requeued: false,
        retries: 0,
    }
}

/// Stopping a sub-session takes out the retries its parent asked for that wait in its queue
/// (for a run slot), as it takes out the parent's messages; the chat's own prompts stay.
#[tokio::test]
async fn stopping_a_sub_session_withdraws_the_retries_waiting_in_its_queue() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let retry = json!({"kind": "auto_resume", "promptId": "p", "attempt": 1, "manual": true,
        "from": "parent"});
    let message = json!({"kind": crate::hub::subsessions::PROVENANCE_KIND, "from": "parent"});
    for (id, provenance) in
        [("p-retry", Some(retry)), ("p-message", Some(message)), ("p-own", None)]
    {
        session.queue.lock().unwrap().push(queued_prompt(id, provenance));
        session.queued.fetch_add(1, Ordering::SeqCst);
    }
    hub.withdraw_family_prompts(&session, "stopped");
    let left: Vec<String> = session.queue().into_iter().map(|q| q.prompt_id).collect();
    assert_eq!(left, ["p-own"]);
    let removed: Vec<Value> = hub
        .events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "queue_removed")
        .map(|e| e.msg)
        .collect();
    assert_eq!(removed.len(), 2, "{removed:?}");
    assert!(removed.iter().all(|r| r["reason"] == "stopped"), "{removed:?}");
}

/// The subagent's entries acpmux logged, oldest first.
fn entries(hub: &Hub, session: &Session, id: &str) -> Vec<Value> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records
        .into_iter()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .filter(|e| e["id"] == id && e.get("retryable").is_some())
        .collect()
}

/// Whether the chat's saved meta says a logged retry may be open (`subagentRetryOpen`).
fn retry_open(session: &Session) -> bool {
    serde_json::to_value(session.meta()).unwrap()["subagentRetryOpen"] == true
}

/// Whether `entry` says no attempt is in flight: `retryInFlight` there, and null.
fn none_in_flight(entry: &Value) -> bool {
    entry.get("retryInFlight") == Some(&Value::Null)
}

/// An automatic attempt is in flight from its fire; its turn ending with the subagent still
/// failed ends it (here: given up, the attempts used up).
#[tokio::test]
async fn an_automatic_attempt_is_in_flight_from_its_fire_until_its_turn_ends() {
    let (hub, session, _conn) = chat(vec![0]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    for _ in 0..100 {
        if outcomes(&hub, &session).iter().any(|o| o == "exhausted") {
            break;
        }
        settle().await;
    }
    assert_eq!(outcomes(&hub, &session), ["scheduled", "fired", "exhausted"]);
    let got = entries(&hub, &session, "s/t1");
    assert_eq!(got.len(), 3, "{got:?}");
    assert!(none_in_flight(&got[0]), "scheduled: {}", got[0]);
    let fired = &got[1]["retryInFlight"];
    assert_eq!((&fired["attempt"], &fired["of"]), (&json!(1), &json!(1)), "{fired}");
    assert_eq!((&fired["reason"], &fired["manual"]), (&json!("capacity"), &json!(false)));
    assert!(fired["firedAt"].as_u64().is_some_and(|at| at > 0), "{fired}");
    assert!(fired["promptId"].as_str().is_some_and(|p| p.starts_with("subagent-retry-")));
    assert!(none_in_flight(&got[2]), "given up: {}", got[2]);
    assert!(!retry_open(&session), "nothing left open for a load to settle");
}

/// A person's attempt is in flight from its fire (a second retry meanwhile is busy) until the
/// subagent runs again.
#[tokio::test]
async fn a_person_attempt_is_in_flight_until_the_subagent_runs_again() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let _claim = hub.claim_subagent(&session, "s/t1", 1).unwrap();
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    let in_flight = &entry["retryInFlight"];
    assert_eq!((&in_flight["attempt"], &in_flight["manual"]), (&json!(1), &json!(true)), "{entry}");
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    let fired = records.iter().rev().find(|e| e.kind == "subagent_retry").unwrap();
    assert_eq!(in_flight["promptId"], fired.msg["promptId"], "{entry}");
    assert_eq!((&entry["state"], &entry["retry"]), (&json!("failed"), &Value::Null));
    let busy = hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap_err();
    assert_eq!(busy.data.unwrap()["reason"], "retry.busy");
    hub.observe_subagents(&session, &[json!({"id": "s/t1", "parent": null, "state": "running"})]);
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!(entry["state"], "running", "{entry}");
    assert!(none_in_flight(&entry), "{entry}");
}

/// An attempt refused before its prompt was recorded is no longer in flight: its wait waits
/// again. A stopped subagent's attempt whose turn ended with it still failed, likewise.
#[tokio::test]
async fn an_attempt_refused_or_over_is_no_longer_in_flight() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    let claim = hub.claim_subagent(&session, "s/t1", 1).unwrap();
    session.harness_turn.store(true, Ordering::SeqCst);
    let refused = hub.send_claim(&session, "s/t1", claim, by_person()).await.unwrap_err();
    session.harness_turn.store(false, Ordering::SeqCst);
    assert_eq!(refused.data.unwrap()["reason"], "retry.busy");
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert!(none_in_flight(&entry) && entry["retry"].is_object(), "waits again: {entry}");

    // Stopped, then a person's attempt whose turn ends with the subagent still failed.
    hub.stop_subagent_retries(&session, false);
    hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap();
    let over = || {
        let all = hub.subagent_retries.lock();
        let failed = all.subs[&session.id]["s/t1"].failed.clone().unwrap();
        failed.idle && failed.wait.is_none()
    };
    for _ in 0..100 {
        if over() {
            break;
        }
        settle().await;
    }
    assert!(over(), "its turn ended");
    let got = entries(&hub, &session, "s/t1");
    assert!(got.iter().any(|e| e["retryInFlight"]["manual"] == true), "{got:?}");
    let entry = got.last().unwrap();
    assert!(none_in_flight(entry), "{entry}");
    assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(true)));
}

/// Stop and close end an attempt in flight, and leave nothing open for a load to settle.
#[tokio::test]
async fn stop_and_close_end_an_attempt_in_flight() {
    for closed in [false, true] {
        let (hub, session, _conn) = chat(vec![60_000]).await;
        hub.observe_subagents(&session, &[failed("s/t1")]);
        settle().await;
        hub.claim_subagent(&session, "s/t1", 1).unwrap();
        assert!(retry_open(&session), "{closed}");
        session.closing.store(closed, Ordering::SeqCst);
        hub.stop_subagent_retries(&session, closed);
        let entry = last_entry(&hub, &session, "s/t1").unwrap();
        assert!(none_in_flight(&entry), "{closed}: {entry}");
        assert_eq!(entry["retryable"], json!(!closed), "{entry}");
        assert!(!retry_open(&session), "{closed}: nothing left open");
    }
}

/// A daemon restart drops an attempt in flight (and a waiting retry): the chat's load logs
/// each entry again with neither, not retryable, once.
#[tokio::test]
async fn a_restart_settles_an_attempt_left_in_flight() {
    let dir = std::env::temp_dir().join(format!("acpmux-inflight-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg.auto_resume_delays_ms = Some(vec![60_000]);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let (session, conn) = another_chat(&hub).await;
    let id = session.id.clone();
    hub.observe_subagents(&session, &[failed("s/t1"), failed("s/t2")]);
    settle().await;
    hub.claim_subagent(&session, "s/t1", 1).unwrap();
    assert!(last_entry(&hub, &session, "s/t1").unwrap()["retryInFlight"].is_object());
    assert!(last_entry(&hub, &session, "s/t2").unwrap()["retry"].is_object());
    // A fired retry prompt the queue kept, as one queued behind a turn is logged.
    let queued = json!({"text": "Resume it", "client": "acpmux", "position": 1,
        "promptId": "subagent-retry-t2-1-1", "turnId": "t-retry", "control": "local",
        "prompt": [{"type": "text", "text": "Resume it"}],
        "_meta": {"provenance": {"kind": PROVENANCE_KIND, "subagentId": "s/t2", "attempt": 1}}});
    hub.append(&session, "mux", "queued", queued);
    hub.shutdown_all().await;
    drop((hub, session, conn));

    let reopen = || Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let hub = reopen();
    let session = hub.resolve(&id).unwrap();
    for sub in ["s/t1", "s/t2"] {
        let entry = last_entry(&hub, &session, sub).unwrap();
        assert!(none_in_flight(&entry) && entry["retry"].is_null(), "{sub}: {entry}");
        assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(false)));
        assert_eq!(entry["agentId"], format!("agent-{sub}"), "{entry}");
    }
    assert!(!retry_open(&session));
    // Its queue came back without the retry prompt (`drop_unsent_subagent_retries`), never run.
    hub.resume_queues();
    let refused = || {
        let records = hub.events(&session.id, 0, 10_000).unwrap();
        let id = |e: &crate::store::EventRecord| e.msg["promptId"] == "subagent-retry-t2-1-1";
        let ran = records.iter().any(|e| e.kind == "user_message" && id(e));
        assert!(!ran, "the retry prompt ran after the restart");
        records.iter().any(|e| {
            matches!(e.kind.as_str(), "prompt_refused" | "turn_result" | "queue_removed") && id(e)
        })
    };
    for _ in 0..100 {
        if refused() {
            break;
        }
        settle().await;
    }
    assert!(refused(), "the restored retry prompt settled");
    assert!(session.turn().is_none());
    let count = entries(&hub, &session, "s/t1").len();
    let refused = hub.retry_subagent(&session, "s/t1", by_person()).await.unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "retry.unknown_subagent");
    hub.shutdown_all().await;
    drop((hub, session));
    let hub = reopen();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(entries(&hub, &session, "s/t1").len(), count, "settled once");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A chat imported with a retry in flight (a bundle `acpmux export` wrote): the import settles
/// its entries, as a restart does.
#[tokio::test]
async fn an_import_settles_an_attempt_left_in_flight() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let dirs: Vec<std::path::PathBuf> = (0..3)
        .map(|_| std::env::temp_dir().join(format!("acpmux-inflight-{}", uuid::Uuid::now_v7())))
        .collect();
    let hub_at = |dir: &Path| {
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Local;
        cfg.auto_resume_delays_ms = Some(vec![60_000]);
        Hub::new(cfg.clone(), crate::store::open(&cfg.store, dir).unwrap())
    };
    let source = hub_at(&dirs[0]);
    let (session, _conn) = another_chat(&source).await;
    source.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    source.claim_subagent(&session, "s/t1", 1).unwrap();
    assert!(retry_open(&session));
    let bundle = source.export(&session, &dirs[2]).unwrap();

    let here = hub_at(&dirs[1]);
    let imported = here.import(&bundle, Some("imported".into())).await.unwrap();
    assert!(imported.meta().name_given, "a name the import gives is someone's (`acpmux ls`)");
    let entry = last_entry(&here, &imported, "s/t1").unwrap();
    assert!(none_in_flight(&entry) && entry["retry"].is_null(), "{entry}");
    assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(false)));
    assert!(!retry_open(&imported));
    for dir in &dirs {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// A chat whose queue a failed turn paused (a 503) holds a subagent retry prompt when the
/// daemon restarts. That retry was the old daemon's: the restored queue loses the prompt at
/// once, logged as removed so a later load does not bring it back, and keeps the person's own
/// prompt held behind it. Before, the paused queue never reached it, so it sat there for good.
#[tokio::test]
async fn a_restored_paused_queue_loses_an_unsent_subagent_retry_prompt() {
    let dir = std::env::temp_dir().join(format!("acpmux-stale-retry-{}", uuid::Uuid::now_v7()));
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg.auto_resume_delays_ms = Some(vec![60_000]);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let (session, conn) = another_chat(&hub).await;
    let id = session.id.clone();
    let retry_id = "subagent-retry-t9-1-1";
    let queued = |prompt_id: &str, turn_id: &str, provenance: Option<Value>| {
        let mut msg = json!({"text": "waits", "client": "acpmux", "position": 1,
            "promptId": prompt_id, "turnId": turn_id, "control": "local",
            "prompt": [{"type": "text", "text": "waits"}]});
        if let Some(p) = provenance {
            msg["_meta"] = json!({"provenance": p});
        }
        msg
    };
    let provenance = json!({"kind": PROVENANCE_KIND, "subagentId": "s/t9",
        "agentId": "agent-s/t9", "attempt": 1});
    hub.append(&session, "mux", "queued", queued(retry_id, "t-retry", Some(provenance)));
    hub.append(&session, "mux", "queued", queued("p-own", "t-own", None));
    // The turn ahead of them failed: both held until the person resumes the queue.
    hub.append(
        &session,
        "mux",
        "queue_paused",
        json!({"turnId": "t-failed", "held": [retry_id, "p-own"]}),
    );
    hub.shutdown_all().await;
    drop((hub, session, conn));

    let reopen = || Hub::new(cfg.clone(), crate::store::open(&cfg.store, &dir).unwrap());
    let hub = reopen();
    let session = hub.resolve(&id).unwrap();
    hub.load_session_log(&session);
    let left: Vec<(String, bool)> =
        session.queue().into_iter().map(|q| (q.prompt_id, q.held)).collect();
    assert_eq!(left, [("p-own".to_owned(), true)], "the stale retry prompt is still queued");
    let removed: Vec<Value> = hub
        .events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "queue_removed" && e.msg["promptId"] == retry_id)
        .map(|e| e.msg)
        .collect();
    assert_eq!(removed.len(), 1, "{removed:?}");
    assert_eq!(removed[0]["reason"], PROVENANCE_KIND, "{removed:?}");
    hub.shutdown_all().await;
    drop((hub, session));

    // The next load restores the person's prompt only.
    let hub = reopen();
    let session = hub.resolve(&id).unwrap();
    hub.load_session_log(&session);
    let left: Vec<String> = session.queue().into_iter().map(|q| q.prompt_id).collect();
    assert_eq!(left, ["p-own"]);
    hub.shutdown_all().await;
    drop((hub, session));
    let _ = std::fs::remove_dir_all(&dir);
}
