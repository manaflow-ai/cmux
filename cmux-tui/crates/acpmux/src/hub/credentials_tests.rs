use crate::agent_credentials::{AgentCredential, CHATGPT_TOKEN, CLAUDE_OAUTH};
use crate::config::{Config, StoreMode};
use crate::hub::{Hub, NewRequest};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

const FIRST: &str = "sk-ant-oat01-first-token-value";
const SECOND: &str = "sk-ant-oat01-second-token-value";
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    hub_for("claude", &["python3", FAKE])
}

fn hub_for(family: &str, argv: &[&str]) -> Arc<Hub> {
    let harness = format!("{family}-fake");
    let mut cfg = serde_json::from_value::<Config>(json!({
        "harnesses": {(&harness): {"argv": argv, "family": family}},
        "defaultHarness": harness
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[cfg(unix)]
async fn recovery_hub() -> (tempfile::TempDir, Arc<Hub>) {
    use std::os::unix::fs::PermissionsExt as _;

    let root = tempfile::tempdir().unwrap();
    let launcher = root.path().join("claude");
    std::fs::copy(FAKE, &launcher).unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o700)).unwrap();
    let hub = hub();
    {
        let mut cfg = hub.config.write().await;
        let profile = cfg.harnesses.get_mut("claude-fake").unwrap();
        profile.argv = vec![launcher.display().to_string()];
        let cli =
            serde_json::from_value(json!({"kind": "claude-stdio", "argv": [launcher]})).unwrap();
        cfg.harnesses.insert("claude".into(), cli);
    }
    (root, hub)
}

fn credential(token: &str) -> AgentCredential {
    AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: token}})).unwrap()
}

/// Everything this daemon wrote down about the session: its meta and its whole log.
fn written(hub: &Hub, id: &str) -> String {
    let session = hub.resolve(id).unwrap();
    let records = hub.events(id, 0, 100_000).unwrap();
    let log: Vec<_> = records.into_iter().map(|r| (r.kind, r.msg)).collect();
    format!("{}\n{}", serde_json::to_string(&session.meta()).unwrap(), json!(log))
}

fn launched(session: &crate::hub::Session) -> std::collections::BTreeMap<String, String> {
    session.launch_env.lock().unwrap().clone().unwrap_or_default()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_credential_reaches_only_its_agent_and_is_never_written_down() {
    let hub = hub();
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        credential: Some(credential(FIRST)),
        ..NewRequest::default()
    };
    let session = hub.new_session(req).await.unwrap();
    hub.child_for(&session).await.unwrap();
    let env = launched(&session);
    assert_eq!(env.get(CLAUDE_OAUTH).map(String::as_str), Some(FIRST));
    let unset = env.get(crate::routes::UNSET_KEY).cloned().unwrap_or_default();
    for key in crate::cloud_model_plane::KEYS {
        assert!(unset.split(',').any(|k| k == key), "{key} is removed for this agent");
    }
    // Another chat on the same daemon runs on the machine's own route.
    let other = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    hub.child_for(&other).await.unwrap();
    assert!(!launched(&other).contains_key(CLAUDE_OAUTH));
    assert!(!written(&hub, &session.id).contains(FIRST), "no meta or log record holds it");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cloud_gemini_fork_refuses_to_replay_on_the_machine_account() {
    let hub = hub_for("gemini", &["python3", FAKE]);
    hub.config.write().await.cloud_host = true;
    hub.config.write().await.harnesses.get_mut("gemini-fake").unwrap().env.extend([
        ("FAKE_NO_FORK".into(), "1".into()),
        ("GEMINI_API_KEY".into(), "machine-fixture".into()),
    ]);
    let credential = AgentCredential::parse(&json!({
        "connection": "google-key",
        "env": {"GEMINI_API_KEY": "owner-fixture"}
    }))
    .unwrap();
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    assert_eq!(launched(&session)["GEMINI_API_KEY"], "owner-fixture");

    let prompt = || vec![json!({"type": "text", "text": "parent history"})];
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    let (shown, showing) = tokio::sync::oneshot::channel();
    let (release, released) = tokio::sync::oneshot::channel();
    *hub.family_write_seam.lock().unwrap() = Some((shown, released));
    let turn = tokio::spawn({
        let (hub, session) = (hub.clone(), session.clone());
        async move { hub.prompt(&session, prompt(), "test", false).await }
    });
    tokio::time::timeout(std::time::Duration::from_secs(10), showing).await.unwrap().unwrap();
    assert_eq!(session.status(), crate::store::SessionStatus::Running);
    let fork = hub.fork(&session, None, None, Default::default(), None, None, true).await;
    release.send(()).unwrap();
    turn.await.unwrap().unwrap();
    let error = fork.err().expect("a fork cannot use the machine's default key");
    assert_eq!(error.data.unwrap()["reason"], "credentials.needed");
    assert!(hub.sessions().iter().all(|s| s.meta().parent_id.is_none()));
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_restarts_the_agent_on_the_new_credential_in_the_same_chat() {
    let hub = hub();
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        credential: Some(credential(FIRST)),
        ..NewRequest::default()
    };
    let session = hub.new_session(req).await.unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;
    let reply = hub.update_credential(&session.id, credential(SECOND), false).await.unwrap();
    assert_eq!(reply["restart"], "now");
    let after = hub.child_for(&session).await.unwrap().generation;
    assert_ne!(before, after, "a new agent process");
    assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(SECOND));
    assert_eq!(hub.resolve(&session.id).unwrap().id, session.id, "the same chat");
    let text = format!("{reply}{}", written(&hub, &session.id));
    assert!(!text.contains(FIRST) && !text.contains(SECOND));
    // The same credential again restarts nothing.
    let again = hub.update_credential(&session.id, credential(SECOND), false).await.unwrap();
    assert_eq!(again["restart"], "none");
}

