use super::*;

// Prompt bookmarks live in session meta beside the draft, and share these helpers.
#[path = "bookmarks.rs"]
mod bookmarks;

#[tokio::test]
async fn composer_draft_rpc_round_trip_and_clear() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let session =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = session["sessionId"].as_str().unwrap().to_owned();

    let saved = c
        .request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "keep this"}))
        .await
        .unwrap();
    assert_eq!(saved["draft"], "keep this");
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(loaded["draft"], "keep this");

    let cleared =
        c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": " \n\t"})).await.unwrap();
    assert!(cleared["draft"].is_null());
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(loaded["draft"].is_null());

    let too_large = "x".repeat(acpmux::hub::Hub::MAX_COMPOSER_DRAFT_CHARS + 1);
    assert!(
        c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": too_large}))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn a_sent_draft_is_cleared_and_another_prompt_keeps_it() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let session =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = session["sessionId"].as_str().unwrap().to_owned();
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});

    // Another client (the TUI, another pane) sends something else: the
    // pane's unsent text stays.
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "still typing"}))
        .await
        .unwrap();
    c.request(method::SESSION_PROMPT, prompt("something else")).await.unwrap();
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(loaded["draft"], "still typing");

    // The draft itself is sent, from whichever client: it is no longer unsent.
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "send this\n"}))
        .await
        .unwrap();
    c.request(method::SESSION_PROMPT, prompt("send this")).await.unwrap();
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(loaded["draft"].is_null(), "{loaded}");
}
