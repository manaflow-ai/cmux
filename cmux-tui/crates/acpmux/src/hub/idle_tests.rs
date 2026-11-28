//! What keeps a session awake (`idle_eligible`): each of the gates a hub test can hold by hand.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

#[cfg(unix)]
#[tokio::test]
async fn automatic_restart_after_harness_update_waits_for_unreported_work() {
    use std::{fs, os::unix::fs::PermissionsExt, time::Duration};

    let root = tempfile::tempdir().unwrap();
    let home = &root.path().canonicalize().unwrap();
    let version = home.join("version");
    let program = home.join(".local/share/claude/versions/fake-harness");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    fs::create_dir_all(program.parent().unwrap()).unwrap();
    fs::write(&version, "2.0.5\n").unwrap();
    fs::write(
        &program,
        format!(
            r#"#!/bin/sh
case "$1" in
  --version) cat '{version}' ;;
  update) echo 2.0.9 > '{version}' ;;
  *) export TEST_HARNESS_VERSION="$(cat '{version}')"; exec python3 '{fake}' "$@" ;;
esac
"#,
            version = version.display(),
        ),
    )
    .unwrap();
    fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": [program]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, home).unwrap();
    let hub = Hub::new(cfg, store);
    let clock = crate::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(Some(Duration::from_secs(300)));
    let cache = home.join("health.json");
    let settings = crate::harness_health::Settings {
        home: home.into(),
        cache: Some(cache.clone()),
        auto_update: Some(home.join("auto-update.json")),
        ..Default::default()
    };
    // Use a real local version check and update plan with a cached registry answer.
    hub.health.attach(settings.clone());
    let mut rows = hub.health.check(hub.health_subjects().await, false).await;
    assert_eq!(rows[0].version.as_deref(), Some("2.0.5"));
    rows[0].latest = Some("2.0.9".into());
    rows[0].latest_checked_at = Some(crate::store::now_ms());
    fs::write(&cache, serde_json::to_vec(&rows).unwrap()).unwrap();
    hub.health.attach(settings);

    let session =
        hub.new_session(NewRequest { cwd: Some(home.into()), ..Default::default() }).await.unwrap();
    let prompt = |text: String| vec![json!({"type": "text", "text": text})];
    let probe = home.join("child.json");
    hub.prompt(&session, prompt(format!("class-probe: {}", probe.display())), "test", false)
        .await
        .unwrap();
    assert!(hub.idle_eligible(&session), "work must be invisible to the ordinary gates");
    let before = hub.child_for(&session).await.unwrap();
    assert_eq!(hub.auto_update_harnesses().await, vec!["fake".to_owned()]);
    assert_eq!(hub.health.rows()[0].version.as_deref(), Some("2.0.9"));
    assert!(
        Arc::ptr_eq(&before, &hub.child_for(&session).await.unwrap()),
        "the updater replaced the harness while an unreported child was running"
    );

    clock.advance(quiet_respawn());
    hub.stop_idle_children().await;
    assert_ne!(session.idle_refusal_logged.load(Ordering::Relaxed), 0);
    assert!(Arc::ptr_eq(&before, &hub.child_for(&session).await.unwrap()));

    let child: Value = serde_json::from_slice(&fs::read(&probe).unwrap()).unwrap();
    let pid = child["sleeper"].as_u64().unwrap() as u32;
    // SAFETY: the fake harness just recorded this test's sleeper.
    assert_eq!(unsafe { libc::kill(pid as i32, libc::SIGKILL) }, 0);
    let harness_pid = before.pid.unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while !crate::agent_host::tree::under_shared(harness_pid)
            .is_some_and(|children| children.iter().all(|child| child.pid != pid))
        {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the sleeper ended");

    // A census refusal backs off to the normal idle period.
    clock.advance(Duration::from_secs(301));
    hub.stop_idle_children().await;
    assert!(session.child.lock().await.is_none());
    assert!(hub.waking(&session));

    hub.prompt(&session, prompt("env: TEST_HARNESS_VERSION".into()), "test", false).await.unwrap();
    assert!(!Arc::ptr_eq(&before, &hub.child_for(&session).await.unwrap()));
    let events = hub.events(&session.id, 0, 1000).unwrap();
    assert!(events.iter().any(|e| {
        e.msg.pointer("/params/update/content/text").and_then(Value::as_str)
            == Some("TEST_HARNESS_VERSION=2.0.9")
    }));
    assert!(!hub.waking(&session));
    hub.shutdown_all().await;
}

