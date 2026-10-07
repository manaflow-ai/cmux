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
    v["curated"] = json!(true);
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

/// Steps 2 and 3 of the module doc for one harness.
fn offered(
    kind: &HarnessKind,
    curated: Option<&CatalogHarness>,
    catalog: &Catalog,
    reported: &[(String, String)],
) -> Vec<Value> {
    let static_claude =
        || crate::claude_stdio::models().iter().map(|(v, n)| json!({"id": v, "name": n})).collect();
    let Some(curated) = curated.filter(|c| c.model_source == "catalog" && !c.models.is_empty())
    else {
        return match kind {
            HarnessKind::ClaudeStdio => static_claude(),
            _ => reported.iter().map(|r| reported_json(r, catalog)).collect(),
        };
    };
    let mut out = Vec::new();
    if *kind == HarnessKind::ClaudeStdio
        && let Some((id, name)) = crate::claude_stdio::models().first()
    {
        out.push(json!({"id": id, "name": name}));
    }
    let reported_has = |id: &str| reported.iter().any(|(r, _)| r == id);
    for model in &curated.models {
        if *kind != HarnessKind::Acp || reported.is_empty() || reported_has(&model.id) {
            out.push(curated_json(model, catalog));
        }
    }
    for entry in reported {
        if !curated.models.iter().any(|m| m.id == entry.0) {
            out.push(reported_json(entry, catalog));
        }
    }
    out
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
            let reported = known.get(name).cloned().unwrap_or_default();
            for entry in offered(&profile.kind, curated.as_ref(), &catalog, &reported) {
                push_or_fill(&mut models, entry);
            }
            if models.is_empty() {
                models.push(json!({"id": "default", "name": "default (agent's choice)"}));
            }
            super::model_availability::mark_unavailable(&mut models, name, &refused);
            let mut entry = json!({"harness": name, "kind": profile.kind, "isDefault": cfg.default_harness.as_deref() == Some(name), "models": models});
            if let Some(reason) = probe_errors.get(name) {
                entry["probeError"] = json!(reason);
            }
            if let Some(curated) = &curated {
                entry["catalog"] = harness_catalog_json(curated);
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
                v["profiles"] = json!(profiles);
                v
            })
            .collect();
        let mut summary = self.catalog.summary();
        summary["harnesses"] = json!(list);
        summary
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::schema::parse;

    fn catalog() -> Catalog {
        let body = br#"{"schemaVersion":1,"generatedAt":"2026-10-07T00:00:00.000Z","source":"live","harnesses":[
            {"id":"codex","name":"Codex","brand":"openai","families":["codex"],"modelSource":"catalog","models":[
              {"id":"gpt-new","ref":"openai/gpt-new","name":"GPT New","shortName":"New","provider":"openai","fast":true},
              {"id":"gpt-old","ref":"openai/gpt-old","name":"GPT Old","shortName":"Old","provider":"openai"}]},
            {"id":"opencode","name":"OpenCode","brand":"opencode","families":["opencode"],"modelSource":"probe","models":[]}],
          "models":{"openai/gpt-new":{"name":"GPT New","contextWindow":400000},"anthropic/claude-x":{"name":"Claude X","contextWindow":200000}},
          "providers":{"openai":{"name":"OpenAI"}}}"#;
        parse(body).unwrap_or_else(|e| panic!("{e}"))
    }

    fn ids(models: &[Value]) -> Vec<&str> {
        models.iter().filter_map(|m| m["id"].as_str()).collect()
    }

    #[test]
    fn an_acp_harness_offers_the_curated_models_it_reported_then_its_own() {
        let c = catalog();
        let reported = vec![
            ("gpt-old".to_owned(), "gpt old".to_owned()),
            ("mine".to_owned(), "Mine".to_owned()),
        ];
        let out = offered(&HarnessKind::Acp, Some(&c.harnesses[0]), &c, &reported);
        assert_eq!(ids(&out), ["gpt-old", "mine"]);
        assert_eq!(out[0]["name"], "GPT Old");
        assert_eq!(out[0]["curated"], true);
        assert_eq!(out[1]["curated"], false);
        // Before the probe answers, the curated list is the whole list, with its metadata.
        let out = offered(&HarnessKind::Acp, Some(&c.harnesses[0]), &c, &[]);
        assert_eq!(ids(&out), ["gpt-new", "gpt-old"]);
        assert_eq!(out[0]["contextWindow"], 400000);
    }

    #[test]
    fn a_probe_entry_shows_every_reported_model_with_catalog_metadata() {
        let c = catalog();
        let reported = vec![
            ("anthropic/claude-x".to_owned(), "claude x".to_owned()),
            ("local/llama".to_owned(), "Llama".to_owned()),
        ];
        let out = offered(&HarnessKind::Acp, Some(&c.harnesses[1]), &c, &reported);
        assert_eq!(ids(&out), ["anthropic/claude-x", "local/llama"]);
        assert_eq!(out[0]["contextWindow"], 200000);
        assert_eq!(out[0]["name"], "claude x");
    }

    #[test]
    fn claude_code_lists_default_then_the_curated_models() {
        let c = catalog();
        let out = offered(&HarnessKind::ClaudeStdio, Some(&c.harnesses[0]), &c, &[]);
        assert_eq!(ids(&out), ["default", "gpt-new", "gpt-old"]);
        assert_eq!(out[1]["fast"], true);
        // No catalog entry: the built-in list.
        assert_eq!(
            offered(&HarnessKind::ClaudeStdio, None, &c, &[]).len(),
            crate::claude_stdio::models().len()
        );
    }

    #[test]
    fn a_declared_model_keeps_its_fields_and_gains_curated_ones() {
        let c = catalog();
        let mut models = vec![json!({"id": "gpt-new", "name": "Mine", "declared": true})];
        for entry in offered(&HarnessKind::Acp, Some(&c.harnesses[0]), &c, &[]) {
            push_or_fill(&mut models, entry);
        }
        assert_eq!(models.len(), 2);
        assert_eq!(models[0]["name"], "Mine");
        assert_eq!(models[0]["fast"], true);
    }
}
