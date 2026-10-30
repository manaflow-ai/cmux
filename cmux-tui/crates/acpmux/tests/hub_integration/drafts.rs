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

#[tokio::test]
async fn composer_draft_explicit_clear_before_send_does_not_advance_twice() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "draft-clear-before-send").await;
    for (text, generation) in [("send this", 0), ("", 1)] {
        c.request(
            method::MUX_DRAFT_SET,
            json!({"sessionId": id, "text": text, "generation": generation}),
        )
        .await
        .unwrap();
    }
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "send this"}]}),
    )
    .await
    .unwrap();
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(loaded["draft"].is_null());
    assert_eq!(loaded["generation"], 1);
}

#[tokio::test]
async fn composer_draft_safe_integer_limit_cannot_wrap_or_revive_a_clear() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "draft-generation-limit").await;
    let generation = 9_007_199_254_740_991_u64;
    for text in ["last draft", "last draft typed", ""] {
        let saved = c
            .request(
                method::MUX_DRAFT_SET,
                json!({"sessionId": id, "text": text, "generation": generation}),
            )
            .await
            .unwrap();
        assert_eq!(saved["generation"], generation);
    }
    assert!(
        c.request(
            method::MUX_DRAFT_SET,
            json!({"sessionId": id, "text": "late draft", "generation": generation})
        )
        .await
        .is_err()
    );
}

#[tokio::test]
async fn composer_draft_concurrent_generations_persist_the_newest() {
    let dir =
        std::env::temp_dir().join(format!("acpmux-draft-concurrent-{}", uuid::Uuid::now_v7()));
    let (cfg, hub) = bookmarks::local_hub(&dir);
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "draft-concurrent").await;
    let session = hub.resolve(&id).unwrap();
    let barrier = std::sync::Barrier::new(8);
    std::thread::scope(|workers| {
        for generation in 1..=8 {
            let (hub, session, barrier) = (&hub, &session, &barrier);
            workers.spawn(move || {
                barrier.wait();
                let text = if generation == 8 { "" } else { "old text" };
                let result = hub.set_composer_draft(session, text, generation);
                if generation == 8 {
                    assert!(result.unwrap().is_none());
                }
            });
        }
    });
    // Read from disk before shutdown could write the in-memory state again.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let reloaded = store.load(&id).unwrap().unwrap();
    assert!(reloaded.composer_draft.is_none());
    assert_eq!(reloaded.composer_draft_generation, 8);
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    std::fs::remove_dir_all(dir).unwrap();
}