/// cmux#45776: a daemon restart forgets the credential (memory only), while the agent it adopts
/// still runs on it. Read back from that agent's env, the agent's next start (a wake after the
/// machine paused) runs on it again instead of the machine's route ("Claude is not signed in").
#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_adopted_agents_credential_is_held_again_for_its_next_start() {
    let hub = hub();
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        credential: Some(credential(FIRST)),
        ..NewRequest::default()
    };
    let session = hub.new_session(req).await.unwrap();
    let child = hub.child_for(&session).await.unwrap();
    let pid = child.pid.expect("the agent's pid");
    let start = crate::owner_exit::process_start(pid).unwrap();
    let identity = Some((pid, start));
    let other = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    assert!(
        !hub.recover_credential(&other, identity),
        "same-family chat cannot take the credential"
    );
    // What a new daemon has of the session: no credential.
    *session.credential.lock().unwrap() = None;
    assert!(!hub.recover_credential(&session, Some((pid, start + 1))), "a reused PID is refused");
    assert!(hub.recover_credential(&session, identity));
    assert_eq!(*session.credential.lock().unwrap(), Some(credential(FIRST)));
    // One the Mac sent since stays.
    *session.credential.lock().unwrap() = Some(credential(SECOND));
    assert!(!hub.recover_credential(&session, identity));
    assert_eq!(*session.credential.lock().unwrap(), Some(credential(SECOND)));
    // The next start runs on the held credential.
    *session.credential.lock().unwrap() = None;
    assert!(hub.recover_credential(&session, identity));
    let before = child.generation;
    let only = std::collections::BTreeSet::from([session.id.clone()]);
    hub.restart_harnesses(None, Some(&only)).await;
    let after = hub.child_for(&session).await.unwrap().generation;
    assert_ne!(before, after, "a new agent process");
    assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(FIRST));
    assert!(!written(&hub, &session.id).contains(FIRST), "still never written down");
}

#[cfg(target_os = "linux")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_agent_launched_without_a_credential_gives_none_back() {
    let hub = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let pid = hub.child_for(&session).await.unwrap().pid.expect("the agent's pid");
    let identity = Some((pid, crate::owner_exit::process_start(pid).unwrap()));
    assert!(!hub.recover_credential(&session, identity));
    assert!(session.credential.lock().unwrap().is_none());
    assert!(!hub.recover_credential(&session, None));
}

