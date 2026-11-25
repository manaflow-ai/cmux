//! Prompt preparation must answer promptly when configuration is held, while preserving
//! prompt-owned uploads so the same delivery can be retried.

use super::{TestClient, new_session, setup};
use acpmux::config::PermissionPolicy;
use acpmux::rpc::{Message, method};
use base64::Engine;
use serde_json::{Value, json};
use std::time::{Duration, Instant};

async fn upload(c: &mut TestClient, session: &str) -> (String, String) {
    let bytes = b"prompt attachment";
    let begun = c
        .request(
            method::MUX_FILE_PUT_BEGIN,
            json!({"sessionId": session, "fileName": "retry.txt", "size": bytes.len(), "forPrompt": true}),
        )
        .await
        .unwrap();
    let id = begun["uploadId"].as_str().unwrap().to_owned();
    let owner = begun["ownerToken"].as_str().unwrap().to_owned();
    c.request(
        method::MUX_FILE_PUT_CHUNK,
        json!({"sessionId": session, "uploadId": id, "offset": 0,
               "data": base64::engine::general_purpose::STANDARD.encode(bytes)}),
    )
    .await
    .unwrap();
    c.request(
        method::MUX_FILE_PUT_FINISH,
        json!({"sessionId": session, "uploadId": id, "fileName": "retry.txt", "size": bytes.len()}),
    )
    .await
    .unwrap();
    (id, owner)
}

async fn raw_reply(c: &mut TestClient, id: i64) -> Result<Value, Value> {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(10), c.rx.recv())
            .await
            .expect("timeout waiting for prompt response")
            .expect("connection closed");
        if let Message::Response { id: response_id, result, error } = Message::parse(&line).unwrap()
            && response_id == json!(id)
        {
            return match error {
                Some(error) => Err(serde_json::to_value(error).unwrap()),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

#[tokio::test]
async fn prompt_preparation_deadline_preserves_upload_for_retry() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut c, "prompt-preparation-deadline").await;
    let (upload, owner) = upload(&mut c, &session).await;
    let upload_dir = acpmux::config::home().join("uploads").join(&session).join(&upload);
    assert!(upload_dir.is_dir(), "finished prompt upload missing: {upload_dir:?}");
    let prompt_id = "prompt-preparation-retry";
    let params = json!({
        "sessionId": session,
        "prompt": [
            {"type": "text", "text": "retry this prompt"},
            {"type": "image", "mimeType": "image/png",
             "_meta": {"acpmux": {"upload": {"uploadId": upload, "fileName": "retry.txt", "owned": owner}}}}
        ],
        "_meta": {"acpmux": {"promptId": prompt_id}}
    });

    let config_guard = hub.config.write().await;
    c.next += 1;
    let request_id = c.next;
    c.tx.send(Message::request(request_id, method::SESSION_PROMPT, params.clone()).to_line())
        .await
        .unwrap();
    let started = Instant::now();
    let error = raw_reply(&mut c, request_id).await.expect_err("held config should time out");
    assert!(
        started.elapsed() < Duration::from_secs(8),
        "prompt admission exceeded bounded answer time"
    );
    assert_eq!(error["data"]["reason"], "deadline_exceeded", "{error}");
    assert_eq!(error["data"]["wait"], "hub.config.read", "{error}");
    assert_eq!(error["data"]["retryable"], true, "{error}");
    assert!(upload_dir.is_dir(), "timed-out prompt deleted its upload");
    assert!(
        hub.events(&session, 0, 1000).unwrap().iter().all(|event| event.kind != "user_message")
    );
    drop(config_guard);

    let retried = c.request(method::SESSION_PROMPT, params).await.unwrap();
    assert_eq!(retried["stopReason"], "end_turn", "{retried}");
    let events = hub.events(&session, 0, 1000).unwrap();
    assert_eq!(events.iter().filter(|event| event.kind == "user_message").count(), 1, "{events:?}");
    assert!(events.iter().any(|event| event.kind == "turn_end"), "{events:?}");
    assert!(
        events
            .iter()
            .any(|event| event.kind == "user_message" && event.msg["text"] == "retry this prompt"),
        "{events:?}"
    );
}
