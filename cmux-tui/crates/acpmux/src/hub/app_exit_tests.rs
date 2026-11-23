use super::*;
use crate::config::{Config, StoreMode};
use crate::store::{MemoryStore, Tag, Watching};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-app-exit-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sessions")).unwrap();
    dir
}

fn now_ms() -> u64 {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap();
    u64::try_from(now.as_millis()).unwrap()
}

/// A Claude Code stand-in: a process of this test's and the registry entry naming it, recorded
/// at `started_at`.
fn app(config: &Path, sid: &str, started_at: u64) -> std::process::Child {
    let child = std::process::Command::new("sleep").arg("600").spawn().unwrap();
    let pid = child.id();
    let entry = json!({"pid": pid, "sessionId": sid, "cwd": "/w", "entrypoint": "claude-desktop",
        "startedAt": started_at});
    std::fs::write(config.join(format!("sessions/{pid}.json")), entry.to_string()).unwrap();
    child
}

fn hub(config: &Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(MemoryStore::default()));
    hub.harness_homes.lock().unwrap().claude = config.to_path_buf();
    hub
}

/// A watched chat of conversation `sid`, as the bridge lists it (or a restart restores it):
/// tagged with the app's pid when `pid` is given.
async fn watched(hub: &Arc<Hub>, config: &Path, sid: &str, pid: Option<u32>) -> Arc<Session> {
    let transcript = config.join(format!("{sid}.jsonl"));
    std::fs::write(&transcript, "").unwrap();
    let session = hub
        .new_session(crate::hub::NewRequest {
            cwd: Some(config.to_path_buf()),
            ..Default::default()
        })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.agent_session_id = Some(sid.into());
        let tag = |v: &str| Tag { value: v.into(), expires_at: None };
        if let Some(pid) = pid {
            meta.tags.insert("bridge".into(), tag("claude"));
            meta.tags.insert("origin.pid".into(), tag(&pid.to_string()));
        }
        meta.watching = Some(Watching {
            family: "claude".into(),
            file: transcript,
            offset: 0,
            codex_items: false,
            open: None,
            ..Default::default()
        });
    }
    hub.save_meta(&session);
    hub.start_watch(&session);
    session
}

fn status(hub: &Hub, session: &Session) -> String {
    let row = hub.session_summary(session);
    assert_eq!(row["status"], row["state"], "{row}");
    row["status"].as_str().unwrap().to_owned()
}

/// Waits up to `within` for `ok`.
async fn until(within: Duration, mut ok: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if ok() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    ok()
}

fn armed(session: &Session) -> bool {
    followed().get(&session.id).is_some_and(|f| !f.procs.is_empty())
}

fn signal(child: &std::process::Child, sig: libc::c_int) {
    // SAFETY: a signal to this test's own child.
    assert_eq!(unsafe { libc::kill(child.id() as libc::pid_t, sig) }, 0);
}

/// The duress bench's external row: a bridged chat whose app is killed reads disconnected within
/// seconds; a stopped app is not dead, and a chat of another app that runs on is untouched.
#[tokio::test(flavor = "multi_thread")]
async fn a_killed_app_reads_disconnected_and_a_stopped_one_does_not() {
    let config = scratch("killed");
    let mut killed = app(&config, "sid-killed", now_ms());
    let mut other = app(&config, "sid-other", now_ms());
    let hub = hub(&config);
    let chat = watched(&hub, &config, "sid-killed", Some(killed.id())).await;
    let bystander = watched(&hub, &config, "sid-other", Some(other.id())).await;
    assert!(until(Duration::from_secs(5), || armed(&chat) && armed(&bystander)).await);
    assert_ne!(status(&hub, &chat), "disconnected");

    signal(&killed, libc::SIGSTOP);
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_ne!(status(&hub, &chat), "disconnected", "a stopped app is not dead");
    signal(&killed, libc::SIGCONT);

    let at = Instant::now();
    killed.kill().unwrap();
    killed.wait().unwrap();
    assert!(
        until(Duration::from_secs(5), || status(&hub, &chat) == "disconnected").await,
        "the kill was heard"
    );
    assert!(at.elapsed() < Duration::from_secs(5));
    assert_ne!(status(&hub, &bystander), "disconnected", "another app's chat is untouched");

    other.kill().unwrap();
    other.wait().unwrap();
    assert!(until(Duration::from_secs(5), || status(&hub, &bystander) == "disconnected").await);
    let _ = std::fs::remove_dir_all(&config);
}

/// A restored chat whose app exited while the daemon was down, or whose pid another process has
/// now (its entry was recorded before that process started), reads disconnected at once; a
/// watched chat nothing bridged is not followed.
#[tokio::test(flavor = "multi_thread")]
async fn a_gone_or_reused_pid_reads_disconnected_at_once() {
    let config = scratch("reused");
    let mut gone = app(&config, "sid-gone", now_ms());
    let gone_pid = gone.id();
    gone.kill().unwrap();
    gone.wait().unwrap();
    // An entry an hour older than the process under its pid: not the process that wrote it.
    let mut reused = app(&config, "sid-reused", now_ms() - 3_600_000);
    let hub = hub(&config);
    let restored = watched(&hub, &config, "sid-gone", Some(gone_pid)).await;
    let wrong = watched(&hub, &config, "sid-reused", Some(reused.id())).await;
    let plain = watched(&hub, &config, "sid-plain", None).await;
    assert!(until(Duration::from_secs(5), || status(&hub, &restored) == "disconnected").await);
    assert!(until(Duration::from_secs(5), || status(&hub, &wrong) == "disconnected").await);
    assert!(!armed(&wrong), "the other process under the pid is not followed");
    assert_ne!(status(&hub, &plain), "disconnected");
    assert!(followed().get(&plain.id).is_none(), "a chat nothing bridged is not followed");
    reused.kill().unwrap();
    reused.wait().unwrap();
    let _ = std::fs::remove_dir_all(&config);
}

/// A new process for the conversation (a restarted app the bridge lists again) brings the chat
/// back, and its exit is heard in turn.
#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_app_is_followed_again() {
    let config = scratch("restarted");
    let mut first = app(&config, "sid-again", now_ms());
    let hub = hub(&config);
    let chat = watched(&hub, &config, "sid-again", Some(first.id())).await;
    assert!(until(Duration::from_secs(5), || armed(&chat)).await);
    first.kill().unwrap();
    first.wait().unwrap();
    assert!(until(Duration::from_secs(5), || status(&hub, &chat) == "disconnected").await);

    let mut second = app(&config, "sid-again", now_ms());
    hub.follow_app(&chat, Some(second.id()));
    assert!(until(Duration::from_secs(5), || status(&hub, &chat) != "disconnected").await);
    second.kill().unwrap();
    second.wait().unwrap();
    assert!(until(Duration::from_secs(5), || status(&hub, &chat) == "disconnected").await);
    let _ = std::fs::remove_dir_all(&config);
}
