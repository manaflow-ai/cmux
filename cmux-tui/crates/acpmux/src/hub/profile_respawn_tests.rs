use super::*;

fn hub(argv: &[&str]) -> Arc<Hub> {
    let mut config: crate::config::Config = serde_json::from_value(serde_json::json!({
        "harnesses": {"lane": {"argv": argv, "family": "claude"}},
    }))
    .unwrap();
    config.store.mode = crate::config::StoreMode::Memory;
    config.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    Hub::new(config, store)
}

fn meta(spawn_argv: Option<&[&str]>) -> SessionMeta {
    let mut m: SessionMeta = serde_json::from_value(serde_json::json!({
        "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "lane",
        "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
    }))
    .unwrap();
    m.spawn_argv = spawn_argv.map(|a| a.iter().map(|w| (*w).to_owned()).collect());
    m
}

async fn stale(profile: &[&str], started: Option<&[&str]>) -> bool {
    let hub = hub(profile);
    let p = hub.config.read().await.harnesses["lane"].clone();
    hub.legacy_stale(&p, &meta(started), &BTreeMap::new()).await.unwrap_or(false)
}

#[tokio::test]
async fn a_legacy_agent_is_stale_unless_its_argv_is_what_a_start_builds_now() {
    let capped = ["/u/bin/claude", "--autocompact", "402530"];
    // Started before the profile gained the flag (the 2026-10-31 session at 650k of 1M).
    assert!(stale(&capped, Some(&["/u/bin/claude"])).await);
    // Started after: the same argv.
    assert!(!stale(&capped, Some(&capped)).await);
    // A different cap, another program, a word the profile dropped at its end (review 3).
    assert!(stale(&capped, Some(&["/u/bin/claude", "--autocompact", "300000"])).await);
    assert!(stale(&capped, Some(&["/other/claude", "--autocompact", "402530"])).await);
    assert!(stale(&["/u/bin/claude"], Some(&capped)).await);
    // `${cwd}` is expanded as a start expands it.
    let at = ["/u/bin/agent", "--cwd", "${cwd}"];
    assert!(!stale(&at, Some(&["/u/bin/agent", "--cwd", "/w"])).await);
    // Nothing to judge: no recorded argv.
    assert!(!stale(&capped, None).await);
}

#[tokio::test]
async fn a_remote_origin_legacy_agent_is_not_judged() {
    let hub = hub(&["/u/bin/claude", "--autocompact", "402530"]);
    let p = hub.config.read().await.harnesses["lane"].clone();
    let mut m = meta(Some(&["/u/bin/claude"]));
    m.remote_origin = true;
    assert_eq!(hub.legacy_stale(&p, &m, &BTreeMap::new()).await, None);
}

/// An adopted chat found current keeps the catalog's digest: the next sweeps compare strings
/// and build no launch (one daemon, 2026-11-28: 1,170 builds in 3 minutes for 48 chats).
#[tokio::test]
async fn a_legacy_agent_found_current_is_built_once_not_every_sweep() {
    let argv = ["/u/bin/claude", "--autocompact", "402530"];
    let hub = hub(&argv);
    let p = hub.config.read().await.harnesses["lane"].clone();
    let now = p.launch_digest();
    let session = hub.insert_test_session(meta(Some(&argv)));
    LEGACY_BUILDS.with(|n| n.set(0));
    for _ in 0..28 {
        let m = session.meta();
        assert!(!hub.launch_changed(&session, &m, &now, &p, &BTreeMap::new()).await);
    }
    // Before: 28 builds, one per sweep.
    assert_eq!(LEGACY_BUILDS.with(|n| n.get()), 1);
    assert_eq!(session.meta().launch_digest.as_deref(), Some(now.as_str()));
    // A later profile change is seen by its digest, with no build.
    assert!(hub.launch_changed(&session, &session.meta(), "other", &p, &BTreeMap::new()).await);
    assert_eq!(LEGACY_BUILDS.with(|n| n.get()), 1);

    // A stale one keeps no digest: it is marked, and the respawn records the new one.
    let stale = hub.insert_test_session({
        let mut m = meta(Some(&["/u/bin/claude"]));
        m.id = "t".into();
        m
    });
    assert!(hub.launch_changed(&stale, &stale.meta(), &now, &p, &BTreeMap::new()).await);
    assert_eq!(stale.meta().launch_digest, None);
}
