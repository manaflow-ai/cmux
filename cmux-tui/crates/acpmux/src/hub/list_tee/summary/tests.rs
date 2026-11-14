use super::*;

async fn fixture(secret: bool) -> (std::sync::Arc<Hub>, std::sync::Arc<Session>) {
    let mut config = crate::config::Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let mut meta = crate::god_fixture::session_meta(
        "fixture",
        "fixture",
        "/work/project///",
        "native-id",
        400,
        crate::store::now_ms(),
    );
    meta["status"] = Value::from("closed");
    meta["lastPrompt"] = Value::from("p".repeat(100_000));
    meta["preview"] = Value::from("v".repeat(100_000));
    if secret {
        meta["title"] =
            Value::from(format!("token gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"));
    }
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(config, store);
    hub.wait_store().await;
    let session = hub.sessions.lock().unwrap().get("fixture").cloned().unwrap();
    (hub, session)
}

#[tokio::test]
async fn a_long_v1_summary_keeps_required_shapes_without_empty_extra() {
    let (hub, session) = fixture(false).await;
    let row = summary_from_session(&hub, &session).unwrap();
    row.validate().unwrap();
    let extra: Value = serde_json::from_str(row.extra.get()).unwrap();
    assert_eq!(row.folder.as_deref(), Some("/work/project"));
    assert_eq!(extra["cwd"], "/work/project///");
    assert!(extra["lastPrompt"].as_str().unwrap().chars().count() <= TEXT_CHARS);
    assert!(extra["preview"].as_str().unwrap().chars().count() <= TEXT_CHARS);
    assert!(extra.get("forkSeq").is_some());
    assert!(extra.get("spawnedBy").is_none());
    assert!(extra.get("queue").is_none());
    assert!(extra.get("usageStats").is_none());
    assert!(extra.get("tools").is_none());
    assert!(row.peer_form.is_none());
    assert_eq!(row.last_activity, session.meta().updated_at);
}

#[tokio::test]
async fn peer_form_is_a_masked_summary_and_keeps_the_local_secret_local() {
    let (hub, session) = fixture(true).await;
    let row = summary_from_session(&hub, &session).unwrap();
    row.validate().unwrap();
    assert!(row.title.contains("ghp_"));
    let peer: Summary = serde_json::from_str(row.peer_form.as_ref().unwrap().get()).unwrap();
    assert!(!peer.title.contains("ghp_"));
    assert!(peer.title.contains("GitHub"));
    assert_eq!(peer.chat_id, row.chat_id);
    assert_eq!(peer.archived, row.archived);
    assert!(peer.peer_form.is_none());
}

#[tokio::test]
async fn peer_form_keeps_stuck_details_but_masks_scanned_error_text() {
    let (hub, session) = fixture(false).await;
    hub.edit_test_meta(&session, |meta| {
        meta.status = crate::store::SessionStatus::Running;
        meta.last_prompt = None;
        meta.preview = None;
        let base = meta.harness_failures.through_seq;
        for offset in 1..=3 {
            let seq = base + offset;
            meta.harness_failures.observe(
                &serde_json::json!({
                    "status": "failed",
                    "errorText": "HTTP 503 bearer ghp_aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"
                }),
                seq,
                offset * 10,
            );
        }
    });
    let row = summary_from_session(&hub, &session).unwrap();
    let local: Value = serde_json::from_str(row.extra.get()).unwrap();
    assert_eq!(local["stuckSince"], 30);
    assert_eq!(local["stuckError"], "HTTP 503 [redacted]");
    let peer: Summary = serde_json::from_str(row.peer_form.as_ref().unwrap().get()).unwrap();
    let peer_extra: Value = serde_json::from_str(peer.extra.get()).unwrap();
    assert!(peer_extra.get("stuckSince").is_none());
    assert!(peer_extra.get("stuckError").is_none());
}

