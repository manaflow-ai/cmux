//! Part of `Hub`; see `hub/mod.rs`. The `_acpmux/models` reply: every
//! configured harness with the models a picker offers for it.
//!
//! Per harness, in this order:
//! 1. the models its profile file declares (the user's own list wins);
//! 2. the curated catalog's models (`crate::catalog`), marked `curated`, for a
//!    catalog entry whose `modelSource` is `catalog`. For an ACP harness that
//!    already reported its models, only the curated ones it reported (the
//!    agent decides what it runs; the catalog adds names, order and
//!    metadata). Claude Code reports none, so its list comes from the catalog
//!    after the "default" choice;
//! 3. the models the harness reported that the catalog does not list, marked
//!    `curated: false` (for example an OpenCode user's own providers). A
//!    `probe` entry lists no models: every reported model is shown, with the
//!    catalog's metadata when `models` describes its id.
//!
//! Without a catalog entry the harness keeps today's lists.

use super::*;
use crate::catalog::{Catalog, CatalogHarness, CatalogService, HarnessModel};
use crate::config::HarnessKind;
use cmux_json::JsonSet as _;
use std::sync::PoisonError;

/// The curated catalog entry for a profile (by its name, else its family).
pub(super) fn curated_for(
    catalog: &CatalogService,
    name: &str,
    profile: &HarnessProfile,
) -> Option<CatalogHarness> {
    catalog.harness(name, &crate::config::derive_family(name, profile))
}

/// Every curated model id (and alias) of a profile, for model-id lookups.
pub(super) fn curated_ids(
    catalog: &CatalogService,
    name: &str,
    profile: &HarnessProfile,
) -> Vec<String> {
    curated_for(catalog, name, profile)
        .map(|h| {
            h.models
                .into_iter()
                .flat_map(|m| std::iter::once(m.id).chain(m.aliases.unwrap_or_default()))
                .collect()
        })
        .unwrap_or_default()
}

/// A model's catalog metadata (`models[ref]`) under its harness fields, marked `curated`.
fn curated_json(model: &HarnessModel, catalog: &Catalog) -> Value {
    let mut v =
        serde_json::to_value(model).unwrap_or_else(|_| json!({"id": model.id, "name": model.name}));
    let info = model.reference.as_deref().and_then(|r| catalog.models.get(r));
    if let (Some(out), Some(Ok(Value::Object(extra)))) =
        (v.as_object_mut(), info.map(serde_json::to_value))
    {
        for (k, x) in extra {
            if k != "name" && k != "family" {
                out.entry(k).or_insert(x);
            }
        }
    }
    v.set("curated", json!(true));
    v
}

/// A reported model, with the catalog's metadata when `models` describes its id.
fn reported_json((id, name): &(String, String), catalog: &Catalog) -> Value {
    let mut v = json!({"id": id, "name": name, "curated": false});
    if let (Some(out), Some(Ok(Value::Object(extra)))) =
        (v.as_object_mut(), catalog.models.get(id).map(serde_json::to_value))
    {
        for (k, x) in extra {
            if k != "name" {
                out.entry(k).or_insert(x);
            }
        }
    }
    v
}

/// Adds `entry` unless its id is listed; a listed declared model gets the curated fields it lacks.
fn push_or_fill(models: &mut Vec<Value>, entry: Value) {
    let Some(existing) = models.iter_mut().find(|m| m["id"] == entry["id"]) else {
        models.push(entry);
        return;
    };
    if let (Some(out), Value::Object(extra)) = (existing.as_object_mut(), entry) {
        for (k, x) in extra {
            out.entry(k).or_insert(x);
        }
    }
}

/// Whether `reported` lists `model`, by its id or one of its aliases.
fn lists(reported: &[(String, String)], model: &HarnessModel) -> bool {
    reported.iter().any(|(id, _)| {
        *id == model.id || model.aliases.as_ref().is_some_and(|aliases| aliases.contains(id))
    })
}

/// Steps 2 and 3 of the module doc for one harness. `live`: `reported` is the
/// harness CLI's own list (`hub/live_models.rs`), which stands in for Claude
/// Code's static list and, like an ACP harness's report, picks the curated
/// models it names.
fn offered(
    kind: &HarnessKind,
    curated: Option<&CatalogHarness>,
    catalog: &Catalog,
    reported: &[(String, String)],
    live: bool,
) -> Vec<Value> {
    let claude = *kind == HarnessKind::ClaudeStdio;
    let mut out: Vec<Value> = Vec::new();
    // Claude Code's own "default" choice comes first whatever the list.
    if claude && let Some((id, name)) = crate::claude_stdio::models().first() {
        out.push(json!({"id": id, "name": name}));
    }
    let Some(curated) = curated.filter(|c| c.model_source == "catalog" && !c.models.is_empty())
    else {
        if claude && !live {
            return crate::claude_stdio::models()
                .iter()
                .map(|(v, n)| json!({"id": v, "name": n}))
                .collect();
        }
        out.extend(reported.iter().map(|r| reported_json(r, catalog)));
        return out;
    };
    let picks = (*kind == HarnessKind::Acp || live) && !reported.is_empty();
    for model in &curated.models {
        if !picks || lists(reported, model) {
            out.push(curated_json(model, catalog));
        }
    }
    // Claude Code's adapter reports its static aliases, which the curated list covers.
    if claude && !live {
        return out;
    }
    for entry in reported {
        if !curated.models.iter().any(|m| lists(std::slice::from_ref(entry), m)) {
            out.push(reported_json(entry, catalog));
        }
    }
    out
}

