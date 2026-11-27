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

    let large = "x".repeat(3 * 1024 * 1024);
    let saved =
        c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": large})).await.unwrap();
    assert_eq!(saved["draft"].as_str().unwrap().len(), 3 * 1024 * 1024);
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(loaded["draft"].as_str().unwrap().len(), 3 * 1024 * 1024);
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

/// `_acpmux/draft_set {attachments}` and `_acpmux/draft_get {attachments: true}`: the draft's
/// chips round-trip through the daemon with its text, in order and in their place, contents
/// travel once, and a page that never asks for them sees the answer it always did.
#[tokio::test]
async fn draft_attachments_rpc_round_trip_in_place() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let session =
        c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = session["sessionId"].as_str().unwrap().to_owned();
    let text = "see \u{FFFC}img-1\u{FFFC} here";
    let chip = json!({"id": "img-1", "kind": "image", "inline": true, "name": "a.png",
                      "mimeType": "image/png", "size": 4, "data": "iVBO"});

    let saved = c
        .request(
            method::MUX_DRAFT_SET,
            json!({"sessionId": id, "text": text, "attachments": [chip.clone()]}),
        )
        .await
        .unwrap();
    assert_eq!(saved["draft"], text);
    assert_eq!(saved["held"], json!(["img-1"]));

    // An older page: no `attachments` asked, none answered.
    let plain = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(plain["draft"], text);
    assert!(plain.get("attachments").is_none(), "{plain}");

    // The chip named again without its contents (a reconnect's write): its bytes stay.
    let mut named = chip.clone();
    named.as_object_mut().unwrap().remove("data");
    let saved = c
        .request(method::MUX_DRAFT_SET, json!({"sessionId": id, "attachments": [named]}))
        .await
        .unwrap();
    assert_eq!(saved["held"], json!(["img-1"]));
    assert!(saved.get("draft").is_none(), "the text is left as it was: {saved}");
    let loaded = c
        .request(method::MUX_DRAFT_GET, json!({"sessionId": id, "attachments": true}))
        .await
        .unwrap();
    assert_eq!(loaded["draft"], text);
    assert_eq!(loaded["attachments"], json!([chip]));

    // A bad list is refused whole; neither field at all is refused as before.
    let bad = c
        .request(method::MUX_DRAFT_SET, json!({"sessionId": id, "attachments": [{"name": "x"}]}))
        .await;
    assert!(bad.is_err());
    assert!(c.request(method::MUX_DRAFT_SET, json!({"sessionId": id})).await.is_err());
    let loaded = c
        .request(method::MUX_DRAFT_GET, json!({"sessionId": id, "attachments": true}))
        .await
        .unwrap();
    assert_eq!(loaded["attachments"].as_array().map(Vec::len), Some(1));

    // Forgotten with an empty list.
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "attachments": []})).await.unwrap();
    let loaded = c
        .request(method::MUX_DRAFT_GET, json!({"sessionId": id, "attachments": true}))
        .await
        .unwrap();
    assert_eq!(loaded["attachments"], json!([]));
}
