//! `title_log.rs`: each title outcome is one line in the log, never the title's text.

use super::*;

async fn chat(dir: &std::path::Path) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    super::title_log::TEST_PATH.with(|p| *p.borrow_mut() = Some(dir.join(super::title_log::FILE)));
    (hub, session)
}

fn lines(dir: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(dir.join(super::title_log::FILE))
        .unwrap_or_default()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn tmp(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-{name}-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    dir
}

#[tokio::test]
async fn a_generated_title_and_an_empty_answer_are_logged_without_text() {
    let dir = tmp("title-log-a");
    let (hub, session) = chat(&dir).await;
    session.meta.lock().unwrap().title_source = Some("asked".to_owned());
    hub.apply_generated_title(&session, None);
    session.meta.lock().unwrap().title_source = Some("asked".to_owned());
    hub.apply_generated_title(&session, Some("Fix the flaky build".to_owned()));
    let log = lines(&dir);
    assert_eq!(log.len(), 2, "{log:?}");
    assert_eq!(log[0]["outcome"], "empty");
    assert_eq!(log[1]["outcome"], "generated");
    assert_eq!(log[1]["words"], 4);
    assert_eq!(log[1]["session"], session.id.as_str());
    let raw = std::fs::read_to_string(dir.join(super::title_log::FILE)).unwrap();
    assert!(!raw.contains("flaky"), "the title's text was logged: {raw}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_person_renaming_after_a_generated_title_is_a_logged_miss() {
    let dir = tmp("title-log-b");
    let (hub, session) = chat(&dir).await;
    session.meta.lock().unwrap().title_source = Some("asked".to_owned());
    hub.apply_generated_title(&session, Some("Fix the flaky build".to_owned()));
    hub.rename(&session, "ship-the-release".to_owned()).await.unwrap();
    let log = lines(&dir);
    let last = log.last().unwrap();
    assert_eq!(last["outcome"], "renamed", "{log:?}");
    assert_eq!(last["prev_source"], "generated");
    let _ = std::fs::remove_dir_all(&dir);
}
