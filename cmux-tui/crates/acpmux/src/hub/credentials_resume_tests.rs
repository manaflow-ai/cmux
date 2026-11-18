//! A Cloud chat on the owner's credential across a machine's pause and resume (`credentials.rs`,
//! cmux#40159: no provider login is ever written onto a Cloud machine). The pause ends the agent
//! and acpmux; the daemon that comes back on resume restores the chat but forgot the credential,
//! which lived only in memory. The owner's Mac sends it again when its link to the machine comes
//! back (`agent/credentials.update`); until then a turn waits for it, then names why it cannot run.

use super::*;
use crate::agent_credentials::{AgentCredential, CLAUDE_OAUTH};
use crate::config::{Config, StoreMode};
use std::path::Path;
use std::time::Duration;

const TOKEN: &str = "sk-ant-oat01-resume-token-value";

fn hub_at(root: &Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg = serde_json::from_value::<Config>(json!({
        "harnesses": {"claude-fake": {"argv": ["python3", fake], "family": "claude"}},
        "defaultHarness": "claude-fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&cfg.store, root).unwrap();
    Hub::new(cfg, store)
}

fn credential() -> AgentCredential {
    AgentCredential::parse(&json!({"env": {CLAUDE_OAUTH: TOKEN}})).unwrap()
}

fn launched(session: &Session) -> std::collections::BTreeMap<String, String> {
    session.launch_env.lock().unwrap().clone().unwrap_or_default()
}

fn text(words: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": words})]
}

/// Every file under `root` that holds `needle`: nothing of the credential is ever written down.
fn files_holding(root: &Path, needle: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else if std::fs::read(&path)
                .is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle.as_bytes()))
            {
                found.push(path.display().to_string());
            }
        }
    }
    found
}

/// The pause: a chat started on the owner's credential, its agent and daemon then gone. The
/// resume: a new daemon on the same store. Returns that daemon, the restored chat and the store.
async fn paused_and_resumed(
    on_credential: bool,
) -> (Arc<Hub>, Arc<Session>, cmux_unix_socket::TestDir) {
    let dir = cmux_unix_socket::short_test_dir("cred-resume");
    #[cfg(unix)]
    std::fs::set_permissions(dir.path(), std::os::unix::fs::PermissionsExt::from_mode(0o700))
        .unwrap();
    let first = hub_at(dir.path());
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        credential: on_credential.then(credential),
        ..NewRequest::default()
    };
    let session = first.new_session(req).await.unwrap();
    first.child_for(&session).await.unwrap();
    first.prompt(&session, text("before the pause"), "test", false).await.unwrap();
    first.store.flush_session(&session.id).unwrap();
    first.shutdown_all().await;
    drop(first);
    let resumed = hub_at(dir.path());
    let restored = resumed.resolve(&session.id).unwrap();
    assert!(
        restored.credential.lock().unwrap().is_none(),
        "the daemon that resumed holds no credential: it lived in memory only"
    );
    (resumed, restored, dir)
}

/// Pause, resume (acpmux restarted and forgot the credential), the Mac's link comes back and it
/// sends the credential again, and the turn sent meanwhile runs on it: never on the machine's own
/// route, and with no login on the machine's disk.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_turn_after_resume_runs_on_the_credential_the_mac_sends_when_its_link_returns() {
    let (hub, session, dir) = paused_and_resumed(true).await;
    // The person's turn, sent as the machine comes back.
    let turn = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.prompt(&session, text("back after a pause"), "test", false).await
        })
    };
    // The Mac's link to the machine returns: it sends the chat's credential again.
    tokio::time::sleep(Duration::from_millis(300)).await;
    hub.update_credential(&session.id, credential()).await.unwrap();
    let answer = tokio::time::timeout(Duration::from_secs(30), turn).await.unwrap().unwrap();
    assert!(answer.is_ok(), "the turn after resume failed: {answer:?}");
    assert_eq!(
        launched(&session).get(CLAUDE_OAUTH).map(String::as_str),
        Some(TOKEN),
        "the agent that answered after resume runs on the owner's credential"
    );
    assert_eq!(files_holding(dir.path(), TOKEN), Vec::<String>::new(), "no login on disk");
    hub.shutdown_all().await;
}

/// The Mac is offline (asleep, cmux closed): a resumed chat's turn says why it cannot run, by
/// name, and starts no agent on the machine's route (whose harness would say "Not logged in").
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_turn_after_resume_with_the_mac_offline_names_why() {
    let (hub, session, _dir) = paused_and_resumed(true).await;
    let e = tokio::time::timeout(
        Duration::from_secs(30),
        hub.prompt(&session, text("back after a pause"), "test", false),
    )
    .await
    .unwrap()
    .unwrap_err();
    assert!(e.message.contains("needs the Mac to sign in: open cmux"), "{}", e.message);
    assert!(!e.message.to_lowercase().contains("not logged in"), "{}", e.message);
    assert_eq!(e.data.as_ref().unwrap()["errorKind"], "credentials.needs_mac");
    assert!(launched(&session).is_empty(), "no agent started on the machine's own route");
    // The Mac comes back later: the next turn runs.
    hub.update_credential(&session.id, credential()).await.unwrap();
    hub.prompt(&session, text("again"), "test", false).await.unwrap();
    assert_eq!(launched(&session).get(CLAUDE_OAUTH).map(String::as_str), Some(TOKEN));
    hub.shutdown_all().await;
}

/// A chat on the machine's own route (no owner's credential) is never held after a resume.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_on_the_machines_own_route_takes_its_turn_after_resume_at_once() {
    let (hub, session, _dir) = paused_and_resumed(false).await;
    hub.prompt(&session, text("back after a pause"), "test", false).await.unwrap();
    hub.shutdown_all().await;
}
