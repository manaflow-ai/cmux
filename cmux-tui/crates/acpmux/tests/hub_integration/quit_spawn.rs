//! Agents never outlive the daemon's shutdown: once it has begun, nothing
//! starts an agent (or an agent host) that the shutdown would not end.
use super::*;

/// After the shutdown ended the agents, a new session and a prompt that
/// would respawn a stopped session's agent are both refused. On Quit (End
/// Sessions) the Chief's compactor started slots after the census and
/// their hosts stayed behind with no daemon.
#[tokio::test]
async fn no_agent_starts_once_the_shutdown_has_begun() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "before-quit"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    hub.shutdown_all().await;
    let fresh = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "during-quit"}}}),
        )
        .await;
    assert!(fresh.as_ref().is_err_and(|e| e.contains("shutting down")), "{fresh:?}");
    let respawn = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert!(respawn.as_ref().is_err_and(|e| e.contains("shutting down")), "{respawn:?}");
}
