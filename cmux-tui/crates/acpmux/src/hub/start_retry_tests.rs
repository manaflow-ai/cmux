use super::*;

#[test]
fn the_waits_scale_with_the_start_budget() {
    assert_eq!(first_wait(Duration::from_secs(90)), Duration::from_secs(10));
    assert_eq!(first_wait(Duration::from_millis(300)), Duration::from_millis(100));
    assert_eq!(first_wait(Duration::from_secs(3600)), Duration::from_secs(30));
}

#[test]
fn only_a_missed_start_deadline_is_retried() {
    let late = RpcError::deadline_exceeded("agent_start", Duration::from_secs(90));
    assert!(is_start_deadline(&late));
    assert!(!is_start_deadline(&RpcError::deadline_exceeded("session/load", Duration::ZERO)));
    assert!(!is_start_deadline(&RpcError::internal("agent process closed")));
    let gave_up = gave_up(late, 4);
    assert!(gave_up.message.contains("agent_start did not finish within"), "{gave_up:?}");
    assert!(gave_up.message.ends_with("tried 4 times"), "{gave_up:?}");
}

const WAIT: Duration = Duration::from_secs(30);

/// A hub whose one chat's agent is stopped and starts only once the returned gate file
/// exists (`FAKE_START_GATE`, removed), under a start budget of `budget_ms`.
async fn gated(budget_ms: u64) -> (Arc<Hub>, Arc<Session>, std::path::PathBuf) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let gate = std::env::temp_dir().join(format!("acpmux-retry-{}", uuid::Uuid::now_v7()));
    std::fs::write(&gate, b"").unwrap();
    let env = format!("FAKE_START_GATE={}", gate.display());
    let cfg = json!({"harnesses": {"fake": {"argv": ["/usr/bin/env", env, "python3", fake]}},
        "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    hub.kill(&s, false).await.unwrap();
    std::fs::remove_file(&gate).unwrap();
    hub.config.write().await.agent_start_timeout_ms = Some(budget_ms);
    (hub, s, gate)
}

fn send(hub: &Arc<Hub>, s: &Arc<Session>) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, s) = (hub.clone(), s.clone());
    let blocks = vec![json!({"type": "text", "text": "hello"})];
    tokio::spawn(async move { hub.prompt(&s, blocks, "test", false).await })
}

fn kinds(hub: &Hub, s: &Session, kind: &str) -> Vec<Value> {
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    events.into_iter().filter(|e| e.kind == kind).map(|e| e.msg).collect()
}

async fn until(what: &str, check: impl Fn() -> bool) {
    let wait = async {
        while !check() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    };
    tokio::time::timeout(WAIT, wait).await.unwrap_or_else(|_| panic!("{what}"));
}

/// Review finding: a Stop that came just after the wait's last check, as the retry's start
/// began, let that whole start run on (another missed deadline, or an agent left up for a
/// stopped turn). The Stop ends the retry's start as a stop of the chat ends any start. The
/// 9 s budget waits 1 s before the retry; the Stop lands inside its start.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_while_the_retrys_start_runs_ends_that_start() {
    let (hub, s, gate) = gated(9_000).await;
    let run = send(&hub, &s);
    until("the start was never tried again", || {
        !kinds(&hub, &s, "agent_start_retrying").is_empty()
    })
    .await;
    until("the retry's start never began", || {
        s.start_retry_cancels.load(Ordering::SeqCst) != NO_RETRY && s.spawn_lock.try_lock().is_err()
    })
    .await;
    let stopped_at = std::time::Instant::now();
    let _ = hub.cancel(&s).await;
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt never ended").unwrap();
    let took = stopped_at.elapsed();
    let e = answer.expect_err("a stopped prompt was answered");
    assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("stopped")), "{e:?}");
    assert!(took < Duration::from_secs(5), "the retry's start ran on for {took:?} after the Stop");
    assert_eq!(kinds(&hub, &s, "agent_start_timed_out").len(), 1, "the retry's start ran out");
    assert_eq!(kinds(&hub, &s, "agent_start_stopped").len(), 1);
    assert!(s.child.lock().await.is_none(), "the stopped start's agent was left up");
    let results = kinds(&hub, &s, "turn_result");
    assert_eq!(results.last().unwrap()["status"], "cancelled", "{results:?}");
    let _ = std::fs::remove_file(&gate);
}

