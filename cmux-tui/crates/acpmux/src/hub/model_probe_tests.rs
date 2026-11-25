use super::*;
use crate::config::StoreMode;

fn hub(argv: &[&str]) -> Arc<Hub> {
    let mut cfg: Config =
        serde_json::from_value(json!({"harnesses": {"acme": {"argv": argv}}})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn listed(ids: &[&str]) -> Value {
    json!({"availableModels": ids.iter().map(|id| json!({"modelId": id, "name": id.to_uppercase()})).collect::<Vec<_>>()})
}

async fn model_ids(hub: &Hub) -> Vec<String> {
    let catalog = hub.models_catalog().await;
    let row = catalog["harnesses"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|h| h["harness"] == "acme")
        .cloned()
        .unwrap_or_default();
    row["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| m["id"].as_str().map(str::to_owned))
        .collect()
}

async fn probed(hub: &Hub, dir: &std::path::Path, ids: &[&str]) -> bool {
    let profile = hub.config.read().await.harnesses["acme"].clone();
    let changed = hub.remember_models_from("acme", None, Some(&listed(ids)));
    hub.keep_probed_models_in(dir.to_path_buf(), "acme", &profile, changed).await;
    changed
}

/// Leo (2026-11-08): "why is there no models … we know what the models are." An ACP
/// agent's list came only from a live probe, so a restarted daemon showed "default" until
/// it answered. The last probed list is now served from disk at once.
#[tokio::test]
async fn a_restarted_daemon_serves_the_last_probed_acp_list_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let first = hub(&["acme-acp"]);
    assert!(probed(&first, dir.path(), &["m-one", "m-two"]).await);

    let next = hub(&["acme-acp"]);
    assert_eq!(model_ids(&next).await, vec!["default".to_owned()]);
    next.load_acp_cache_from(dir.path().to_path_buf()).await;
    assert_eq!(model_ids(&next).await, vec!["m-one".to_owned(), "m-two".to_owned()]);
    // Served from disk, so the probe still runs for it, and its answer replaces the copy.
    assert!(next.acp_from_disk.lock().unwrap().contains("acme"));
    assert!(probed(&next, dir.path(), &["m-three"]).await);
    assert!(!next.acp_from_disk.lock().unwrap().contains("acme"));
    assert_eq!(model_ids(&next).await, vec!["m-three".to_owned()]);

    let third = hub(&["acme-acp"]);
    third.load_acp_cache_from(dir.path().to_path_buf()).await;
    assert_eq!(model_ids(&third).await, vec!["m-three".to_owned()]);
}

/// A list probed under another profile (another argv here) is never served.
#[tokio::test]
async fn a_changed_profile_gets_no_cached_list() {
    let dir = tempfile::tempdir().unwrap();
    assert!(probed(&hub(&["acme-acp"]), dir.path(), &["m-one"]).await);
    let other = hub(&["acme-acp", "--other"]);
    other.load_acp_cache_from(dir.path().to_path_buf()).await;
    assert_eq!(model_ids(&other).await, vec!["default".to_owned()]);
    assert!(other.acp_from_disk.lock().unwrap().is_empty());
}

/// A probe that changed the served list tells the watchers (`_acpmux/harnesses_changed`);
/// one that confirms it (the disk copy, or the same probe again) tells nobody.
#[tokio::test]
async fn only_a_probe_that_changed_the_list_announces_it() {
    let dir = tempfile::tempdir().unwrap();
    let first = hub(&["acme-acp"]);
    let mut changes = first.subscribe_harness_changes();
    assert!(probed(&first, dir.path(), &["m-one"]).await);
    let note = changes.try_recv().unwrap();
    assert_eq!(note["harnesses"], json!(["acme"]), "{note}");
    assert!(!probed(&first, dir.path(), &["m-one"]).await);
    assert!(changes.try_recv().is_err());

    let next = hub(&["acme-acp"]);
    let mut changes = next.subscribe_harness_changes();
    next.load_acp_cache_from(dir.path().to_path_buf()).await;
    assert!(!probed(&next, dir.path(), &["m-one"]).await);
    assert!(changes.try_recv().is_err());
    assert!(probed(&next, dir.path(), &["m-two"]).await);
    assert!(changes.try_recv().is_ok());
}

/// The first `_acpmux/models` of a starting daemon waits for the disk lists: answered
/// before them, it named only "default", and the cached list arriving after it announced
/// nothing, so a pane with no list of its own stayed empty (#39080 review).
#[tokio::test]
async fn a_models_read_during_startup_waits_for_the_disk_lists() {
    let dir = tempfile::tempdir().unwrap();
    assert!(probed(&hub(&["acme-acp"]), dir.path(), &["m-one"]).await);
    let next = hub(&["acme-acp"]);
    next.begin_startup(false);
    let reader = next.clone();
    let read = tokio::spawn(async move {
        reader.wait_model_caches().await;
        model_ids(&reader).await
    });
    tokio::task::yield_now().await;
    assert!(!read.is_finished());
    next.load_model_caches_from(dir.path().to_path_buf()).await;
    assert_eq!(read.await.unwrap(), vec!["m-one".to_owned()]);
}
