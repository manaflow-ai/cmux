//! An outbox send (`_acpmux/send_queue`, `acpmux send --no-wait`) to a session whose folder is
//! gone: kept and tried again (the folder may come back), with the reason and the folder in what
//! its sender reads (`send_status`). Only the first attempt runs the full folder check (archive
//! read, worktree recreate); every retry while the folder stays gone is one stat, with no git and
//! no harness started (a probe folder under /tmp was tried about 18 times for each message on a
//! loaded Mac, each time in full).

use super::*;

#[tokio::test]
async fn a_send_to_a_session_whose_folder_is_gone_stays_queued_and_retries_with_one_stat() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let folder =
        std::env::temp_dir().join(format!("acpmux-folder-missing-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&folder).unwrap();
    let s = c.request(method::SESSION_NEW, json!({"cwd": folder, "mcpServers": []})).await;
    let id = s.unwrap()["sessionId"].as_str().unwrap().to_owned();
    c.request(method::SESSION_PROMPT, prompt(&id, "hello", None)).await.unwrap();
    // No agent runs, so the next prompt checks the folder before it is taken.
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    std::fs::remove_dir_all(&folder).unwrap();

    let request = json!({"sessionId": id, "prompt": [{"type": "text", "text": "anyone there?"}]});
    let queued = c.request(method::MUX_SEND_QUEUE, json!({"request": request})).await.unwrap();
    let delivery = queued["deliveryId"].as_str().unwrap().to_owned();
    // Attempts at 0, 2 and 7 s on the outbox's schedule.
    let mut status = Value::Null;
    for _ in 0..30 {
        status = c
            .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 500}))
            .await
            .unwrap();
        if status["attempts"].as_u64().unwrap_or(0) >= 3 && status["error"].is_string() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    assert!(status["attempts"].as_u64().unwrap_or(0) >= 3, "tried again: {status}");
    assert!(matches!(status["status"].as_str(), Some("queued" | "delivering")), "{status}");
    assert_eq!(status["reason"], "session.folder_missing", "{status}");
    let error = status["error"].as_str().unwrap();
    assert!(error.starts_with("session.folder_missing"), "{status}");
    assert!(error.contains(folder.to_str().unwrap()), "the folder is not named: {status}");
    assert!(error.contains("no longer exists"), "{status}");
    // Every retry after the first was one stat: no archive read, no worktree recreate (and no
    // agent: the refusal comes before one starts, `turns.rs` `cold_prompt_check`).
    assert_eq!(hub.folder_missing_full_checks(&folder), 1, "{status}");

    // Back: the next retry runs the full check and delivers it.
    std::fs::create_dir_all(&folder).unwrap();
    for _ in 0..4 {
        status = c
            .request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 10_000}))
            .await
            .unwrap();
        if status["status"] == "delivered" {
            break;
        }
    }
    assert_eq!(status["status"], "delivered", "{status}");
    assert!(status["reason"].is_null(), "{status}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&folder);
}
