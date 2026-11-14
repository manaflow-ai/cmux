use super::*;
use std::collections::BTreeMap;

#[test]
fn harness_picker_order_survives_catalog_order_and_aliases() {
    let models = vec![
        json!({"id": "release-b", "aliases": ["b"]}),
        json!({"id": "release-a", "aliases": ["a"]}),
        json!({"id": "older"}),
    ];
    let reported = [("default", "Default"), ("a", "A"), ("b", "B"), ("a", "A")]
        .map(|(id, name)| (id.to_owned(), name.to_owned()));
    assert_eq!(picker_models(&reported, &models), vec!["release-a", "release-b"]);
}

#[test]
fn a_new_harness_model_needs_no_cmux_top_list_update() {
    let models = vec![json!({"id": "new-family"}), json!({"id": "existing"})];
    let reported = [("existing", "Existing"), ("new-family", "New")]
        .map(|(id, name)| (id.to_owned(), name.to_owned()));
    assert_eq!(picker_models(&reported, &models), vec!["existing", "new-family"]);
}

/// A hub with Claude Code and the `cmux` router profile, discovered or user-written.
fn router_hub(discovered: bool) -> std::sync::Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let mut found = BTreeMap::new();
    crate::config::add_cmux_router_with(&mut found, &|_| Some("/usr/bin/claude".into()), None);
    let claude = HarnessProfile {
        env: BTreeMap::new(),
        description: None,
        models: vec![],
        model: None,
        ..found["cmux"].clone()
    };
    let mut cfg = Config::default();
    cfg.harnesses.insert("claude".into(), claude);
    if discovered {
        cfg.join_discovered(found);
    } else {
        cfg.harnesses.insert("cmux".into(), found["cmux"].clone());
    }
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn models_row(reply: &Value, name: &str) -> Value {
    reply["harnesses"].as_array().unwrap().iter().find(|h| h["harness"] == name).cloned().unwrap()
}

/// The discovered `cmux` profile is Claude's automatic fallback to the cmux model router,
/// not an agent a person picks: pickers showed it as a "Cmux" harness above Claude Code
/// (user, 2026-10-28). Both replies keep its row (a chat that failed over to it still needs
/// its name, icon and models) and mark it `pickerHidden`.
#[tokio::test]
async fn the_discovered_cmux_router_fallback_is_hidden_from_pickers() {
    let hub = router_hub(true);
    assert_eq!(
        hub.config.read().await.harnesses["claude"].fallback.as_deref(),
        Some("cmux"),
        "the router stays Claude's fallback"
    );
    let models = hub.models_catalog().await;
    assert_eq!(models_row(&models, "cmux")["pickerHidden"], json!(true));
    assert!(models_row(&models, "cmux")["models"].as_array().is_some_and(|m| !m.is_empty()));
    assert_eq!(models_row(&models, "claude").get("pickerHidden"), None);
    let view = hub.harnesses_view().await;
    assert_eq!(view["harnesses"]["cmux"]["pickerHidden"], json!(true));
    assert_eq!(view["harnesses"]["claude"].get("pickerHidden"), None);
}

/// A `cmux` profile the person wrote in their config is theirs to pick.
#[tokio::test]
async fn a_user_written_cmux_profile_stays_in_pickers() {
    let hub = router_hub(false);
    assert_eq!(models_row(&hub.models_catalog().await, "cmux").get("pickerHidden"), None);
    assert_eq!(hub.harnesses_view().await["harnesses"]["cmux"].get("pickerHidden"), None);
}
