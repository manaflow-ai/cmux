use super::*;

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