#[tokio::test]
async fn a_host_report_cannot_restore_a_withdrawn_or_replaced_credential() {
    let hub = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let report = |name: &str| {
        vec![(crate::agent_credentials::MARKER.into(), name.into()), (name.into(), FIRST.into())]
    };
    assert!(!hub.hold_launch_credential(&session, &report(crate::byo_endpoint::ANTHROPIC_KEY_ENV)));
    let report = report(CLAUDE_OAUTH);
    assert!(hub.hold_launch_credential(&session, &report));
    assert_eq!(*session.credential.lock().unwrap(), Some(credential(FIRST)));
    *session.credential.lock().unwrap() = None;
    hub.edit_test_meta(&session, |meta| meta.credential_withdrawn = true);
    assert!(!hub.hold_launch_credential(&session, &report));
    hub.edit_test_meta(&session, |meta| {
        meta.credential_withdrawn = false;
        meta.claude_token_recovery = Some(crate::store::ClaudeTokenRecovery::MachineLogin);
    });
    assert!(!hub.hold_launch_credential(&session, &report));
    assert!(session.credential.lock().unwrap().is_none());
}

/// An idle chat's agent is hibernated while a machine update restarts the daemon: the
/// credential was in the daemon's memory only, and the next message said "Claude is not signed
/// in here". The session's summary says so while it lasts, and the wake a machine update asks
/// for starts the agent on the credential, which then carries it in its env.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hibernated_chats_credential_is_marked_until_a_wake_puts_it_on_an_agent() {
    let hub = hub();
    let only_here =
        |s: &crate::hub::Session| hub.session_summary(s)["credentialOnlyHere"] == json!(true);
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        credential: Some(credential(FIRST)),
        ..NewRequest::default()
    };
    let session = hub.new_session(req).await.unwrap();
    hub.child_for(&session).await.unwrap();
    assert!(!only_here(&session), "its running agent carries it");
    let paused = hub.pause(&session).await.unwrap();
    assert_eq!(paused["paused"], true, "{paused}");
    assert!(only_here(&session), "hibernated: only this daemon's memory holds it");
    let summary = hub.session_summary(&session).to_string();
    assert!(!summary.contains(FIRST) && !summary.contains(CLAUDE_OAUTH), "{summary}");
    // Without a credential a hibernated chat has nothing to lose.
    let plain = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    hub.child_for(&plain).await.unwrap();
    assert_eq!(hub.pause(&plain).await.unwrap()["paused"], true);
    assert!(hub.session_summary(&plain).get("credentialOnlyHere").is_none());
    // The wake starts the agent on it.
    let woke = hub.wake(&session).await.unwrap();
    assert_eq!(woke["woke"], true, "{woke}");
    assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(FIRST));
    assert!(!only_here(&session));
    assert!(!written(&hub, &session.id).contains(FIRST), "still never written down");
}

