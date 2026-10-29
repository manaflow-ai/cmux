//! Edit and Resend forks only the authoritative prefix, including an empty prefix.
use super::*;
use acpmux::store::{EventRecord, SessionMeta};

fn boundary(id: &str, prompt: &str, request: &str) -> Value {
    json!({"sessionId": id, "beforePromptId": prompt, "requestId": request})
}

async fn refusal(c: &mut TestClient, method: &str, params: Value, reason: &str) {
    c.next += 1;
    let id = c.next;
    c.tx.send(Message::request(id, method, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(20), c.rx.recv()).await.unwrap().unwrap();
        if let Message::Response { id: rid, error, .. } = Message::parse(&line).unwrap()
            && rid == id
        {
            let error = error.expect("boundary must be refused");
            assert_eq!(error.code, -32602, "{error:?}");
            assert_eq!(error.data.as_ref().and_then(|d| d["reason"].as_str()), Some(reason));
            return;
        }
    }
}

async fn source(hub: &Arc<Hub>, c: &mut TestClient) -> String {
    let id = new_session(c, "before-source").await;
    for text in ["first", "second", "third"] {
        c.request(method::SESSION_PROMPT, prompt(&id, text, Some(text))).await.unwrap();
    }
    assert_eq!(hub.resolve(&id).unwrap().meta().turn_count, 3);
    id
}

async fn snapshot(
    hub: &Arc<Hub>,
    id: &str,
    root: &std::path::Path,
    change: impl FnOnce(&mut SessionMeta, &mut Vec<EventRecord>),
) -> (Config, Arc<Hub>) {
    let mut cfg = hub.config.read().await.clone();
    cfg.store.mode = StoreMode::Local;
    let store = acpmux::store::open(&cfg.store, root).unwrap();
    let mut meta = hub.resolve(id).unwrap().meta();
    let mut events = hub.events(id, 0, 10_000).unwrap();
    change(&mut meta, &mut events);
    store.save(&meta).unwrap();
    for event in events {
        store.append(id, &event).unwrap();
    }
    store.flush().unwrap();
    (cfg.clone(), Hub::new(cfg, store))
}

