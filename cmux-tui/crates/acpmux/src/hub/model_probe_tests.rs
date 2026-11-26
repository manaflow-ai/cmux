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

/// Antigravity (agy 1.5.16) names one model per option value and one `availableModels` id per
/// reasoning level (`gemini-3.8-flash-low` … `-high`). Its rows in `_acpmux/models` carry those
/// levels, so the picker's Reasoning column lists them before a chat runs the model. A model with
/// no level ids (`gpt-oss-120b-medium`) keeps none.
#[tokio::test]
async fn level_variants_in_the_model_list_become_each_models_efforts() {
    let hub = hub(&["agy", "acp"]);
    let options = json!([{
        "id": "model", "category": "model", "type": "select", "currentValue": "gemini-4-neon",
        "options": [
            {"value": "gemini-4-neon", "name": "Gemini 4 Neon"},
            {"value": "gemini-3.8-flash", "name": "Gemini 3.8 Flash"},
            {"value": "gpt-oss-120b-medium", "name": "GPT-OSS 120B (Medium)"},
        ],
    }]);
    let available = listed(&[
        "gemini-4-neon-high",
        "gemini-4-neon-xhigh",
        "gemini-4-neon-medium",
        "gemini-4-neon-low",
        "gemini-3.8-flash-high",
        "gemini-3.8-flash-medium",
        "gemini-3.8-flash-low",
        "gpt-oss-120b-medium",
    ]);
    assert!(hub.remember_models_from("acme", Some(&options), Some(&available)));
    let catalog = hub.models_catalog().await;
    let row = catalog["harnesses"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|h| h["harness"] == "acme")
        .cloned()
        .unwrap();
    let efforts = |id: &str| {
        row["models"].as_array().unwrap().iter().find(|m| m["id"] == id).unwrap()["efforts"].clone()
    };
    assert_eq!(efforts("gemini-4-neon"), json!(["low", "medium", "high", "xhigh"]));
    assert_eq!(efforts("gemini-3.8-flash"), json!(["low", "medium", "high"]));
    assert_eq!(efforts("gpt-oss-120b-medium"), Value::Null);
    // The same report again changes nothing.
    assert!(!hub.remember_models_from("acme", Some(&options), Some(&available)));
    // A resumed chat's answer with no `availableModels` keeps the levels.
    hub.remember_models_from("acme", Some(&options), None);
    assert_eq!(hub.known_efforts.lock().unwrap()["acme"]["gemini-3.8-flash"].len(), 3);
}

/// A model the list names as it is gets no levels from a sibling model whose id ends in a level
/// word: OpenCode lists both `gpt-5.1-codex` and `gpt-5.1-codex-max`, two models.
#[test]
fn a_listed_model_takes_no_levels_from_a_sibling_model() {
    let models = vec![
        ("gpt-5.1-codex".to_owned(), "GPT-5.1 Codex".to_owned()),
        ("gpt-5.1-codex-max".to_owned(), "GPT-5.1 Codex Max".to_owned()),
    ];
    let efforts = crate::model_catalog::variant_efforts(
        &models,
        Some(&listed(&["gpt-5.1-codex", "gpt-5.1-codex-max"])),
    );
    assert!(efforts.is_empty(), "{efforts:?}");
}

/// Image roll 45732114266: cursor-agent probes ran on minutes after their 60 s bound. A probe
/// dropped before it ended its agent (the bound's timeout, a stopping daemon) left the agent
/// running, since the agent's exit watcher holds it and `kill_on_drop` never fired.
#[cfg(unix)]
#[tokio::test]
async fn a_dropped_probe_ends_its_agent() {
    let dir = tempfile::tempdir().unwrap();
    let pid_file = dir.path().join("pid");
    // An ACP agent that never answers `initialize`, as a harness waiting on its sign-in does.
    let script = format!("echo $$ > '{}'; exec sleep 30", pid_file.display());
    let hub = hub(&["sh", "-c", &script]);
    let profile = hub.config.read().await.harnesses["acme"].clone();
    let probe = hub.probe_one("acme", &profile);
    let pid = tokio::time::timeout(std::time::Duration::from_secs(10), async {
        tokio::pin!(probe);
        loop {
            tokio::select! {
                _ = &mut probe => panic!("the probe ended before it was dropped"),
                () = tokio::time::sleep(std::time::Duration::from_millis(20)) => {}
            }
            if let Some(pid) =
                std::fs::read_to_string(&pid_file).ok().and_then(|s| s.trim().parse::<i32>().ok())
            {
                return pid;
            }
        }
    })
    .await
    .expect("the probe's agent never started");
    // The probe was dropped with the timeout above, its agent still waiting.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    // SAFETY: signal 0 only checks that the process exists.
    while unsafe { libc::kill(pid, 0) } == 0 && std::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_ne!(unsafe { libc::kill(pid, 0) }, 0, "the dropped probe's agent still runs");
}