/// A ready chat with nothing going on is idle; an agent request waiting on its answer, a
/// sub-session at work, a stored-less Claude chat with turns, and a queued prompt each keep it.
#[tokio::test]
async fn each_gate_keeps_a_session_awake() {
    let (hub, session) = chat().await;
    assert!(hub.idle_eligible(&session), "a ready chat with nothing going on");
    {
        let _asked = AgentRequest::new(&session);
        assert!(!hub.idle_eligible(&session), "an agent request on its way");
    }
    assert!(hub.idle_eligible(&session));
    *session.work_below_since.lock().unwrap() = 1;
    assert!(!hub.idle_eligible(&session), "a sub-session at work");
    *session.work_below_since.lock().unwrap() = 0;
    {
        let mut m = session.meta.lock().unwrap();
        m.claude_unstored = true;
        m.turn_count = 1;
    }
    assert!(hub.idle_eligible(&session), "a Claude chat whose unstored turns did no work");
    session.meta.lock().unwrap_or_else(|e| e.into_inner()).claude_unstored_work = true;
    assert!(!hub.idle_eligible(&session), "a Claude chat whose turns are not stored");
    session.meta.lock().unwrap().claude_unstored = false;
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(!hub.idle_eligible(&session), "a queued prompt");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    assert!(hub.idle_eligible(&session));
    hub.shutdown_all().await;
}

/// Under `adaptive-v1` a parent whose only work below is its open sub-sessions' sleeps through
/// it; `static` keeps it up as before.
#[tokio::test]
async fn adaptive_lets_a_parent_sleep_while_only_its_sub_sessions_work() {
    let (hub, session) = chat().await;
    *session.work_below_since.lock().unwrap() = 1;
    assert!(!hub.idle_eligible(&session), "static: a sub-session at work keeps it");
    hub.set_idle_policy(IdlePolicyKind::AdaptiveV1);
    assert!(hub.idle_eligible(&session), "adaptive-v1: its sub-sessions run in their own harness");
    hub.set_idle_policy(IdlePolicyKind::Static);
    assert!(!hub.idle_eligible(&session));
    *session.work_below_since.lock().unwrap() = 0;
    assert!(hub.idle_eligible(&session));
    hub.shutdown_all().await;
}

/// A chat stored as hibernated comes back marked (after a restart it wakes for a turn), and
/// clearing the hibernation drops the mark, a cause a wake recorded, and the stored flag.
#[tokio::test]
async fn a_stored_hibernation_comes_back_and_clearing_it_drops_every_trace() {
    let (hub, session) = chat().await;
    let mut meta = session.meta();
    meta.hibernated_ms = 1;
    meta.id = format!("{}-restored", meta.id);
    let restored = hub.make_session(meta);
    assert_ne!(restored.hibernated_at.load(Ordering::SeqCst), 0, "a restart lost the hibernation");
    hub.wake_cause(&restored, "click");
    hub.clear_hibernation(&restored);
    assert_eq!(restored.hibernated_at.load(Ordering::SeqCst), 0);
    assert!(restored.wake_cause.lock().unwrap().is_none(), "a stale wake cause");
    assert_eq!(restored.meta().hibernated_ms, 0);
    hub.shutdown_all().await;
}

/// A daemon still loading never counts as unused (`in_use`): each load it finishes after its
/// start keeps it, so a queued prompt or cut turn the last daemon left is resumed first.
#[tokio::test]
async fn a_daemon_still_loading_is_in_use() {
    let (hub, _session) = chat().await;
    for (gate, name) in [
        (&hub.startup_ready, "startup"),
        (&hub.adoption_ready, "adoption"),
        (&hub.logs_ready, "the chat logs"),
        (&hub.store_load.ready, "the store"),
    ] {
        gate.send_replace(false);
        assert_eq!(hub.in_use().await, Some("its startup"), "{name} still loading");
        gate.send_replace(true);
    }
}

/// A chat moving to another machine keeps the daemon until the move is committed or aborted: its
/// watch settles it, and the chat stays frozen here until then. A chat that moved away does not.
#[tokio::test]
async fn a_move_under_way_is_in_use() {
    let (hub, session) = chat().await;
    *session.moving.lock().unwrap() = Some("t-1".into());
    assert_eq!(hub.in_use().await, Some("a move under way"));
    session.meta.lock().unwrap().moved_to = Some(json!({}));
    assert_ne!(hub.in_use().await, Some("a move under way"), "a committed move");
}