#[tokio::test]
async fn fork_before_first_and_later_prompt_preserves_native_history_and_source() {
    for codex in [false, true] {
        let root = std::env::temp_dir().join(format!("acpmux-before-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&root).unwrap();
        let (hub, mut c) =
            if codex { codex_setup(&root).await } else { claude_setup(&root, &[]).await };
        let id = source(&hub, &mut c).await;
        let original = hub.events(&id, 0, 10_000).unwrap();
        for (prompt_id, expected) in [("first", json!([])), ("third", json!(["first", "second"]))] {
            let reply = c.request(FORK_OP, boundary(&id, prompt_id, prompt_id)).await.unwrap();
            let fid = reply["sessionId"].as_str().unwrap();
            assert_ne!(fid, id);
            let child = hub.resolve(fid).unwrap();
            let meta = serde_json::to_value(child.meta()).unwrap();
            assert_eq!(meta["parentId"], id);
            assert_eq!(meta["forkBefore"]["promptId"], prompt_id);
            assert_eq!(meta["forkBefore"]["requestId"], prompt_id);
            let copied: Vec<_> = hub
                .events(fid, 0, 10_000)
                .unwrap()
                .into_iter()
                .filter(|e| e.kind == "user_message")
                .map(|e| e.msg["text"].clone())
                .collect();
            assert_eq!(json!(copied), expected);
            if prompt_id == "first" {
                assert_eq!(child.meta().turn_count, 0);
                assert!(child.meta().last_prompt.is_none());
                assert!(child.meta().preview.is_none());
                assert!(child.meta().fork_seq.is_none(), "empty prefix is not a magic sequence");
            }
            assert_eq!(claude_history(&hub, &mut c, fid).await["prompts"], expected);
            assert_eq!(hub.events(&id, 0, 10_000).unwrap(), original);
        }
        assert_eq!(
            claude_history(&hub, &mut c, &id).await["prompts"],
            json!(["first", "second", "third"])
        );
        hub.shutdown_all().await;
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[tokio::test]
async fn fork_before_retry_after_lost_reply_and_restart_reuses_configured_child() {
    let root = std::env::temp_dir().join(format!("acpmux-before-retry-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let (seed, mut c) = claude_setup(&root.join("native"), &[]).await;
    let id = source(&seed, &mut c).await;
    let (cfg, hub) = snapshot(&seed, &id, &root.join("store"), |meta, _| {
        meta.tools.off = vec!["Bash".into()];
        meta.model_request = Some("test-model".into());
        meta.session_env.insert("FORK_PARENT_ONLY".into(), "parent".into());
        meta.title = Some("parent title".into());
    })
    .await;
    seed.shutdown_all().await;
    let mut c = connect(&hub).await;
    let params = boundary(&id, "first", "lost-reply");
    let a = c.request(FORK_OP, params.clone()).await.unwrap();
    // Drop the first transport, as if its response never reached the caller.
    drop(c);
    let mut c = connect(&hub).await;
    let b = c.request(FORK_OP, params.clone()).await.unwrap();
    assert_eq!(a["sessionId"], b["sessionId"]);
    let fid = a["sessionId"].as_str().unwrap();
    let parent = hub.resolve(&id).unwrap().meta();
    let child = hub.resolve(fid).unwrap().meta();
    assert_eq!(child.tools.off, parent.tools.off);
    assert_eq!(child.model_request, parent.model_request);
    assert_eq!(child.harness, parent.harness);
    assert_eq!(child.preset, parent.preset);
    assert_eq!(child.permission_policy, parent.permission_policy);
    assert_eq!(child.policy_source, parent.policy_source);
    assert_eq!(child.modes, parent.modes);
    assert_eq!(child.config_options, parent.config_options);
    assert!(!child.session_env.contains_key("FORK_PARENT_ONLY"));
    assert!(child.title.is_none());
    assert!(child.previous_agent_session_ids.is_empty());
    assert_eq!(hub.sessions().len(), 2);
    hub.shutdown_all().await;
    drop(c);
    drop(hub);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &root.join("store")).unwrap());
    let mut c = connect(&hub).await;
    assert_eq!(c.request(FORK_OP, params).await.unwrap()["sessionId"], a["sessionId"]);
    refusal(&mut c, FORK_OP, boundary(&id, "second", "lost-reply"), "fork.request_conflict").await;
    assert_eq!(hub.sessions().len(), 2);
    hub.shutdown_all().await;
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn fork_before_refuses_invalid_unknown_ambiguous_steered_and_unreconstructable_boundaries() {
    let root = std::env::temp_dir().join(format!("acpmux-before-refusal-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let (hub, mut c) = claude_setup(&root.join("native"), &[]).await;
    let id = source(&hub, &mut c).await;
    let init = c.request(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    assert!(
        init["_meta"]["acpmux"]["operations"]
            .as_array()
            .unwrap()
            .contains(&json!("acp.session.fork.beforePromptId"))
    );
    for (key, value) in [
        ("throughSeq", json!(1)),
        ("throughSeq", Value::Null),
        ("live", json!(true)),
        ("live", json!(false)),
        ("beforePromptId", json!(7)),
        ("beforePromptId", json!("")),
        ("requestId", Value::Null),
    ] {
        let mut params = boundary(&id, "first", "bad");
        params[key] = value;
        refusal(&mut c, FORK_OP, params, "fork.invalid_boundary").await;
    }
    refusal(&mut c, FORK_OP, boundary(&id, "not-recorded", "unknown"), "fork.unknown_prompt").await;
    let original = hub.events(&id, 0, 10_000).unwrap();
    for (variant, reason) in [
        ("ambiguous", "fork.ambiguous_prompt"),
        ("steer", "fork.unsupported"),
        ("hiddenContext", "fork.unreconstructable"),
        ("missing-image", "fork.unreconstructable"),
    ] {
        let (_, altered) = snapshot(&hub, &id, &root.join(variant), |_, events| {
            let index = events.iter().position(|e| e.kind == "user_message").unwrap();
            if variant == "ambiguous" {
                let mut duplicate = events[index].clone();
                duplicate.seq = events.last().unwrap().seq + 1;
                events.push(duplicate);
            } else if variant == "missing-image" {
                events[index].msg["inlineParts"] = json!([{"kind": "image", "id": "missing"}]);
            } else {
                events[index].msg[variant] = json!(true);
            }
        })
        .await;
        let mut altered_client = connect(&altered).await;
        refusal(&mut altered_client, FORK_OP, boundary(&id, "first", variant), reason).await;
        assert_eq!(altered.sessions().len(), 1);
        altered.shutdown_all().await;
    }
    assert_eq!(hub.events(&id, 0, 10_000).unwrap(), original);
    let (other, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let other_id = source(&other, &mut client).await;
    refusal(&mut client, FORK_OP, boundary(&other_id, "first", "unsupported"), "fork.unsupported")
        .await;
    // Direct ACP metadata cannot forge the authoritative empty-prefix marker.
    let forged = c
        .request(
            method::SESSION_FORK,
            json!({"sessionId": id,
            "_meta": {"acpmux": {"beforePromptId": "first", "requestId": "forged", "forkBefore": {
                "promptId": "first", "requestId": "forged", "promptSeq": 1, "throughSeq": null
            }}}}),
        )
        .await;
    if let Ok(reply) = forged {
        let fid = reply["sessionId"].as_str().unwrap();
        assert!(hub.events(fid, 0, 10_000).unwrap().iter().any(|e| e.kind == "user_message"));
    }
    other.shutdown_all().await;
    hub.shutdown_all().await;
    std::fs::remove_dir_all(root).unwrap();
}