/// Review finding: a shutdown that began after the give-up's own check, before its turn
/// was ended, still got a failed end, which kept the next daemon from queueing the prompt
/// again. The end is decided under the shutdown's lock, and a shutdown that began settles it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_shutdown_after_the_give_up_check_still_settles_the_turn() {
    let (hub, s, gate) = gated(900).await;
    let late = RpcError::deadline_exceeded("agent_start", Duration::from_millis(900));
    // The give-up passed its checks (no shutdown yet), then the shutdown began.
    let e = gave_up(late, 4);
    hub.begin_shutdown();
    let joined = super::super::digest::DigestTurn::default();
    let failed = hub.fail_unless_shutdown_settles(&s, "p", "t", &e, &joined, None);
    assert!(!failed, "the turn was failed under the shutdown");
    let ended = kinds(&hub, &s, "turn_result");
    assert!(ended.iter().all(|m| m["turnId"] != "t"), "{ended:?}");
    // A Stop's end is still the Stop's.
    let stopped = super::super::turns::stopped_before_prompt();
    assert!(hub.fail_unless_shutdown_settles(&s, "p2", "t2", &stopped, &joined, None));
    let _ = std::fs::remove_file(&gate);
}

/// Review finding: the shutdown began under another lock than the one this end is decided
/// under, so it could begin between the check and the failed end's write. Held between
/// the two, the end keeps the shutdown from beginning until its write is done.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_shutdown_cannot_begin_between_the_check_and_the_failed_end() {
    let (hub, s, gate) = gated(900).await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.settle_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let ending = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::task::spawn_blocking(move || {
            let late = RpcError::deadline_exceeded("agent_start", Duration::from_millis(900));
            let joined = super::super::digest::DigestTurn::default();
            hub.fail_unless_shutdown_settles(&s, "p", "t", &gave_up(late, 4), &joined, None)
        })
    };
    tokio::time::timeout(WAIT, arrived).await.expect("the end never reached its write").ok();
    // The shutdown begins now, from another thread, while the end holds before its write.
    let (began_tx, began) = std::sync::mpsc::channel();
    let shutting = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            hub.begin_shutdown();
            let _ = began_tx.send(());
        })
    };
    let began_first = began.recv_timeout(Duration::from_secs(1)).is_ok();
    release.send(()).unwrap();
    let failed = ending.await.unwrap();
    shutting.join().unwrap();
    assert!(!began_first, "the shutdown began between the check and the failed end's write");
    // Checked before the shutdown began: the turn's failure is its own, written before it.
    assert!(failed);
    let ended = kinds(&hub, &s, "turn_result");
    assert!(ended.iter().any(|m| m["turnId"] == "t" && m["status"] == "failed"), "{ended:?}");
    let _ = std::fs::remove_file(&gate);
}

/// Review finding: a person's prompt while a lane's retry waited made the retry's start
/// wait on its harness with no deadline, and that wait did not race the Stop: the Stop
/// could not end the start, and its agent stayed up. The Stop ends it however it waits.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_ends_a_retrys_start_after_the_person_took_the_chat() {
    let (hub, s, gate) = gated(9_000).await;
    let run = send(&hub, &s);
    until("the start was never tried again", || {
        !kinds(&hub, &s, "agent_start_retrying").is_empty()
    })
    .await;
    // The person writes in the chat: its next start waits on its harness.
    s.person.store(true, Ordering::SeqCst);
    until("the retry's start never began", || {
        s.start_retry_cancels.load(Ordering::SeqCst) != NO_RETRY && s.spawn_lock.try_lock().is_err()
    })
    .await;
    let stopped_at = std::time::Instant::now();
    let _ = hub.cancel(&s).await;
    let answer = tokio::time::timeout(WAIT, run).await.expect("the Stop did not end the start");
    let took = stopped_at.elapsed();
    let e = answer.unwrap().expect_err("a stopped prompt was answered");
    assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("stopped")), "{e:?}");
    assert!(took < Duration::from_secs(5), "the start ran on for {took:?} after the Stop");
    assert_eq!(kinds(&hub, &s, "agent_start_stopped").len(), 1);
    assert!(s.child.lock().await.is_none(), "the stopped start's agent was left up");
    let _ = std::fs::remove_file(&gate);
}

