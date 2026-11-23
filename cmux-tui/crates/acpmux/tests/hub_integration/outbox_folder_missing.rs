//! An outbox send (`_acpmux/send_queue`, `acpmux send --no-wait`) to a session whose folder is
//! gone: refused once, at once, with the reason and the folder in what its sender reads
//! (`send_status`), never tried again for a day (a probe folder under /tmp was tried about 18
//! times for each message on a loaded Mac).

use super::*;

#[tokio::test]
async fn a_send_to_a_session_whose_folder_is_gone_fails_after_one_attempt_naming_the_folder() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let folder =
        std::env::temp_dir().join(format!("acpmux-folder-missing-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&folder).unwrap();
    let s = c.request(method::SESSION_NEW, json!({"cwd": folder, "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    // No agent runs, so the next prompt checks the folder before it is taken.
    hub.detach_child(&hub.resolve(&id).unwrap()).await;
    std::fs::remove_dir_all(&folder).unwrap();

    let request = json!({"sessionId": id, "prompt": [{"type": "text", "text": "anyone there?"}]});
    let queued = c.request(method::MUX_SEND_QUEUE, json!({"request": request})).await.unwrap();
    let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
    let status = c
        .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 10_000}))
        .await
        .unwrap();
    assert_eq!(status["status"], "failed", "{status}");
    assert_eq!(status["attempts"], 1, "{status}");
    assert_eq!(status["reason"], "session.folder_missing", "{status}");
    let error = status["error"].as_str().unwrap();
    assert!(error.starts_with("session.folder_missing"), "{status}");
    assert!(error.contains(folder.to_str().unwrap()), "the folder is not named: {status}");

    // Settled: nothing tries it again later.
    tokio::time::sleep(Duration::from_secs(3)).await;
    let later = c.request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery})).await.unwrap();
    assert_eq!(later["attempts"], 1, "{later}");
    assert_eq!(later["status"], "failed", "{later}");
    hub.shutdown_all().await;
}
