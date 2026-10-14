use super::*;

// A session an agent starts from inside its own chat (Leo 2026-10-13: lanes' child sessions,
// titled "Coordinator: ...", listed at the top of the New Tab Chats list) names its parent, so
// the lists fold it under that chat. A parent that is not a session here is not kept.
#[tokio::test]
async fn a_session_started_from_another_names_it_as_its_parent() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let parent =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let parent_id = parent["sessionId"].as_str().unwrap().to_owned();
    assert!(parent.pointer("/_meta/acpmux/spawnedBy").is_none_or(Value::is_null));

    let child = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"spawnedBy": parent_id}}}),
        )
        .await
        .unwrap();
    assert_eq!(child["_meta"]["acpmux"]["spawnedBy"], parent_id.as_str());

    let stray = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"spawnedBy": "no-such-session"}}}),
        )
        .await
        .unwrap();
    assert!(stray.pointer("/_meta/acpmux/spawnedBy").is_none_or(Value::is_null));
}
