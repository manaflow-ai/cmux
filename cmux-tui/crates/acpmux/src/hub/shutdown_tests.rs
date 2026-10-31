//! A restart hands a running turn to the next daemon (`shutdown.rs`): the old daemon writes no end
//! of its own for it, whether the shutdown took the turn or its end was already under way, so the
//! next daemon finds the turn cut and continues it (`restart_resume.rs`).

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub on the stand-in agent, its store in `dir`.
fn hub_in(dir: &std::path::Path) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// A hub on the stand-in agent with `env`, whose agent messages wait in the queue (no inbox).
fn queue_hub_in(dir: &std::path::Path, env: Value) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let harness = json!({"argv": ["python3", fake], "env": env});
    let cfg = json!({"harnesses": {"fake": harness}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg.agent_inbox = Some(false);
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// Waits, bounded, until `done`.
async fn until(what: &str, done: impl Fn() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !done() {
        assert!(tokio::time::Instant::now() < deadline, "never: {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The `kind` records of the chat's log.
fn records(hub: &Hub, s: &Session, kind: &str) -> Vec<Value> {
    let records = hub.events(&s.id, 0, 100_000).unwrap();
    records.into_iter().filter(|r| r.kind == kind).map(|r| r.msg).collect()
}

/// The turn's end was under way when the shutdown began (Sol review of #28503): its agent died,
/// `finish_turn` took the turn and is held there, so the shutdown finds no turn to take. Let go
/// after the shutdown began, the end writes nothing, and the next daemon continues the turn.
#[tokio::test]
async fn a_turn_whose_end_was_under_way_at_a_restart_is_continued_by_the_next_daemon() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let opts = PromptOptions { prompt_id: Some("p-cut".to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "die-later: gone"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the end took the turn before the shutdown");
    hub.shutdown_all_with_auto_resume(true).await;
    let _ = release.send(());
    let answer = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    assert!(answer.is_err(), "{answer:?}");
    for kind in ["turn_result", "turn_error", "auto_resume_scheduled"] {
        let late = records(&hub, &s, kind);
        assert!(late.is_empty(), "the old daemon wrote a {kind} after the shutdown: {late:?}");
    }
    let id = s.id.clone();
    drop(s);
    drop(hub);

    let hub = hub_in(&dir);
    let s = hub.resolve(&id).unwrap();
    hub.session_log(&s).await;
    let queued = records(&hub, &s, "queued");
    assert!(
        queued.iter().any(|m| m["promptId"] == "p-cut~resume-1"),
        "the cut turn's continuation was not queued: {queued:?}"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A route switch asked during a turn moves the chat when the turn ends (`route_switch.rs`), but
/// not once a shutdown began (Sol review of #28503): the agent the shutdown left for the next
/// daemon (here one whose child it could not reach) stays alive, unkilled by a restart that could
/// not start it again anyway.
#[tokio::test]
async fn a_turn_ending_after_a_shutdown_began_leaves_the_kept_agent_to_the_next_daemon() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt_with(&s, blocks, "test", false, PromptOptions::default()).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    s.route_switch.store(true, Ordering::SeqCst);
    let child = s.child.lock().await.clone().expect("the turn's agent");
    {
        // The shutdown cannot reach this child: it keeps it for the next daemon.
        let _held = s.child.lock().await;
        hub.shutdown_all().await;
    }
    let _ = release.send(());
    let answer = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    assert!(answer.is_ok(), "{answer:?}");
    let kept = s.child.lock().await.clone();
    assert!(kept.is_some_and(|c| Arc::ptr_eq(&c, &child)), "the turn's end took the kept agent");
    assert!(child.is_alive().await, "the turn's end killed the agent the shutdown kept");
    child.kill().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// What the old daemon writes once its shutdown is done can land after the next daemon read the
/// log (it lets go of `daemon.lock` before its process exits; Sol review of #28503), so it
/// writes nothing then: a turn whose answer came after is cut, and the next daemon continues it.
#[tokio::test]
async fn a_turn_answered_after_the_shutdown_writes_nothing_and_is_continued() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let opts = PromptOptions { prompt_id: Some("p-late".to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    hub.shutdown_all_with_auto_resume(true).await;
    let _ = release.send(());
    let answer = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    assert!(answer.is_ok(), "{answer:?}");
    let late = records(&hub, &s, "turn_result");
    assert!(late.is_empty(), "the old daemon wrote after its shutdown: {late:?}");
    let started = records(&hub, &s, "turn_started");
    let cut = started.last().expect("the turn started")["turnId"].clone();
    let id = s.id.clone();
    drop(s);
    drop(hub);

    let hub = hub_in(&dir);
    let s = hub.resolve(&id).unwrap();
    hub.session_log(&s).await;
    let queued = records(&hub, &s, "queued");
    assert!(
        queued.iter().any(|m| m["promptId"] == "p-late~resume-1"),
        "the cut turn's continuation was not queued: {queued:?}"
    );
    // The next daemon settles the cut turn as of unknown outcome; nothing says it completed.
    let ends = records(&hub, &s, "turn_result");
    let completed = ends.iter().filter(|m| m["turnId"] == cut && m["status"] == "completed");
    assert_eq!(completed.count(), 0, "the cut turn reads completed: {ends:?}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// Every path that ends an agent between turns (a route switch, an update's restart, an adopted
/// agent's `restart_unproven`) goes through `detach_child`, which leaves the agent a shutdown
/// handed to the next daemon alone, also when it was called before the shutdown began.
#[tokio::test]
async fn a_detach_after_a_handing_off_shutdown_leaves_the_kept_agent() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    hub.prompt_with(&s, blocks, "test", false, PromptOptions::default()).await.unwrap();
    let child = s.child.lock().await.clone().expect("the chat's agent");
    let held = s.child.lock().await;
    // A detach waits for the child lock, as one that began just before the shutdown would.
    let detach = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.detach_child(&s).await })
    };
    // The shutdown cannot reach this child: it keeps it for the next daemon.
    hub.shutdown_all().await;
    drop(held);
    tokio::time::timeout(WAIT, detach).await.unwrap().unwrap();
    let kept = s.child.lock().await.clone();
    assert!(kept.is_some_and(|c| Arc::ptr_eq(&c, &child)), "the detach took the kept agent");
    assert!(child.is_alive().await, "the detach killed the agent the shutdown kept");
    child.kill().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A turn of agent messages a restart cuts goes on in the next daemon with every message's words
/// (its `user_message` holds all that joined it, `restart_resume.rs`): the old daemon puts none of
/// them back in its queue, or the next one would run them twice (Sol review of #28503).
#[tokio::test]
async fn a_cut_turn_of_agent_messages_puts_none_of_them_back() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = queue_hub_in(&dir, json!({"FAKE_UNTIL_CANCEL_IN": "hang-here"}));
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let send = |text: &str, opts: PromptOptions| {
        let (hub, s) = (hub.clone(), s.clone());
        let blocks = vec![json!({"type": "text", "text": text})];
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    let busy = send("until-cancel", PromptOptions::default());
    until("the busy turn runs", || s.turn().is_some()).await;
    let from = |id: &str| PromptOptions {
        prompt_id: Some(id.to_owned()),
        agent: Some("lane-a".to_owned()),
        ..PromptOptions::default()
    };
    let a = send("from a, hang-here", from("p-a"));
    until("a waits", || s.queued() == 1).await;
    let b = send("from b", from("p-b"));
    until("b waits", || s.queued() == 2).await;
    hub.cancel(&s).await.unwrap();
    until("a's turn takes b", || s.queued() == 0 && s.turn().is_some_and(|t| t.prompt_id == "p-a"))
        .await;
    hub.shutdown_all().await;
    for task in [busy, a, b] {
        let _ = tokio::time::timeout(WAIT, task).await.unwrap().unwrap();
    }
    let queue: Vec<String> = s.queue.lock().unwrap().iter().map(|q| q.prompt_id.clone()).collect();
    assert!(queue.is_empty(), "the old daemon put the cut turn's messages back: {queue:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Quit Everything (`endAgents`) ends every turn in progress as cancelled, also one whose end was
/// under way and held past the shutdown's grace (Sol review of #28503): the shutdown found no turn
/// to take, and the held end lands after the seal. The log holds that turn's one end, cancelled,
/// and nothing retries it.
#[tokio::test]
async fn quit_everything_ends_a_turn_whose_end_was_under_way_as_cancelled() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let opts = PromptOptions { prompt_id: Some("p-quit".to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "die-later: gone"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
    let _ = release.send(());
    let _ = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    let ends = records(&hub, &s, "turn_result");
    assert_eq!(ends.len(), 1, "the turn's ends: {ends:?}");
    assert_eq!((&ends[0]["status"], &ends[0]["detail"]), (&json!("cancelled"), &json!("quit")));
    let retries = records(&hub, &s, "auto_resume_scheduled");
    assert!(retries.is_empty(), "a turn Quit Everything ended was retried: {retries:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// An answer that comes in while a restart's shutdown drains (its end under way when the
/// shutdown began, held a moment) is the turn's end: the old daemon writes it whole, the
/// shutdown hands nothing on, and the next daemon continues nothing (router review of #28503).
/// Never a handed-on turn with an end, nor one with half of one.
#[tokio::test]
async fn an_answer_that_lands_while_the_shutdown_drains_ends_the_turn_once() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let opts = PromptOptions { prompt_id: Some("p-drain".to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    let mut shutdown = {
        let hub = hub.clone();
        tokio::spawn(async move { hub.shutdown_all().await })
    };
    until("the shutdown began", || hub.shutting_down()).await;
    // The answer lands while the shutdown drains: a shutdown that does not wait for it is done
    // by now, one that does is still waiting.
    let _ = tokio::time::timeout(Duration::from_millis(500), &mut shutdown).await;
    let _ = release.send(());
    let answer = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    assert!(answer.is_ok(), "{answer:?}");
    let _ = tokio::time::timeout(WAIT, shutdown).await.unwrap();
    let ends = records(&hub, &s, "turn_result");
    let started = records(&hub, &s, "turn_started");
    let cut = started.last().expect("the turn started")["turnId"].clone();
    let id = s.id.clone();
    drop(s);
    drop(hub);

    let hub = hub_in(&dir);
    let s = hub.resolve(&id).unwrap();
    hub.session_log(&s).await;
    let mine: Vec<_> = ends.iter().filter(|m| m["turnId"] == cut).collect();
    assert_eq!(mine.len(), 1, "the turn's ends: {ends:?}");
    assert_eq!(mine[0]["status"], "completed", "{mine:?}");
    let queued = records(&hub, &s, "queued");
    assert!(
        !queued.iter().any(|m| m["promptId"] == "p-drain~resume-1"),
        "a turn that ended was continued: {queued:?}"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A shutdown that meets a detach ending its agent waits for that end (router review of #28503):
/// the agent's kill takes up to its grace (`KILL_GRACE`), longer than the shutdown waits for the
/// child lock, and a shutdown that gave up counted the agent kept while the detach ended it.
#[tokio::test]
async fn a_shutdown_waits_for_a_detach_that_is_ending_its_agent() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = queue_hub_in(&dir, json!({"FAKE_IGNORE_TERM": "1"}));
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    hub.prompt_with(&s, blocks, "test", false, PromptOptions::default()).await.unwrap();
    let child = s.child.lock().await.clone().expect("the chat's agent");
    let detach = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.detach_child(&s).await })
    };
    until("the detach holds the child lock", || s.child.try_lock().is_err()).await;
    hub.shutdown_all().await;
    assert!(detach.is_finished(), "the shutdown went on while a detach ended the agent");
    assert!(!child.is_alive().await, "the detach did not end its agent");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A retry whose turn was cut before a shutdown began sets no wait once it began, however late
/// its task gets there (router review of #28503): a cut handed on is the next daemon's to
/// continue, Quit Everything continues nothing, and the wait is what the next daemon restores.
#[tokio::test]
async fn a_retry_set_after_a_shutdown_began_waits_for_nothing() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    hub.config.write().await.auto_resume_delays_ms = Some(vec![120_000]);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.retry_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let blocks = vec![json!({"type": "text", "text": "die-later: gone"})];
    let answer = hub.prompt_with(&s, blocks, "test", false, PromptOptions::default()).await;
    assert!(answer.is_err(), "{answer:?}");
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    hub.end_agents_at_shutdown(Default::default()).unwrap();
    hub.shutdown_all().await;
    let _ = release.send(());
    until("the retry's task settled", || {
        hub.retry_row(&s, None).0.is_some() || !hub.continuation_pending(&s)
    })
    .await;
    let waits = hub.retry_row(&s, None).0;
    assert!(waits.is_none(), "a retry waits after the shutdown began: {waits:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
