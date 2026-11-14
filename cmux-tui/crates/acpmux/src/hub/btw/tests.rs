use super::*;

#[tokio::test]
async fn inline_transcript_cleanup_targets_only_requested_session() {
    let root = std::env::temp_dir().join(format!("acpmux-btw-cancel-{}", uuid::Uuid::now_v7()));
    let projects = root.join("projects").join("p");
    std::fs::create_dir_all(&projects).unwrap();
    let transcript = projects.join("temporary.jsonl");
    let concurrent = projects.join("concurrent.jsonl");
    let env = std::collections::BTreeMap::from([(
        "CLAUDE_CONFIG_DIR".to_owned(),
        root.to_string_lossy().into_owned(),
    )]);
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    std::fs::write(&transcript, "temporary").unwrap();
    std::fs::write(&concurrent, "concurrent").unwrap();
    assert!(transcript.exists());
    remove_transcript("claude", &env, "temporary");
    assert!(!transcript.exists(), "inline cleanup leaves no temporary transcript");
    assert!(concurrent.exists(), "cleanup must preserve a concurrent transcript");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

fn claude_profile(env: &[(&str, &str)]) -> crate::config::HarnessProfile {
    serde_json::from_value(json!({
            "kind": "claude-stdio",
            "argv": ["claude"],
            "family": "claude",
            "env": env.iter().map(|(k, v)| (k.to_string(), json!(v))).collect::<serde_json::Map<_, _>>(),
        }))
        .unwrap()
}

fn side_meta(harness: &str, cwd: &std::path::Path) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA,
        "id": "side",
        "name": "side",
        "harness": harness,
        "family": "claude",
        "cwd": cwd,
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
    }))
    .unwrap()
}

/// A profile's `${home}` store is expanded as at spawn; the parent's raw env
/// (what cleanup used before) leaves the template, which `HarnessHomes` skips.
#[tokio::test]
async fn inline_cleanup_store_expands_profile_home_template() {
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "claude-iso".into(),
        claude_profile(&[("CLAUDE_CONFIG_DIR", "${home}/isolated-claude")]),
    );
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let meta = side_meta("claude-iso", &std::env::temp_dir());
    let raw = std::collections::BTreeMap::from([(
        "CLAUDE_CONFIG_DIR".to_owned(),
        "${home}/isolated-claude".to_owned(),
    )]);
    let env = hub.btw_store_env(&meta, &raw).await;
    let home = dirs::home_dir().unwrap_or_default();
    assert_eq!(
        env.get("CLAUDE_CONFIG_DIR").map(std::path::PathBuf::from),
        Some(home.join("isolated-claude")),
    );
    let homes = crate::adopt::HarnessHomes::from_env();
    assert_eq!(homes.with_env(&[&env]).claude, home.join("isolated-claude"));
    assert_ne!(homes.with_env(&[&raw]).claude, home.join("isolated-claude"));
    hub.shutdown_all().await;
}

/// A creation that fails after its harness wrote a transcript is discarded inside
/// `new_session`/`fork`, out of the request's sight: an inline /btw's session takes its
/// transcript with it, and any other discarded session keeps its harness's files.
#[tokio::test]
async fn discarded_inline_creation_removes_its_transcript_and_only_its_own() {
    let root = std::env::temp_dir().join(format!("acpmux-btw-discard-{}", uuid::Uuid::now_v7()));
    let projects = root.join("projects").join("p");
    std::fs::create_dir_all(&projects).unwrap();
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "claude-iso".into(),
        claude_profile(&[("CLAUDE_CONFIG_DIR", &root.to_string_lossy())]),
    );
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let env = std::collections::BTreeMap::from([(
        "CLAUDE_CONFIG_DIR".to_owned(),
        root.to_string_lossy().into_owned(),
    )]);
    let publish = |name: &str, sid: &str| {
        let mut meta = side_meta("claude-iso", &root);
        meta.id = format!("id-{name}");
        meta.name = name.to_owned();
        meta.agent_session_id = Some(sid.to_owned());
        std::fs::write(projects.join(format!("{sid}.jsonl")), sid).unwrap();
        let session = hub.make_session(meta);
        hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
        session
    };
    let inline = publish("chat-btw-1", "inline-transcript");
    let other = publish("chat", "other-transcript");
    let owned = InlineOwned::new(&hub, "chat-btw-1", "claude", &env);
    hub.discard_failed_creation(&inline, 0).await;
    hub.discard_failed_creation(&other, 0).await;
    drop(owned);
    assert!(hub.resolve(&inline.id).is_err(), "the inline session is discarded");
    assert!(hub.resolve(&other.id).is_err(), "the other session is discarded");
    assert!(
        !projects.join("inline-transcript.jsonl").exists(),
        "the inline session's transcript goes with it"
    );
    assert!(
        projects.join("other-transcript.jsonl").exists(),
        "a session no inline request owns keeps its transcript"
    );
    assert!(hub.inline_btw.lock().unwrap().is_empty(), "the request's mark is gone");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// A creation cancelled at its deadline is purged by its CreationGuard on a spawned task,