#[cfg(unix)]
#[tokio::test]
async fn claude_recovery_keeps_the_active_turn_and_restarts_without_the_token() {
    let (_root, hub) = recovery_hub().await;
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let before = hub.child_for(&session).await.unwrap().generation;
    let (shown, turn_shown) = tokio::sync::oneshot::channel();
    let (resume, wait) = tokio::sync::oneshot::channel();
    *hub.family_write_seam.lock().unwrap() = Some((shown, wait));
    let turn = tokio::spawn({
        let (hub, session) = (hub.clone(), session.clone());
        async move {
            hub.prompt(&session, vec![json!({"type": "text", "text": "first"})], "test", false)
                .await
        }
    });
    turn_shown.await.unwrap();
    assert!(hub.use_claude_machine_login(&session).await.unwrap());
    let only = std::collections::BTreeSet::from([session.id.clone()]);
    let restarts = hub.restart_harnesses(None, Some(&only)).await;
    assert_eq!((restarts.now, restarts.after_turn), (0, 1));
    assert!(session.turn().is_some());
    assert_eq!(session.child.lock().await.as_ref().unwrap().generation, before);

    resume.send(()).unwrap();
    turn.await.unwrap().unwrap();
    hub.prompt(&session, vec![json!({"type": "text", "text": "next"})], "test", false)
        .await
        .unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, before);
    assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
    assert_eq!(launched(&session).get("CMUX_CLAUDE_AUTH").map(String::as_str), Some("own"));
    assert_eq!(session.meta().claude_login_restart_pending, Some(false));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn claude_recovery_keeps_the_token_if_the_launcher_cannot_use_the_machine_login() {
    let hub = hub();
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let error = hub.use_claude_machine_login(&session).await.unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "route.unavailable");
    let status = hub.credential_status(&session.id).await.unwrap();
    assert_eq!(status["held"], true);
    assert!(status["claudeTokenRecovery"].is_null());
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn recovery_saved_after_prompt_preflight_refuses_the_old_child() {
    let (_root, hub) = recovery_hub().await;
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let old = hub.child_for(&session).await.unwrap();
    let (shown, turn_shown) = tokio::sync::oneshot::channel();
    let (resume, wait) = tokio::sync::oneshot::channel();
    *hub.turn_shown_seam.lock().unwrap() = Some((shown, wait));
    let send = tokio::spawn({
        let (hub, session) = (hub.clone(), session.clone());
        async move {
            hub.prompt(
                &session,
                vec![json!({"type": "text", "text": "racing Claude recovery"})],
                "test",
                false,
            )
            .await
        }
    });
    turn_shown.await.unwrap();
    assert!(hub.use_claude_machine_login(&session).await.unwrap());
    let only = std::collections::BTreeSet::from([session.id.clone()]);
    assert_eq!(hub.restart_harnesses(None, Some(&only)).await.after_turn, 1);
    assert!(old.is_alive().await);

    resume.send(()).unwrap();
    let error = send.await.unwrap().unwrap_err();
    assert_eq!(error.data.unwrap()["reason"], "credentials.claude_login_busy");
    assert!(!written(&hub, &session.id).contains("echo: racing Claude recovery"));
    hub.prompt(&session, vec![json!({"type": "text", "text": "next"})], "test", false)
        .await
        .unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, old.generation);
    assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn a_prompt_waits_for_background_work_before_switching_to_claude_login() {
    use std::sync::atomic::Ordering;

    let (_root, hub) = recovery_hub().await;
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let old = hub.child_for(&session).await.unwrap();
    *session.work_below_since.lock().unwrap() = 1;
    assert!(hub.use_claude_machine_login(&session).await.unwrap());
    let only = std::collections::BTreeSet::from([session.id.clone()]);
    let restarts = hub.restart_harnesses(None, Some(&only)).await;
    assert_eq!(restarts.after_turn, 1);
    assert!(session.route_switch.load(Ordering::SeqCst));

    let prompt = || vec![json!({"type": "text", "text": "hello"})];
    let refused = hub.prompt(&session, prompt(), "test", false).await.unwrap_err();
    assert!(!refused.message.contains(FIRST));
    let data = refused.data.unwrap();
    assert_eq!(data, json!({"reason": "credentials.claude_login_busy"}));
    assert!(hub.holds_work_below(&session));
    assert!(old.is_alive().await);
    assert_eq!(session.child.lock().await.as_ref().unwrap().generation, old.generation);

    *session.work_below_since.lock().unwrap() = 0;
    hub.prompt(&session, prompt(), "test", false).await.unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, old.generation);
    assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn a_prompt_after_the_recovery_save_uses_the_machine_login_before_restart_is_requested() {
    use std::sync::atomic::Ordering;

    let (_root, hub) = recovery_hub().await;
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let old = hub.child_for(&session).await.unwrap();
    // The state between use_claude_machine_login and restart_harnesses in signed_in.
    assert!(hub.use_claude_machine_login(&session).await.unwrap());
    assert!(!session.route_switch.load(Ordering::SeqCst));
    assert_eq!(session.meta().claude_login_restart_pending, Some(true));

    hub.prompt(&session, vec![json!({"type": "text", "text": "hello"})], "test", false)
        .await
        .unwrap();
    assert_ne!(hub.child_for(&session).await.unwrap().generation, old.generation);
    assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
    assert_eq!(session.meta().claude_login_restart_pending, Some(false));
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn a_cold_start_waiting_on_recovery_reads_the_new_credential() {
    use std::{future::Future as _, task::Poll};

    let (_root, hub) = recovery_hub().await;
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential(FIRST)),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    assert_eq!(hub.pause(&session).await.unwrap()["paused"], true);
    let lock = session.spawn_lock.lock().await;
    let mut recovery = std::pin::pin!(hub.use_claude_machine_login(&session));
    assert!(futures::poll!(recovery.as_mut()).is_pending());
    let mut start = std::pin::pin!(hub.child_for(&session));
    use super::super::full_access_bound::AT_OPERATION_ENTRY;
    AT_OPERATION_ENTRY.with(|hook| hook.set(Some(|_| {})));
    std::future::poll_fn(|cx| {
        assert!(start.as_mut().poll(cx).is_pending());
        if AT_OPERATION_ENTRY.with(|hook| hook.get().is_none()) {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    })
    .await;

    drop(lock);
    assert!(recovery.await.unwrap());
    start.await.unwrap();
    assert!(!launched(&session).contains_key(CLAUDE_OAUTH));
    assert_eq!(launched(&session).get("CMUX_CLAUDE_AUTH").map(String::as_str), Some("own"));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_saved_claude_rejection_survives_grant_loss_and_later_turns() {
    let hub = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    session.meta.lock().unwrap().last_turn =
        Some(json!({"errorCode": "claude_cloud_token_rejected"}));
    hub.check_claude_recovery(&session, None).await.unwrap();
    for connection in [None, Some("custom-mac-only:0123456789abcdef")] {
        {
            let mut meta = session.meta.lock().unwrap();
            meta.credential_connection = connection.map(str::to_owned);
            meta.claude_token_recovery = None;
        }
        hub.record_last_turn(&session, &json!({"errorCode": "claude_cloud_token_rejected"}));
        hub.check_claude_recovery(&session, None).await.unwrap();

        hub.record_last_turn(&session, &json!({"errorCode": "model_not_found"}));
        assert_eq!(session.meta().last_turn.unwrap()["errorCode"], "model_not_found");
        hub.check_claude_recovery(&session, None).await.unwrap();
    }
    hub.shutdown_all().await;
}

#[cfg(unix)]
#[tokio::test]
async fn withdrawal_waits_for_a_live_turn_permission_and_background_work() {
    use crate::hub::{Control, person::Answerer};

    let (_root, hub) = recovery_hub().await;
    let credential = AgentCredential::parse(&json!({
        "env": {"ANTHROPIC_API_KEY": "fixture-key"}, "connection": "personal-models"
    }))
    .unwrap();
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let child = hub.child_for(&session).await.unwrap();
    let mut events = hub.subscribe();
    let turn = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt(
                &session,
                vec![json!({"type": "text", "text": "ask: fixture permission"})],
                "test",
                false,
            )
            .await
        })
    };
    let timeout = std::time::Duration::from_secs(15);
    let permission = tokio::time::timeout(timeout, async {
        loop {
            let event = events.recv().await.unwrap();
            if event.record.kind == "permission_request" && event.session_id == session.id {
                break event.record.msg["permissionId"].as_str().unwrap().to_owned();
            }
        }
    })
    .await
    .unwrap();
    let pending = hub.revoke_credential(&session.id).await.unwrap_err();
    assert_eq!(pending.data.unwrap()["reason"], "credentials.host_pending");
    assert!(child.is_alive().await);
    assert_eq!(hub.credential_status(&session.id).await.unwrap()["held"], true);
    hub.respond_permission(
        &session,
        &permission,
        Some("no".into()),
        None,
        None,
        Answerer { person: true, ..Default::default() },
        Control::Local,
    )
    .await
    .unwrap();
    assert_eq!(
        tokio::time::timeout(timeout, turn).await.unwrap().unwrap().unwrap()["stopReason"],
        "end_turn"
    );

    let follow_up = hub
        .prompt(
            &session,
            vec![json!({"type": "text", "text": "follow-up before the owner's retry"})],
            "test",
            false,
        )
        .await
        .unwrap_err();
    assert_eq!(follow_up.data.unwrap()["reason"], "credentials.needed");
    assert!(child.is_alive().await);

    *session.work_below_since.lock().unwrap() = 1;
    let pending = hub.revoke_credential(&session.id).await.unwrap_err();
    assert_eq!(pending.data.unwrap()["reason"], "credentials.host_pending");
    assert!(child.is_alive().await);

    *session.work_below_since.lock().unwrap() = 0;
    hub.revoke_credential(&session.id).await.unwrap();
    assert!(!child.is_alive().await);
    assert_eq!(hub.credential_status(&session.id).await.unwrap()["held"], false);
    let error = hub.child_for(&session).await.err().expect("withdrawn key cannot be used");
    assert_eq!(error.data.unwrap()["reason"], "credentials.needed");
    hub.update_credential(
        &session.id,
        AgentCredential::parse(&json!({"env": {"ANTHROPIC_API_KEY": "fixture-key"}})).unwrap(),
        false,
    )
    .await
    .unwrap();
    assert_eq!(
        hub.prompt(
            &session,
            vec![json!({"type": "text", "text": "after redelivery"})],
            "test",
            false,
        )
        .await
        .unwrap()["stopReason"],
        "end_turn"
    );
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_named_cloud_connection_refuses_respawn_until_the_owner_redelivers() {
    let hub = hub();
    let credential = AgentCredential::parse(&json!({
        "env": {CLAUDE_OAUTH: FIRST}, "connection": "personal-models"
    }))
    .unwrap();
    let session = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            credential: Some(credential.clone()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    hub.child_for(&session).await.unwrap();
    let status = hub.credential_status(&session.id).await.unwrap();
    assert_eq!(status["connection"], "personal-models");
    assert_eq!(status["held"], true);
    assert!(!written(&hub, &session.id).contains(FIRST));

    hub.revoke_credential(&session.id).await.unwrap();
    let error = hub.child_for(&session).await.err().expect("missing grant blocks launch");
    assert_eq!(error.data.unwrap()["reason"], "credentials.needed");

    hub.update_credential(&session.id, credential, false).await.unwrap();
    hub.child_for(&session).await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn legacy_refresh_cannot_replace_a_bound_chatgpt_credential() {
    let hub = hub_for("codex", &["python3", FAKE, "app-server"]);
    let credential =
        AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: "old-fixture-token"}})).unwrap();
    let fresh =
        AgentCredential::parse(&json!({"env": {CHATGPT_TOKEN: "new-fixture-token"}})).unwrap();
    let binding = format!("chatgpt:{}", "a".repeat(64));
    for (connection, allowed) in [(None, true), (Some(binding.as_str()), false)] {
        let mut initial = credential.clone();
        initial.keep_connection(connection);
        let session = hub
            .new_session(NewRequest {
                cwd: Some(std::env::temp_dir()),
                credential: Some(initial.clone()),
                ..NewRequest::default()
            })
            .await
            .unwrap();
        assert_eq!(hub.update_credential(&session.id, fresh.clone(), true).await.is_ok(), allowed);
        let held = session.credential.lock().unwrap();
        assert_eq!(held.as_ref(), Some(if allowed { &fresh } else { &initial }));
    }
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_update_of_another_family_or_an_unknown_session_is_refused() {
    let hub = hub();
    let session = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let codex = AgentCredential::parse(
        &json!({"env": {crate::agent_credentials::OPENAI_KEY: "sk-proj-x"}}),
    )
    .unwrap();
    let e = hub.update_credential(&session.id, codex, false).await.unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "credentials.family");
    let e = hub.update_credential("no-such-session", credential(FIRST), false).await.unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "credentials.no_session");
}
