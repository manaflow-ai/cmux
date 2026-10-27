//! The daemon's memory consumers under a stand-in pressure source (a voter of
//! the hub's registry, as the kernel source is).

use super::*;
use crate::live_models::LiveModel;
use serde_json::json;
use std::collections::{BTreeMap, VecDeque};

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn session(hub: &Hub, id: &str) -> Arc<Session> {
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": id,
        "name": id,
        "harness": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 0,
        "updatedAt": 0,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

/// A Codex login file the auth cache keeps a parse of: written more than
/// its racy window ago.
fn settled_codex_home(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-memory-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("auth.json");
    std::fs::write(&file, r#"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-1"}}"#).unwrap();
    let past = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    std::fs::File::options().write(true).open(&file).unwrap().set_modified(past).unwrap();
    dir
}

fn completed_outcomes(n: usize) -> VecDeque<(String, super::super::PromptOutcome)> {
    (0..n)
        .map(|i| {
            let outcome = tokio::sync::watch::channel(Some(Ok(json!({})))).0;
            (format!("prompt-{i}"), Arc::new(outcome))
        })
        .collect()
}

fn model(id: &str) -> LiveModel {
    serde_json::from_value(json!({"id": id, "name": id, "efforts": ["low", "high"]})).unwrap()
}

fn consumer_bytes(hub: &Hub, name: &str) -> Option<u64> {
    hub.memory().registry().report().into_iter().find(|c| c.name == name).and_then(|c| c.bytes)
}

/// The next `_acpmux/harnesses_changed` payload, or None within a second.
async fn next_change(rx: &mut tokio::sync::broadcast::Receiver<serde_json::Value>) -> Option<()> {
    tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await.ok()?.ok().map(|_| ())
}

#[tokio::test]
async fn memory_warning_empties_the_lossless_caches_and_critical_trims_sessions() {
    let hub = hub();
    let mut changes = hub.subscribe_harness_changes();
    let home = settled_codex_home("levels");
    let env = BTreeMap::from([("CODEX_HOME".to_owned(), home.to_string_lossy().into_owned())]);
    let before = hub.pool.auth_cache().fingerprint("codex", &env);
    assert!(consumer_bytes(&hub, names::AUTH_CACHE).unwrap() > 0, "the parse is cached");

    let s = session(&hub, "s-memory-levels");
    s.stderr_tail.lock().unwrap().extend(["Not logged in".to_owned(), "exit 1".to_owned()]);
    *s.prompts.lock().unwrap() = completed_outcomes(20);
    hub.live_models.lock().unwrap().insert("claude".into(), vec![model("opus"), model("sonnet")]);
    assert!(consumer_bytes(&hub, names::STDERR_TAILS).unwrap() > 0);
    assert!(consumer_bytes(&hub, names::LIVE_MODELS).unwrap() > 0);

    let source = hub.memory().registry().voter();
    source.set_level(PressureLevel::Warning);
    assert_eq!(consumer_bytes(&hub, names::AUTH_CACHE), Some(0), "the parsed login files dropped");
    assert!(s.stderr_tail.lock().unwrap().is_empty(), "no agent runs: its tail dropped");
    assert_eq!(consumer_bytes(&hub, names::STDERR_TAILS), Some(0));
    // Lossy state waits for critical.
    assert_eq!(s.prompts.lock().unwrap().len(), 20);
    assert_eq!(hub.live_models.lock().unwrap().len(), 1);
    // The emptied cache reads its file again and gives the same answer.
    assert_eq!(hub.pool.auth_cache().fingerprint("codex", &env), before);

    source.set_level(PressureLevel::Critical);
    let kept: Vec<String> = s.prompts.lock().unwrap().iter().map(|(id, _)| id.clone()).collect();
    assert_eq!(
        kept,
        (12..20).map(|i| format!("prompt-{i}")).collect::<Vec<_>>(),
        "the newest stay"
    );
    assert!(hub.live_models.lock().unwrap().is_empty(), "the curated lists stand in");
    assert_eq!(consumer_bytes(&hub, names::LIVE_MODELS), Some(0));
    assert!(next_change(&mut changes).await.is_some(), "watchers read _acpmux/models again");
    let _ = std::fs::remove_dir_all(home);
}

#[test]
fn memory_warning_keeps_a_tail_that_a_start_or_a_failure_still_quotes() {
    let hub = hub();
    let line = || VecDeque::from(["Not logged in".to_owned()]);
    let starting = session(&hub, "s-memory-starting");
    *starting.stderr_tail.lock().unwrap() = line();
    // An agent that died in `initialize`: no child, status still idle, and
    // `explain_start_failure` reads the tail under `spawn_lock`.
    let spawning = starting.spawn_lock.try_lock().unwrap();
    let died = session(&hub, "s-memory-died");
    *died.stderr_tail.lock().unwrap() = line();
    // An agent that died on its own: the failed turn or request quotes it.
    died.meta.lock().unwrap().status = SessionStatus::Disconnected;
    let stopped = session(&hub, "s-memory-stopped");
    *stopped.stderr_tail.lock().unwrap() = line();

    hub.memory().registry().voter().set_level(PressureLevel::Warning);
    assert_eq!(
        *starting.stderr_tail.lock().unwrap(),
        line(),
        "the start still explains its failure"
    );
    assert_eq!(*died.stderr_tail.lock().unwrap(), line(), "the exit still says why");
    assert!(stopped.stderr_tail.lock().unwrap().is_empty(), "acpmux stopped it: nothing quotes it");
    drop(spawning);
}

#[test]
fn memory_live_lists_from_disk_fill_only_harnesses_without_one() {
    let hub = hub();
    hub.live_models.lock().unwrap().insert("claude".into(), vec![model("opus")]);
    let cached = |id: &str| BTreeMap::from([("claude".to_owned(), vec![model(id)])]);
    assert!(!hub.add_live_lists(cached("haiku")), "a probed list is newer than the disk");
    assert_eq!(hub.live_models_for("claude").unwrap(), [model("opus")]);
    hub.live_models.lock().unwrap().clear();
    assert!(hub.add_live_lists(cached("haiku")), "a refill is announced");
    assert_eq!(hub.live_models_for("claude").unwrap(), [model("haiku")]);
}

#[test]
fn memory_live_lists_stay_without_a_runtime_to_announce_their_change() {
    let hub = hub();
    hub.live_models.lock().unwrap().insert("claude".into(), vec![model("opus")]);
    hub.memory().registry().voter().set_level(PressureLevel::Critical);
    assert_eq!(hub.live_models.lock().unwrap().len(), 1);
}

#[test]
fn memory_critical_never_drops_a_pending_prompt() {
    let hub = hub();
    let s = session(&hub, "s-memory-pending");
    let pending = Arc::new(tokio::sync::watch::channel(None).0);
    s.prompts.lock().unwrap().push_back(("pending".into(), pending));
    let source = hub.memory().registry().voter();
    source.set_level(PressureLevel::Critical);
    let kept: Vec<String> = s.prompts.lock().unwrap().iter().map(|(id, _)| id.clone()).collect();
    assert_eq!(kept, ["pending"], "a retry still finds the prompt it waits for");
}

#[test]
fn memory_daemon_status_reports_each_consumers_bytes_and_the_largest_sessions() {
    let hub = hub();
    let small = session(&hub, "s-memory-small");
    let large = session(&hub, "s-memory-large");
    large.stderr_tail.lock().unwrap().push_back("x".repeat(64 * 1024));
    assert!(large.approx_bytes() > small.approx_bytes() + 64 * 1024 - 1);

    let status = crate::daemon_status::memory_status(&hub);
    let names: Vec<&str> = status["consumers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    for name in [
        names::AUTH_CACHE,
        names::STDERR_TAILS,
        names::PROMPT_OUTCOMES,
        names::LIVE_MODELS,
        names::CHAT_INDEX,
        names::LOGIN_ENV,
    ] {
        assert!(names.contains(&name), "{name} missing from {status}");
    }
    let tails = status["consumers"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == names::STDERR_TAILS)
        .unwrap();
    assert!(tails["bytes"].as_u64().unwrap() >= 64 * 1024, "{tails}");
    assert_eq!(tails["retention"], "lossless");
    // No chat index started: its bytes are unknown, not zero.
    let chats =
        status["consumers"].as_array().unwrap().iter().find(|c| c["name"] == names::CHAT_INDEX);
    assert!(chats.unwrap()["bytes"].is_null());
    assert_eq!(status["level"], "normal");
    assert_eq!(status["top"][0]["session_id"], "s-memory-large");
    assert_eq!(status["top"].as_array().unwrap().len(), 2);
    assert!(status["session_bytes"].as_u64().unwrap() >= 64 * 1024);
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    assert!(status["footprint_bytes"].as_u64().unwrap() > 0);
}
