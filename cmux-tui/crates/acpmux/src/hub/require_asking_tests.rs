use super::*;

fn profile(value: Value) -> HarnessProfile {
    serde_json::from_value(value).unwrap()
}

/// Review F1 (#39320, second round): a start held to asking runs only where the asking
/// table says the harness asks before each change, and is refused, not only logged, elsewhere.
#[test]
fn only_a_harness_that_asks_starts_held_to_asking() {
    let cfg = Config::default();
    let ask = Some(PermissionPolicy::Ask);
    let claude = profile(json!({"argv": ["claude"], "family": "claude"}));
    assert!(admits(&cfg, "claude", &claude, ask, None).is_ok());
    let bridge = profile(json!({"argv": ["codex", "app-server"], "family": "codex"}));
    assert!(admits(&cfg, "codex", &bridge, ask, None).is_ok());
    // The legacy adapter edits and runs without asking in every mode: refused, under any
    // name, including the bare `codex` a person's config may point at it.
    let legacy = profile(json!({"argv": ["codex-acp"], "family": "codex"}));
    for name in ["codex-acp", "codex"] {
        let e = admits(&cfg, name, &legacy, ask, None).unwrap_err();
        assert!(e.message.contains("cannot be held to asking"), "{name}: {}", e.message);
    }
    let opencode = profile(json!({"argv": ["opencode", "acp"], "family": "opencode"}));
    assert!(admits(&cfg, "opencode", &opencode, ask, None).is_err());
    // A family no asking table lists is refused.
    let other = profile(json!({"argv": ["foo-agent"]}));
    assert!(admits(&cfg, "foo", &other, ask, None).is_err());
}

fn hub_on(harnesses: Value) -> Arc<Hub> {
    let cfg = json!({"harnesses": harnesses, "defaultHarness": "codex"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Review F1 (#39320, third round): a config reload between the request check and the start
/// moves bare `codex` from the bridge to the legacy adapter; the start, on the profile it
/// resolves itself, is refused, and nothing is created.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_reload_after_the_check_is_refused_at_the_start() {
    let bridge = json!({"codex": {"argv": ["codex", "app-server"], "family": "codex"}});
    let hub = hub_on(bridge);
    let ask = Some(PermissionPolicy::Ask);
    let name = Some("codex".to_owned());
    let dir = std::env::temp_dir();
    let ok = hub.check_require_asking(name.clone(), None, None, Some(&dir), ask, None, false);
    assert!(ok.await.is_ok());
    // The reload, between the check and the start.
    let legacy = json!({"harnesses": {"codex": {"argv": ["codex-acp"], "family": "codex"}}});
    let mut legacy: Config = serde_json::from_value(legacy).unwrap();
    legacy.store.mode = crate::config::StoreMode::Memory;
    *hub.config.write().await = legacy;
    let req = NewRequest {
        harness: name,
        cwd: Some(dir),
        policy: ask,
        require_asking: true,
        ..NewRequest::default()
    };
    let Err(e) = hub.new_session(req).await else {
        panic!("the start ran on the legacy adapter");
    };
    assert!(e.message.contains("cannot be held to asking"), "{}", e.message);
    assert_eq!(e.data.as_ref().and_then(|d| d["reason"].as_str()), Some("start.not_asking"));
    assert!(hub.sessions.lock().unwrap().is_empty());
}

#[test]
fn a_start_held_to_asking_needs_a_narrow_policy_and_no_mode() {
    let cfg = Config::default();
    let claude = profile(json!({"argv": ["claude"], "family": "claude"}));
    assert!(admits(&cfg, "claude", &claude, None, None).is_err());
    assert!(admits(&cfg, "claude", &claude, Some(PermissionPolicy::ApproveAll), None).is_err());
    let mode = json!({"mode": "bypassPermissions"});
    assert!(admits(&cfg, "claude", &claude, Some(PermissionPolicy::Ask), Some(&mode)).is_err());
    let meta = json!({FIELD: true});
    assert!(asked(Some(&meta)));
    assert!(!asked(Some(&json!({FIELD: "yes"}))));
    assert!(!asked(None));
}