/// The Cloud activity count holds a chat moving off this machine as at work too, so the machine is
/// not paused for idleness with the chat frozen mid-move; a committed move releases it.
#[tokio::test]
async fn a_move_under_way_is_at_work() {
    let (hub, session) = chat().await;
    *session.moving.lock().unwrap() = Some("t-1".into());
    let detail = hub.sessions_at_work_detail();
    assert_eq!(detail.len(), 1, "a move under way");
    assert!(!detail[0].turn && !detail[0].person && detail[0].processes == 0);
    session.meta.lock().unwrap().moved_to = Some(json!({}));
    assert!(hub.sessions_at_work_detail().is_empty(), "a committed move");
    hub.shutdown_all().await;
}

/// A Cloud machine's activity counts each session at work (`sessions_at_work`): a running turn
/// (the harness's own), a queued prompt and an agent request each count it once; with none, it
/// is not at work.
#[tokio::test]
async fn sessions_at_work_counts_a_running_turn_until_it_ends() {
    let (hub, session) = chat().await;
    assert_eq!(hub.sessions_at_work(), 0, "a ready chat with nothing going on");
    session.harness_turn.store(true, Ordering::SeqCst);
    assert_eq!(hub.sessions_at_work(), 1, "a running turn");
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert_eq!(hub.sessions_at_work(), 1, "one session, however much it does");
    session.harness_turn.store(false, Ordering::SeqCst);
    assert_eq!(hub.sessions_at_work(), 1, "a queued prompt");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    {
        let _asked = AgentRequest::new(&session);
        assert_eq!(hub.sessions_at_work(), 1, "an agent request on its way");
    }
    assert_eq!(hub.sessions_at_work(), 0, "the turn ended");
    *session.work_below_since.lock().unwrap() = 1;
    assert_eq!(hub.sessions_at_work(), 1, "a sub-session or background subagent at work");
    *session.work_below_since.lock().unwrap() = 0;
    assert_eq!(hub.sessions_at_work(), 0);
    hub.shutdown_all().await;
}

/// cmux#33327: a shell the harness left running in the background after its turn ended (a Claude
/// background shell) keeps its session at work, so a Cloud machine is not paused under it.
#[tokio::test]
async fn sessions_at_work_counts_a_background_process_the_turn_left_running() {
    let (hub, session) = chat().await;
    assert_eq!(hub.sessions_at_work(), 0);
    let shell = |state: &str| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": state, "command": "serve"}}});
    let rec = hub.append(&session, "in", "background_task_update", shell("running"));
    hub.note_process(&session, &rec, None);
    assert_eq!(hub.sessions_at_work(), 1, "a background shell still running");
    let rec = hub.append(&session, "in", "background_task_update", shell("completed"));
    hub.note_process(&session, &rec, None);
    assert_eq!(hub.sessions_at_work(), 0, "the shell ended");
    hub.shutdown_all().await;
}

/// cmux#34298: the activity report's phases read what holds each session at work: its turn,
/// and the processes it left running.
#[tokio::test]
async fn sessions_at_work_detail_says_what_holds_each_session() {
    let (hub, session) = chat().await;
    assert!(hub.sessions_at_work_detail().is_empty());
    session.harness_turn.store(true, Ordering::SeqCst);
    let detail = hub.sessions_at_work_detail();
    assert_eq!(detail.len(), 1);
    assert!(detail[0].turn && !detail[0].person && detail[0].processes == 0);
    assert_eq!(detail[0].id, session.id);
    session.harness_turn.store(false, Ordering::SeqCst);
    let shell = |state: &str| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": state, "command": "serve"}}});
    let rec = hub.append(&session, "in", "background_task_update", shell("running"));
    hub.note_process(&session, &rec, None);
    let detail = hub.sessions_at_work_detail();
    assert_eq!(detail.len(), hub.sessions_at_work());
    assert!(!detail[0].turn && detail[0].processes == 1, "a background shell, no turn");
    let rec = hub.append(&session, "in", "background_task_update", shell("completed"));
    hub.note_process(&session, &rec, None);
    assert!(hub.sessions_at_work_detail().is_empty());
    hub.shutdown_all().await;
}

/// cmux#33328: the Cloud activity report waits on the same startup gates as `in_use`.
#[tokio::test]
async fn startup_settles_only_once_every_load_is_done() {
    let (hub, _session) = chat().await;
    assert!(hub.startup_settled());
    for (gate, name) in [
        (&hub.startup_ready, "startup"),
        (&hub.adoption_ready, "adoption"),
        (&hub.logs_ready, "the chat logs"),
        (&hub.store_load.ready, "the store"),
    ] {
        gate.send_replace(false);
        assert!(!hub.startup_settled(), "{name} still loading");
        gate.send_replace(true);
    }
    assert!(hub.startup_settled());
}