#[tokio::test]
async fn display_lists_shrink_without_losing_required_keys_or_the_peer_form() {
    let (hub, session) = fixture(true).await;
    hub.edit_test_meta(&session, |meta| {
        meta.pull_requests = (0..LIST_ITEMS)
            .map(|n| format!("https://example.test/{n}/{}", "p".repeat(200)))
            .collect();
    });
    let row = summary_from_session(&hub, &session).unwrap();
    row.validate().unwrap();
    let peer: Summary = serde_json::from_str(row.peer_form.as_ref().unwrap().get()).unwrap();
    for form in [&row, &peer] {
        let extra: Value = serde_json::from_str(form.extra.get()).unwrap();
        let urls = extra["pullRequests"].as_array().unwrap();
        assert_eq!(urls.len(), LIST_ITEMS);
        assert!(urls.iter().all(|url| url.as_str().unwrap().chars().count() <= TEXT_CHARS));
        assert!(urls.iter().any(|url| url.as_str().unwrap().chars().count() < TEXT_CHARS));
        assert!(extra.get("lastPrompt").is_some());
        assert!(extra.get("preview").is_some());
        assert!(extra.get("cwd").is_some());
    }
}

#[tokio::test]
async fn a_multibyte_title_keeps_its_cut_marker_inside_the_byte_bound() {
    let (hub, session) = fixture(false).await;
    hub.edit_test_meta(&session, |meta| meta.title = Some("雪".repeat(TEXT_CHARS)));
    let row = summary_from_session(&hub, &session).unwrap();
    assert!(row.title.len() <= MAX_TITLE_BYTES);
    assert!(row.title.ends_with('…'));
    assert!(row.title.trim_end_matches('…').chars().all(|ch| ch == '雪'));
    assert!(!row.title.trim_end_matches('…').is_empty());
}

#[tokio::test]
async fn workspace_comes_from_own_metadata_when_the_v1_row_omits_it() {
    let (hub, session) = fixture(false).await;
    let workspace = "00000000-0000-4000-8000-000000000001";
    hub.edit_test_meta(&session, |meta| meta.workspace_id = Some(workspace.into()));
    assert!(hub.session_list_summary(&session).get("workspaceId").is_none());
    let row = summary_from_session(&hub, &session).unwrap();
    assert_eq!(row.workspace.as_deref(), Some(workspace));
}

#[tokio::test]
async fn parent_folding_matches_v1_without_rewriting_the_child() {
    let (hub, parent) = fixture(false).await;
    let mut child_meta = parent.meta();
    child_meta.id = "child".into();
    child_meta.subsession = Some(crate::store::SubsessionLink {
        started_by: parent.id.clone(),
        short_name: "child".into(),
        depth: 1,
        offered: false,
    });
    let child = hub.insert_test_session(child_meta);
    let original = summary_from_session(&hub, &child).unwrap();
    for case in ["root", "archived", "nested", "root-again"] {
        hub.edit_test_meta(&parent, |meta| {
            meta.tags.remove("archived");
            meta.subsession = None;
            if case == "archived" {
                meta.tags.insert(
                    "archived".into(),
                    crate::store::Tag { value: "true".into(), expires_at: None },
                );
            } else if case == "nested" {
                meta.subsession = Some(crate::store::SubsessionLink {
                    started_by: "grandparent".into(),
                    short_name: "parent".into(),
                    depth: 1,
                    offered: false,
                });
            }
        });
        let child_row = summary_from_session(&hub, &child).unwrap();
        let parent_row = summary_from_session(&hub, &parent).unwrap();
        assert_eq!(parent_row.archived, case == "archived");
        assert!(child_row.same_content(&original), "parent case {case} changed the child");
        assert_eq!(
            Summary::listed_under(&child_row, Some(&parent_row)),
            hub.spawned_by(&child.meta()).is_some(),
            "parent case {case}",
        );
    }
    assert!(!Summary::listed_under(&original, None));
}

#[tokio::test]
async fn expired_archived_tag_is_not_copied_to_the_typed_row() {
    let (hub, parent) = fixture(false).await;
    hub.edit_test_meta(&parent, |meta| {
        meta.tags.insert(
            "archived".into(),
            crate::store::Tag {
                value: "true".into(),
                expires_at: Some(crate::store::now_ms().saturating_sub(1)),
            },
        );
    });
    assert!(!summary_from_session(&hub, &parent).unwrap().archived);
}
