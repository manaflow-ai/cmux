//! A prompt in a chat an agent or a script started is refused once nobody attended it for the
//! bound; a person's chat, an attached chat and an answered prompt are left as they were.
#![cfg(unix)]
use super::*;
use crate::store::{CreatedBy, CreatorKind};

fn fixture(
    policy: PermissionPolicy,
    creator: Option<CreatorKind>,
) -> (tempfile::TempDir, Arc<Hub>, Arc<Session>) {
    let dir = tempfile::tempdir().unwrap();
    let cwd = dir.path().canonicalize().unwrap().join("repo");
    std::fs::create_dir(&cwd).unwrap();
    let mut config = Config { permission_policy: policy, ..Default::default() };
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, dir.path()).unwrap();
    let hub = Hub::new(config, store);
    let mut meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "lane-session", "name": "Lane",
        "harness": "codex", "cwd": cwd, "status": "ready", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    meta.created_by = creator.map(|kind| CreatedBy { kind, workspace: None, session: None });
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    let env = [("PATH".to_owned(), "/usr/bin:/bin".to_owned())].into_iter().collect();
    *session.launch_env.lock().unwrap() = Some(env);
    (dir, hub, session)
}

fn shell(command: &str) -> Value {
    json!({"sessionId": "lane-session", "toolCall": {
        "toolCallId": "t-1", "title": command, "kind": "execute",
        "rawInput": {"command": ["bash", "-lc", command]}
    }, "options": [
        {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
        {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
    ]})
}

fn ask(hub: &Arc<Hub>, session: &Arc<Session>, request: Value) -> tokio::task::JoinHandle<Value> {
    let (hub, session) = (hub.clone(), session.clone());
    let epoch = session.permission_epoch.load(Ordering::SeqCst);
    tokio::spawn(async move { hub.handle_permission(&session, request, epoch, None).await })
}

/// Lets the ask reach its wait: it is open once it is pending.
async fn opened(session: &Session) {
    for _ in 0..1000 {
        if !session.pending_permissions().is_empty() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("the prompt never opened");
}

#[test]
fn the_bound_reads_its_variable() {
    use super::super::unattended_ask::{BOUND, bound_from};
    assert_eq!(bound_from(None), Some(BOUND));
    assert_eq!(bound_from(Some("")), Some(BOUND));
    assert_eq!(bound_from(Some("0")), None, "0 turns it off");
    assert_eq!(bound_from(Some(" 90 ")), Some(Duration::from_secs(90)));
    assert_eq!(bound_from(Some("soon")), Some(BOUND));
}

#[test]
fn only_an_agents_or_a_scripts_chat_under_an_asking_policy_is_bounded() {
    use super::super::unattended_ask::applies;
    let by = |kind| Some(CreatedBy { kind, workspace: None, session: None });
    for policy in
        [PermissionPolicy::Ask, PermissionPolicy::ApproveReads, PermissionPolicy::ApproveEdits]
    {
        assert!(applies(by(CreatorKind::Agent).as_ref(), policy), "{policy}");
        assert!(applies(by(CreatorKind::Script).as_ref(), policy), "{policy}");
        assert!(!applies(by(CreatorKind::Person).as_ref(), policy), "a person's chat: {policy}");
        assert!(!applies(None, policy), "no creator on record: {policy}");
    }
    for policy in
        [PermissionPolicy::Review, PermissionPolicy::DenyAll, PermissionPolicy::ApproveAll]
    {
        assert!(!applies(by(CreatorKind::Agent).as_ref(), policy), "never asks: {policy}");
    }
}

#[tokio::test(start_paused = true)]
async fn an_unattended_agents_shell_prompt_is_refused_at_the_bound_with_the_fix() {
    let (_dir, hub, session) = fixture(PermissionPolicy::ApproveReads, Some(CreatorKind::Agent));
    let task = ask(&hub, &session, shell("cargo build --release"));
    opened(&session).await;
    let out = task.await.unwrap();
    assert_eq!(out.pointer("/outcome/optionId"), Some(&json!("reject_once")), "{out}");
    let why = out.pointer("/_meta/acpmux").expect("the reason reaches the agent");
    assert_eq!(why["reason"], "permission.unattended");
    assert_eq!(why["command"], "bash -lc cargo build --release");
    assert_eq!(why["policy"], "approve-reads");
    let message = why["message"].as_str().unwrap();
    assert!(message.contains("--policy review") && message.contains("--policy approve-all"));
    assert!(session.pending_permissions().is_empty(), "the card is gone");
    assert_ne!(session.status(), SessionStatus::Waiting);
}

#[tokio::test(start_paused = true)]
async fn a_persons_chat_still_waits_for_the_person() {
    let (_dir, hub, session) = fixture(PermissionPolicy::Ask, Some(CreatorKind::Person));
    let task = ask(&hub, &session, shell("make deploy"));
    opened(&session).await;
    tokio::time::sleep(super::super::unattended_ask::BOUND * 3).await;
    assert!(!task.is_finished(), "a person's chat is never refused for them");
    assert_eq!(session.pending_permissions().len(), 1);
    task.abort();
}

#[tokio::test(start_paused = true)]
async fn an_attached_chat_waits_and_is_refused_a_bound_after_its_client_leaves() {
    let bound = super::super::unattended_ask::BOUND;
    let (_dir, hub, session) = fixture(PermissionPolicy::Ask, Some(CreatorKind::Script));
    session.attached.fetch_add(1, Ordering::SeqCst);
    let task = ask(&hub, &session, shell("rm -rf target"));
    opened(&session).await;
    tokio::time::sleep(bound * 2 + Duration::from_secs(1)).await;
    assert!(!task.is_finished(), "a client is attached: a person may be in it");
    session.attached.fetch_sub(1, Ordering::SeqCst);
    let out = task.await.unwrap();
    assert_eq!(out.pointer("/outcome/optionId"), Some(&json!("reject_once")), "{out}");
    assert_eq!(out.pointer("/_meta/acpmux/reason"), Some(&json!("permission.unattended")));
}

#[tokio::test(start_paused = true)]
async fn an_answer_before_the_bound_stands() {
    let (_dir, hub, session) = fixture(PermissionPolicy::Ask, Some(CreatorKind::Agent));
    let task = ask(&hub, &session, shell("git push"));
    opened(&session).await;
    let pending = {
        let mut state = session.permissions.lock().unwrap();
        let id = state.pending.keys().next().unwrap().clone();
        state.pending.remove(&id).unwrap()
    };
    let _ = pending.reply.send(json!({"outcome": "selected", "optionId": "allow_once"}));
    let out = task.await.unwrap();
    assert_eq!(out.pointer("/outcome/optionId"), Some(&json!("allow_once")), "{out}");
    assert!(out.get("_meta").is_none());
}