/// Preserve the harness's own picker order independently of the catalog's metadata order.
/// An alias maps to the release row in `models`; repeated ids never add a second menu row.
fn picker_models(reported: &[(String, String)], models: &[Value]) -> Vec<String> {
    let mut top = Vec::new();
    for (id, _) in reported {
        if id == "default" {
            continue;
        }
        let model = models.iter().find(|model| {
            model["id"] == id.as_str()
                || model["aliases"]
                    .as_array()
                    .is_some_and(|aliases| aliases.iter().any(|alias| alias == id.as_str()))
        });
        if let Some(id) = model.and_then(|model| model["id"].as_str())
            && !top.iter().any(|known| known == id)
        {
            top.push(id.to_owned());
        }
    }
    top
}

/// Whether pickers leave out the profile `name` (`pickerHidden` on its `_acpmux/models` and
/// `_acpmux/harnesses` rows): the discovered `cmux` profile, Claude Code on the cmux model
/// router, is Claude's automatic fallback, not an agent to pick. It showed as a "Cmux" harness
/// above Claude Code (user, 2026-10-28). The row stays, so a chat that failed over to it keeps
/// its name, icon and models. A `cmux` profile the person wrote in their config is pickable.
pub(super) fn picker_hidden(cfg: &crate::config::Config, name: &str) -> bool {
    name == crate::config::CMUX_ROUTER_PROFILE && cfg.discovered.contains(name)
}

/// The harness-level catalog fields a picker shows.
fn harness_catalog_json(curated: &CatalogHarness) -> Value {
    let mut v = json!({"id": curated.id, "name": curated.name, "brand": curated.brand, "families": curated.families, "modelSource": curated.model_source});
    for (key, value) in [("docsUrl", &curated.docs_url), ("defaultModel", &curated.default_model)] {
        if let Some(value) = value {
            v[key] = json!(value);
        }
    }
    v
}

impl Hub {
    /// Every configured harness with the models known for it, and the catalog in use.
    pub async fn models_catalog(&self) -> Value {
        let cfg = self.config.read().await;
        let known = self.known_models.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let refused = self.refused_models.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let probe_errors = self.probe_errors.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let catalog = self.catalog.current();
        let mut out = Vec::new();
        for (name, profile) in &cfg.harnesses {
            // A terminal harness has no models and no ACP session.
            if profile.kind == HarnessKind::Terminal {
                continue;
            }
            let mut models: Vec<Value> = profile
                .models
                .iter()
                .map(|m| declared_model_json(m, cfg.profile_meta.get(name)))
                .collect();
            let curated = curated_for(&self.catalog, name, profile);
            let live = self.live_models_for(name).filter(|l| !l.is_empty());
            let reported = match &live {
                Some(live) => live.iter().map(|m| (m.id.clone(), m.name.clone())).collect(),
                None => known.get(name).cloned().unwrap_or_default(),
            };
            for entry in
                offered(&profile.kind, curated.as_ref(), &catalog, &reported, live.is_some())
            {
                push_or_fill(&mut models, entry);
            }
            if let Some(live) = &live {
                crate::live_models::overlay(&mut models, live);
            }
            if models.is_empty() {
                models.push(json!({"id": "default", "name": "default (agent's choice)"}));
            }
            super::model_availability::mark_unavailable(&mut models, name, &refused);
            let top =
                if live.is_some() || (profile.kind == HarnessKind::Acp && !reported.is_empty()) {
                    Some(picker_models(&reported, &models))
                } else {
                    None
                };
            let mut entry = json!({"harness": name, "kind": profile.kind, "isDefault": cfg.default_harness.as_deref() == Some(name), "models": models});
            if let Some(top) = top {
                entry.set("topModels", json!(top));
            }
            if let Some(reason) = probe_errors.get(name) {
                entry.set("probeError", json!(reason));
            }
            if picker_hidden(&cfg, name) {
                entry.set("pickerHidden", json!(true));
            }
            if let Some(curated) = &curated {
                entry.set("catalog", harness_catalog_json(curated));
            }
            out.push(entry);
        }
        json!({"harnesses": out, "catalog": self.catalog.summary()})
    }

    /// The catalog's harness list for `_acpmux/harnesses`, each marked with the configured profiles that use it.
    pub(super) fn catalog_harnesses(&self, cfg: &crate::config::Config) -> Value {
        let catalog = self.catalog.current();
        let list: Vec<Value> = catalog
            .harnesses
            .iter()
            .map(|h| {
                let profiles: Vec<&String> = cfg
                    .harnesses
                    .iter()
                    .filter(|(name, p)| {
                        curated_for(&self.catalog, name, p).is_some_and(|c| c.id == h.id)
                    })
                    .map(|(name, _)| name)
                    .collect();
                let mut v = harness_catalog_json(h);
                v.set("profiles", json!(profiles));
                v
            })
            .collect();
        let mut summary = self.catalog.summary();
        summary.set("harnesses", json!(list));
        summary
    }
}

#[cfg(test)]
mod picker_models_tests {
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
        reply["harnesses"]
            .as_array()
            .unwrap()
            .iter()
            .find(|h| h["harness"] == name)
            .cloned()
            .unwrap()
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
}