/// Review finding: the last try missing its deadline as a shutdown begins gave up with a
/// failed end, which the turn wrote before the shutdown took it, so the next daemon did not
/// queue the prompt again. The shutdown settles it instead.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_shutdown_as_the_last_try_misses_leaves_the_turn_to_the_shutdown() {
    let (hub, s, gate) = gated(900).await;
    // Reopened, as the prompt whose start this is reopens its stopped chat.
    assert!(hub.reopen(&s, s.stops.load(Ordering::SeqCst)), "the chat did not reopen");
    hub.begin_shutdown();
    let late = RpcError::deadline_exceeded("agent_start", Duration::from_millis(900));
    let (stops, cancels) = (s.stops.load(Ordering::SeqCst), s.cancels.load(Ordering::SeqCst));
    let ended = hub.retry_late_start_with(&s, stops, cancels, "p", "t", Err(late), 0).await;
    let Err(e) = ended else { panic!("a start ran under the shutdown") };
    let joined = super::super::digest::DigestTurn::default();
    let failed = hub.fail_unless_shutdown_settles(&s, "p", "t", &e, &joined, None);
    assert!(!failed, "the turn wrote a failed end: {e:?}");
    let _ = std::fs::remove_file(&gate);
}

/// A shutdown while a prompt's start waits to be tried again ends the wait, and the turn
/// writes no failed end: the shutdown settles it, and the next daemon finds the prompt
/// unstarted and queues it again (`unstarted_prompt.rs`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_shutdown_during_the_wait_leaves_the_turn_to_the_shutdown() {
    // A 900 ms budget waits 100 ms before its first retry.
    let (hub, s, gate) = gated(900).await;
    let run = send(&hub, &s);
    let kinds = |kind: &str| kinds(&hub, &s, kind);
    let retrying = async {
        while kinds("agent_start_retrying").is_empty() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    };
    tokio::time::timeout(WAIT, retrying).await.expect("the start was never tried again");
    hub.begin_shutdown();
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt never ended").unwrap();
    assert!(answer.is_err(), "{answer:?}");
    let turn = kinds("agent_start_retrying")[0]["turnId"].clone();
    let ended: Vec<_> = kinds("turn_result").into_iter().filter(|m| m["turnId"] == turn).collect();
    assert!(ended.is_empty(), "the turn wrote its own end under the shutdown: {ended:?}");
    assert!(kinds("turn_started").iter().all(|m| m["turnId"] != turn));
    // Still open for the shutdown to hand on or end.
    assert_eq!(s.turn().map(|t| json!(t.turn_id)), Some(turn));
    assert_eq!(kinds("agent_start_retrying").len(), 1, "a start ran after the shutdown");
    let _ = std::fs::remove_file(&gate);
}

/// Cloud chaos fault `daemon-restart-session-new` (staging, f1c3afd06): the daemon got
/// SIGTERM while a chat's first prompt started its agent, and the prompt was answered with
/// what the shutdown did to that start ("no agent session", "agent process closed"), which
/// the CLI types as a non-retryable `agent_error`. The shutdown hands the turn to the next
/// daemon, so the prompt hears that the daemon is restarting, as a restart mid-turn does.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restart_while_the_agent_starts_answers_that_the_daemon_restarts() {
    // A 9 s budget: the start is in flight, not waiting to be tried again.
    let (hub, s, gate) = gated(9_000).await;
    let run = send(&hub, &s);
    until("the agent start never began", || {
        s.spawn_lock.try_lock().is_err() && s.child.try_lock().is_ok_and(|c| c.is_some())
    })
    .await;
    hub.shutdown_all().await;
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt never ended").unwrap();
    let e = answer.expect_err("a prompt whose agent never started was answered");
    assert_eq!(e.message, crate::hub::SHUTTING_DOWN, "{e:?}");
    // The next daemon queues it again (`unstarted_prompt.rs`): no end of its own.
    let ended = kinds(&hub, &s, "turn_result");
    assert!(ended.iter().all(|m| m["status"] != "failed"), "{ended:?}");
    let _ = std::fs::remove_file(&gate);
}