/// which can run after the request (and its mark) is gone: the guard keeps the owner it
/// read when it was made, so the transcript still goes.
#[tokio::test]
async fn a_creation_guard_cleans_the_inline_transcript_after_the_request_ended() {
    let root = std::env::temp_dir().join(format!("acpmux-btw-guard-{}", uuid::Uuid::now_v7()));
    let projects = root.join("projects").join("p");
    std::fs::create_dir_all(&projects).unwrap();
    let mut cfg = Config::default();
    cfg.harnesses.insert(
        "claude-iso".into(),
        claude_profile(&[("CLAUDE_CONFIG_DIR", &root.to_string_lossy())]),
    );
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let env = std::collections::BTreeMap::from([(
        "CLAUDE_CONFIG_DIR".to_owned(),
        root.to_string_lossy().into_owned(),
    )]);
    let mut meta = side_meta("claude-iso", &root);
    meta.id = "id-guarded".into();
    meta.name = "chat-btw-2".into();
    meta.agent_session_id = Some("guarded-transcript".into());
    let transcript = projects.join("guarded-transcript.jsonl");
    std::fs::write(&transcript, "guarded").unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    let owned = InlineOwned::new(&hub, "chat-btw-2", "claude", &env);
    let guard = super::super::lifecycle::CreationGuard::new(hub.clone(), session.clone(), 0);
    // The request ends first (its deadline passed), then the cancelled creation drops.
    drop(owned);
    drop(guard);
    for _ in 0..200 {
        if !transcript.exists() && hub.resolve(&session.id).is_err() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert!(hub.resolve(&session.id).is_err(), "the guard discards the session");
    assert!(!transcript.exists(), "and its transcript, though the request's mark is gone");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// A family default's store (here `${cwd}`-relative) is where cleanup looks,
/// and the temporary transcript in it is removed.
#[tokio::test]
async fn inline_cleanup_removes_transcript_from_family_default_store() {
    let root = std::env::temp_dir().join(format!("acpmux-btw-family-{}", uuid::Uuid::now_v7()));
    let projects = root.join("family-store").join("projects").join("p");
    std::fs::create_dir_all(&projects).unwrap();
    let transcript = projects.join("temporary.jsonl");
    std::fs::write(&transcript, "temporary").unwrap();
    let mut cfg = Config::default();
    cfg.harnesses.insert("claude-fam".into(), claude_profile(&[]));
    cfg.defaults.insert(
        "claude".into(),
        crate::config::SessionDefaults {
            env: std::collections::BTreeMap::from([(
                "CLAUDE_CONFIG_DIR".to_owned(),
                "${cwd}/family-store".to_owned(),
            )]),
            ..Default::default()
        },
    );
    let hub = Hub::new(cfg, Box::new(crate::store::MemoryStore::default()));
    let meta = side_meta("claude-fam", &root);
    // The parent's env carries no family defaults at all.
    let env = hub.btw_store_env(&meta, &Default::default()).await;
    assert_eq!(
        env.get("CLAUDE_CONFIG_DIR").map(std::path::PathBuf::from),
        Some(root.join("family-store")),
    );
    remove_transcript("claude", &env, "temporary");
    assert!(!transcript.exists(), "cleanup removes the transcript from the family default store");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