/// An explicitly requested restart (`restart_harnesses`) preserves its existing work-below
/// behavior: the chat keeps its agent and moves before its next turn. With nothing below,
/// it restarts now. Automatic updates use the stricter quiet restart path instead.
#[tokio::test]
async fn an_explicit_restart_waits_for_work_below_and_restarts_a_quiet_chat_now() {
    let (hub, session) = chat().await;
    let ids: std::collections::BTreeSet<String> = [session.id.to_string()].into();
    *session.work_below_since.lock().unwrap() = 1;
    let held = hub.restart_harnesses(None, Some(&ids)).await;
    assert_eq!((held.now, held.after_turn), (0, 1), "work below was cut: {held:?}");
    assert!(session.route_switch.load(Ordering::SeqCst), "not marked to move before its next turn");
    *session.work_below_since.lock().unwrap() = 0;
    session.route_switch.store(false, Ordering::SeqCst);
    let quiet = hub.restart_harnesses(None, Some(&ids)).await;
    assert_eq!(
        (quiet.now, quiet.after_turn),
        (1, 0),
        "a quiet chat did not restart now: {quiet:?}"
    );
    hub.shutdown_all().await;
}

#[tokio::test]
async fn an_account_restart_keeps_background_work_after_the_turn_settles() {
    let (hub, session) = chat().await;
    let child = hub.child_for(&session).await.unwrap();
    let ids = std::collections::BTreeSet::from([session.id.clone()]);
    let (shown, showing) = tokio::sync::oneshot::channel();
    let (release, released) = tokio::sync::oneshot::channel();
    *hub.turn_shown_seam.lock().unwrap() = Some((shown, released));
    let prompt = || vec![json!({"type": "text", "text": "hello"})];
    let turn = tokio::spawn({
        let (hub, session) = (hub.clone(), session.clone());
        async move { hub.prompt(&session, prompt(), "test", false).await }
    });
    tokio::time::timeout(std::time::Duration::from_secs(10), showing).await.unwrap().unwrap();
    assert!(session.turn().is_some());
    let process = |state: &str| {
        let update = json!({"params": {"update": {"sessionUpdate": "background_task_update",
            "toolCallId": "worker", "taskId": "worker", "state": state, "command": "serve"}}});
        let event = hub.append(&session, "in", "background_task_update", update);
        hub.note_process(&session, &event, None);
    };
    process("running");
    let restarts = hub.restart_harnesses(None, Some(&ids)).await;
    assert_eq!((restarts.now, restarts.after_turn), (0, 1));
    release.send(()).unwrap();
    turn.await.unwrap().unwrap();

    assert!(hub.holds_work_below(&session));
    assert!(session.route_switch.load(Ordering::SeqCst));
    assert!(Arc::ptr_eq(&child, &hub.child_for(&session).await.unwrap()));

    process("completed");
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert!(!Arc::ptr_eq(&child, &hub.child_for(&session).await.unwrap()));
    assert!(!session.route_switch.load(Ordering::SeqCst));
    hub.shutdown_all().await;
}

/// An unstored Claude chat whose failed turn did work stays awake only while Claude has not
/// stored its conversation: once the conversation's transcript is in the store its profile
/// reads, the idle pass clears the flags and it may sleep (its next wake resumes it). Red on
/// the base: only a turn that ended Ok cleared them, so a chat whose one turn hit a 429 after
/// working stayed awake until the daemon stopped.
#[tokio::test]
async fn an_unstored_chat_claude_stored_after_all_may_sleep() {
    const CHAT: &str = "0199a1b2-0000-7000-8000-00000000c1a1";
    let root = std::env::temp_dir().join(format!("acpmux-idle-stored-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let cwd = root.join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake], "env": {"CLAUDE_CONFIG_DIR": root}}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(cwd.clone()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    {
        let mut m = session.meta.lock().unwrap();
        m.agent_session_id = Some(CHAT.into());
        m.claude_unstored = true;
        m.claude_unstored_work = true;
        m.turn_count = 1;
    }
    hub.confirm_claude_stored(&session).await;
    assert!(!hub.idle_eligible(&session), "a conversation Claude never stored keeps it awake");
    assert!(session.meta().claude_unstored);

    let dir = root.join("projects").join(crate::adopt::project_dir_name(&cwd));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(format!("{CHAT}.jsonl")), "{\"type\":\"user\"}\n").unwrap();
    hub.confirm_claude_stored(&session).await;
    let meta = session.meta();
    assert!(!meta.claude_unstored && !meta.claude_unstored_work, "the store has it");
    assert!(hub.idle_eligible(&session), "a stored conversation may sleep");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
