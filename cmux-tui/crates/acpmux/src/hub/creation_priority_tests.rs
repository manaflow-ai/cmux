use super::super::NewRequest;
use super::*;
use crate::store::{CreatedBy, CreatorKind};
use crate::subrouter_priority::{BACKGROUND, INTERACTIVE, TAG};

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(serde_json::json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A chat as the cmux daemon on a Cloud VM creates it over the unix socket: no person proven, so
/// a script's, with the class the daemon asked for (`subrouter_priority::asked_tag`).
async fn cloud_chat(hub: &Arc<Hub>, priority: Option<&str>) -> Arc<Session> {
    hub.new_session(NewRequest {
        cwd: Some(std::env::temp_dir()),
        created_by: Some(CreatedBy { kind: CreatorKind::Script, workspace: None, session: None }),
        priority: priority.map(str::to_owned),
        ..NewRequest::default()
    })
    .await
    .unwrap()
}

/// The class `cold_start` gives the agent (`lifecycle_cold_start.rs`), from the meta as the
/// first spawn reads it.
fn cold_start_class(hub: &Hub, s: &Session) -> &'static str {
    let meta = s.meta();
    let for_person = made_for_a_person(meta.created_by.as_ref(), false);
    hub.subrouter_priority(s, &meta, for_person)
}

/// cloud-chat-replies-production, 2026-11-28 02:49Z: a chat the person started on a Cloud VM
/// ran `background`, and the gateway refused it from the interactive reserve (429). The class its
/// create asks for is on the chat before its agent first spawns.
#[cfg(unix)]
#[tokio::test]
async fn a_cloud_chat_runs_at_the_class_its_create_asked_for_from_its_first_spawn() {
    let hub = test_hub();
    let asked = cloud_chat(&hub, Some(INTERACTIVE)).await;
    assert_eq!(asked.meta().tags.get(TAG).map(|t| t.value.as_str()), Some(INTERACTIVE));
    assert_eq!(cold_start_class(&hub, &asked), INTERACTIVE);
    let script = cloud_chat(&hub, None).await;
    assert!(script.meta().tags.get(TAG).is_none());
    assert_eq!(cold_start_class(&hub, &script), BACKGROUND, "a script's chat stays background");
}
