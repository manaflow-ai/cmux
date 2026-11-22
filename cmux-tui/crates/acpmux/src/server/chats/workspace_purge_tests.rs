//! `_acpmux/workspace_purge` (`workspace_purge.rs`): an incognito workspace's chats are stopped
//! and purged, every other chat is kept, only the local socket may ask, and a harness transcript
//! older than its session (an adopted chat) is never deleted.

use super::*;
use crate::hub::NewRequest;

const INCOGNITO: &str = "3f2b8c1e-5d4a-4b6f-9e7d-0a1b2c3d4e5f";
const NORMAL: &str = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";

/// A hub on the stand-in agent, its chat log in memory.
fn hub() -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn chat(hub: &Arc<Hub>, workspace: Option<&str>) -> String {
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        workspace_id: workspace.map(str::to_owned),
        ..NewRequest::default()
    };
    hub.new_session(req).await.unwrap().id.clone()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn purges_only_the_workspaces_chats() {
    let hub = hub();
    let first = chat(&hub, Some(INCOGNITO)).await;
    let second = chat(&hub, Some(INCOGNITO)).await;
    let other = chat(&hub, Some(NORMAL)).await;
    let none = chat(&hub, None).await;
    // The app may send the workspace key in its own case; acpmux stores it lowercase.
    let reply = handle(&hub, Origin::Local, &json!({"workspaceId": INCOGNITO.to_uppercase()}))
        .await
        .unwrap();
    let mut purged: Vec<String> = serde_json::from_value(reply["purged"].clone()).unwrap();
    purged.sort();
    let mut expected = vec![first.clone(), second.clone()];
    expected.sort();
    assert_eq!(purged, expected, "{reply}");
    assert_eq!(reply["workspaceId"], INCOGNITO);
    for id in [&first, &second] {
        assert!(hub.resolve(id).is_err(), "incognito chat {id} is still listed");
    }
    for id in [&other, &none] {
        assert!(hub.resolve(id).is_ok(), "chat {id} of another workspace was purged");
    }
    // A second close finds nothing left.
    let again = handle(&hub, Origin::Local, &json!({"workspaceId": INCOGNITO})).await.unwrap();
    assert_eq!(again["purged"], json!([]));
}

#[tokio::test]
async fn only_the_local_socket_may_purge() {
    let hub = hub();
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let e = handle(&hub, origin, &json!({"workspaceId": INCOGNITO})).await.unwrap_err();
        assert!(e.message.contains("local unix socket"), "{origin:?}: {e:?}");
    }
    let e = handle(&hub, Origin::Local, &json!({"workspaceId": "handle:1"})).await.unwrap_err();
    assert!(e.message.contains("workspace id"), "{e:?}");
    assert!(handle(&hub, Origin::Local, &json!({})).await.is_err());
}

#[test]
fn a_transcript_older_than_its_session_is_kept() {
    let dir = std::env::temp_dir().join(format!("acpmux-workspace-purge-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let id = "0c8f3e2a-1b4d-4e6f-8a9b-7c6d5e4f3a2b";
    let file = dir.join(format!("{id}.jsonl"));
    std::fs::write(&file, "{}\n").unwrap();
    // Made before the session: an adopted conversation. Made after: the session's own.
    let later = SystemTime::now() + Duration::from_secs(3600);
    assert!(!born_since(&file, later));
    assert!(born_since(&file, UNIX_EPOCH));
    assert!(names(&file, id));
    assert!(names(&dir.join(format!("rollout-2026-11-01T10-00-00-{id}.jsonl")), id));
    assert!(!names(&dir.join("state_5.sqlite"), id), "a shared store file is never a transcript");
    assert!(!names(&dir.join(format!("{id}.json")), id));
    assert!(!names(&file, ""));
    assert!(!born_since(&dir.join("missing.jsonl"), UNIX_EPOCH));
    std::fs::remove_dir_all(&dir).unwrap();
}