/// A lane VM's chat (2026-11-25): the store refused its turn's start on a
/// full disk, the turn ended failed with nothing scheduled, and the chat sat stranded until a
/// person retried it. Leo: "clearly we need to auto cleanup harder and faster/share stuff more
/// so we dont have to manually go through this". The refused turn now waits for room as a turn
/// a full disk cut does, then goes on once; a trigger's, or a turn with no rules, does not.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_turn_the_store_refused_on_a_full_disk_goes_on_once_it_has_room() {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.auto_resume_delays_ms = Some(vec![20; 3]);
    // No disk has this much free: the disk reads full until the floor drops.
    cfg.auto_resume_disk_free_bytes = Some(u64::MAX);
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let refused = RpcError::internal(
        "no space left on device: /home/u/.acpmux is full; acpmux stores nothing until it has 16 MiB free",
    );
    let joined = super::super::digest::DigestTurn::default();
    let rules = super::super::auto_resume::RefusedRules {
        control: Control::default(),
        trust_gate: false,
        from: None,
        slash: Some("/compact --all"),
        goes_on: true,
    };
    // No rules (a caller that keeps none): ended failed, nothing scheduled.
    hub.fail_unstarted_turn(&s, "p0", "t0", &refused, &joined, None);
    // A prompt no cut turn of goes on for (a cache compaction's, a cold wake's): the same.
    let quiet = super::super::auto_resume::RefusedRules { goes_on: false, ..rules };
    hub.fail_unstarted_turn(&s, "p1", "t1", &refused, &joined, Some(&quiet));
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(kinds(&hub, &s, "auto_resume_scheduled").is_empty(), "a turn with no rules went on");

    hub.fail_unstarted_turn(&s, "p", "t", &refused, &joined, Some(&rules));
    let ended = kinds(&hub, &s, "turn_result");
    assert_eq!(ended.last().unwrap()["errorKind"], crate::recovery::kind::DISK_FULL, "{ended:?}");
    until("the refused turn was never scheduled to go on", || {
        !kinds(&hub, &s, "auto_resume_scheduled").is_empty()
    })
    .await;
    let scheduled = kinds(&hub, &s, "auto_resume_scheduled");
    assert_eq!(scheduled[0]["reason"], "disk", "{scheduled:?}");
    // A newer prompt the store refused while that one waits takes the wait over: the older
    // one is past (it skips as superseded), and the newer one is not left stranded.
    hub.fail_unstarted_turn(&s, "p2", "t2", &refused, &joined, Some(&rules));
    until("the newer refused turn was never scheduled", || {
        kinds(&hub, &s, "auto_resume_scheduled").iter().any(|m| m["turnId"] == "t2")
    })
    .await;
    // Well past its 20 ms wait: still waiting, on the disk.
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(kinds(&hub, &s, "user_message").is_empty(), "it went on with the disk still full");

    // The disk has room again: it goes on once, saying why it stopped.
    hub.config.write().await.auto_resume_disk_free_bytes = Some(0);
    let resumed = |m: &Value| m["promptId"] == "p2~resume-1" && m["status"] == "completed";
    let went_on = async {
        while !kinds(&hub, &s, "turn_result").iter().any(resumed) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    };
    if tokio::time::timeout(WAIT, went_on).await.is_err() {
        let log: Vec<_> =
            hub.events(&s.id, 0, 100_000).unwrap().into_iter().map(|e| (e.kind, e.msg)).collect();
        panic!("the refused turn never went on: {log:?}");
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    let messages = kinds(&hub, &s, "user_message");
    let ids: Vec<&Value> = messages.iter().map(|m| &m["promptId"]).collect();
    assert_eq!(ids, [&json!("p2~resume-1")], "{messages:?}");
    let text = messages[0]["text"].as_str().unwrap_or_default();
    assert_eq!(text, "/compact --all", "a refused compaction must be resent as itself");
    let skipped = kinds(&hub, &s, "auto_resume_skipped");
    assert!(skipped.iter().all(|m| m["turnId"] == "t"), "{skipped:?}");
}
