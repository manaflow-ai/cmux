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
    assert_eq!(loaded["generation"], 1);
    assert!(
        c.request(
            method::MUX_DRAFT_SET,
            json!({"sessionId": id, "text": "send this", "generation": 0})
        )
        .await
        .is_err()
    );
    // The web client's matching explicit clear acknowledges that same send boundary.
    let cleared = c
        .request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "", "generation": 1}))
        .await
        .unwrap();
    assert_eq!(cleared["generation"], 1);
}

#[tokio::test]
async fn composer_draft_generations_reject_stale_and_legacy_writes_but_allow_typing() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "draft-generations").await;
    let initial = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(initial["generation"], 0);
    for (generation, text) in [(0, "old"), (1, "replacement"), (1, "replacement typed")] {
        let saved = c
            .request(
                method::MUX_DRAFT_SET,
                json!({"sessionId": id, "text": text, "generation": generation}),
            )
            .await
            .unwrap();
        assert_eq!(saved["draft"], text);
        assert_eq!(saved["generation"], generation);
    }
    for params in [
        json!({"sessionId": id, "text": "late old", "generation": 0}),
        json!({"sessionId": id, "text": "late legacy"}),
        json!({"sessionId": id, "text": "", "generation": 0}),
    ] {
        assert!(c.request(method::MUX_DRAFT_SET, params).await.is_err());
    }
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert_eq!(loaded["draft"], "replacement typed");
    assert_eq!(loaded["generation"], 1);
}

#[tokio::test]
async fn composer_draft_generation_requires_a_nonnegative_safe_integer() {
    let (_hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "draft-generation-validation").await;
    for generation in [
        json!(-1),
        json!(1.5),
        json!("1"),
        json!(null),
        json!(true),
        json!(9_007_199_254_740_992_u64),
    ] {
        assert!(
            c.request(
                method::MUX_DRAFT_SET,
                json!({"sessionId": id, "text": "bad", "generation": generation})
            )
            .await
            .is_err()
        );
    }
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(loaded["draft"].is_null());
    assert_eq!(loaded["generation"], 0);
}

#[tokio::test]
async fn composer_draft_clear_tombstone_survives_reload_without_double_increment() {
    let dir =
        std::env::temp_dir().join(format!("acpmux-draft-generation-{}", uuid::Uuid::now_v7()));
    let (cfg, hub) = bookmarks::local_hub(&dir);
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "draft-tombstone").await;
    c.request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "old", "generation": 4}))
        .await
        .unwrap();
    for _ in 0..2 {
        let cleared = c
            .request(method::MUX_DRAFT_SET, json!({"sessionId": id, "text": "", "generation": 5}))
            .await
            .unwrap();
        assert!(cleared["draft"].is_null());
        assert_eq!(cleared["generation"], 5);
    }
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut c = connect(&hub).await;
    let loaded = c.request(method::MUX_DRAFT_GET, json!({"sessionId": id})).await.unwrap();
    assert!(loaded["draft"].is_null());
    assert_eq!(loaded["generation"], 5);
    for params in [
        json!({"sessionId": id, "text": "resurrected", "generation": 4}),
        json!({"sessionId": id, "text": "resurrected legacy"}),
    ] {
        assert!(c.request(method::MUX_DRAFT_SET, params).await.is_err());
    }
    let typed = c
        .request(
            method::MUX_DRAFT_SET,
            json!({"sessionId": id, "text": "new typing", "generation": 5}),
        )
        .await
        .unwrap();
    assert_eq!(typed["draft"], "new typing");
    assert_eq!(typed["generation"], 5);
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    std::fs::remove_dir_all(dir).unwrap();
}

#[tokio::test]
async fn composer_draft_legacy_file_defaults_to_generation_zero() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "legacy-draft").await;
    let mut legacy = serde_json::to_value(hub.resolve(&id).unwrap().meta()).unwrap();
    legacy.as_object_mut().unwrap().remove("composerDraftGeneration");
    legacy["composerDraft"] = json!("legacy text");
    let meta: acpmux::store::SessionMeta = serde_json::from_value(legacy).unwrap();
    let encoded = serde_json::to_value(meta).unwrap();
    assert_eq!(encoded["composerDraftGeneration"], 0);
    assert_eq!(encoded["composerDraft"], "legacy text");
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

#[tokio::test]
async fn composer_draft_send_persists_clear_before_the_turn_finishes() {
    let dir = std::env::temp_dir().join(format!("acpmux-draft-active-{}", uuid::Uuid::now_v7()));
    let (cfg, hub) = bookmarks::local_hub(&dir);
    let mut c = connect(&hub).await;
    let id = new_session(&mut c, "draft-active-turn").await;
    // Warm the harness first: a startup metadata save must not mask the missing
    // accepted-send save this regression exercises.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "warm up"}]}),
    )
    .await
    .unwrap();
    c.request(
        method::MUX_DRAFT_SET,
        json!({"sessionId": id, "text": "until-cancel", "generation": 4}),
    )
    .await
    .unwrap();
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["sessionId"] == id && p["queued"] == false).await;
    // Reopen the store before completion or shutdown can flush the clear. A daemon
    // crash now must leave the tombstone on disk, not the prompt we just sent.
    assert!(hub.resolve(&id).unwrap().turn().is_some());
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let saved = store.load(&id).unwrap().unwrap();
    assert!(saved.composer_draft.is_none(), "sent draft remains on disk: {saved:?}");
    assert_eq!(saved.composer_draft_generation, 5);
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    drop(store);
    std::fs::remove_dir_all(dir).unwrap();
}
