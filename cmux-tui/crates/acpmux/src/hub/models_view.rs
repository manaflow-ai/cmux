//! Part of `Hub`; see `hub/mod.rs`. The `_acpmux/models` reply: every
//! configured harness with the models a picker offers for it.
//!
//! Per harness, in this order:
//! 1. the models its profile file declares (the user's own list wins);
//! 2. the curated catalog's models (`crate::catalog`), marked `curated`, for a
//!    catalog entry whose `modelSource` is `catalog`. For an ACP harness that
//!    already reported its models, only the curated ones it reported (the
//!    agent decides what it runs; the catalog adds names, order and
//!    metadata), plus the curated releases newer than the newest it reported of
//!    the same family (an older Codex still offers the new Sol), unless the
//!    entry `runsAnyModel` (Gemini CLI: its ACP menu is fixed per release,
//!    `--model` takes any Gemini API id), which gets every curated model, the
//!    ones newer than its whole menu leading `topModels`.
//!    Claude Code reports none, so its list comes from the catalog after the
//!    "default" choice;
//! 3. the models the harness reported that the catalog does not list, marked
//!    `curated: false` (for example an OpenCode user's own providers). A
//!    `probe` entry lists no models: every reported model is shown, with the
//!    catalog's metadata when `models` describes its id.
//!
//! Without a catalog entry the harness keeps today's lists.

use super::*;
use crate::catalog::{Catalog, CatalogHarness, CatalogService, HarnessModel};
use crate::config::HarnessKind;
use crate::live_models::LiveModel;
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

/// The reasoning levels the agent's model list names (`known_efforts`) on each row that declares
/// none: a profile's or the catalog's own `efforts` win.
fn add_variant_efforts(
    models: &mut [Value],
    levels: &std::collections::HashMap<String, Vec<String>>,
) {
    for model in models {
        let Some(found) = model["id"].as_str().and_then(|id| levels.get(id)) else { continue };
        if model.get("efforts").is_none() {
            model.set("efforts", json!(found));
        }
    }
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
    // A harness that runs any model id gets every catalog model, not only the ones it names.
    let picks = (*kind == HarnessKind::Acp || live)
        && !reported.is_empty()
        && curated.runs_any_model != Some(true);
    // A newer release of a family it already runs shows even when this CLI predates it.
    let newer = if picks { newer_than_menu(curated, catalog, reported) } else { Vec::new() };
    for model in &curated.models {
        if !picks || lists(reported, model) || newer.contains(&model.id) {
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

/// Drops the models the catalog disabled from a harness's list: one never shows, even when the
/// harness reports it itself or the user's config names it.
fn drop_disabled(models: &mut Vec<Value>, disabled: &[String]) {
    models.retain(|m| m["id"].as_str().is_none_or(|id| !disabled.iter().any(|d| d == id)));
}

/// The catalog models a harness's menu predates, in catalog order: they lead its picker menu,
/// so a model shows the day the catalog or the feed lists it, without a CLI update (Leo,
/// 2026-11-20: "enable seeing new models even when ppl dont upgradetheir stuff").
///
/// - A harness that runs any model id (`runsAnyModel`: Gemini CLI, whose ACP menu is fixed in
///   each release): every catalog model released after every model its menu names.
/// - Any other harness (Codex, whose `model/list` is what this account runs): a catalog model
///   released after the newest one its menu names of the same family (`models[ref].family`,
///   gpt-sol) and release line ([`release_line`]): an older Codex that lists GPT-6.1 Sol gets
///   GPT-6.2 Sol, and a family the account runs none of (an API-only release) or a later-dated
///   variant of a listed release (GPT-6.1 Sol Healthcare) stays out. Codex takes any id
///   (`session/set_model`).
///
/// Empty when no menu model has a known release date (and family, for the second).
fn newer_than_menu(
    curated: &CatalogHarness,
    catalog: &Catalog,
    reported: &[(String, String)],
) -> Vec<String> {
    let info =
        |model: &HarnessModel| model.reference.as_deref().and_then(|r| catalog.models.get(r));
    let released = |model: &HarnessModel| info(model).and_then(|i| i.release_date.clone());
    let family = |model: &HarnessModel| info(model).and_then(|i| i.family.clone());
    let listed = || curated.models.iter().filter(|m| lists(reported, m));
    if curated.runs_any_model == Some(true) {
        let Some(newest) = listed().filter_map(released).max() else { return Vec::new() };
        return curated
            .models
            .iter()
            .filter(|m| !lists(reported, m) && released(m).is_some_and(|date| date > newest))
            .map(|m| m.id.clone())
            .collect();
    }
    let mut newest = std::collections::BTreeMap::<(String, String), String>::new();
    for model in listed() {
        if let (Some(family), Some(date)) = (family(model), released(model)) {
            let slot = newest.entry((family, release_line(&model.id))).or_default();
            if date > *slot {
                *slot = date;
            }
        }
    }
    curated
        .models
        .iter()
        .filter(|m| m.status.as_deref() != Some("deprecated") && !lists(reported, m))
        .filter(|m| {
            let (Some(family), Some(date)) = (family(m), released(m)) else { return false };
            newest.get(&(family, release_line(&m.id))).is_some_and(|newest| date > *newest)
        })
        .map(|m| m.id.clone())
        .collect()
}

/// A model id without its version: "gpt-6.1-sol" and "gpt-6.2-sol" are both "gpt-sol". A newer
/// release continues a line the menu lists, so a variant the feed files under the same family and
/// dates later is not one: "gpt-6.1-sol-healthcare" (models.dev, 2026-11-24, family gpt-sol) is
/// line "gpt-sol-healthcare", and an older Codex that lists GPT-6.1 Sol does not get it leading
/// its menu as the newest Sol.
fn release_line(id: &str) -> String {
    let id = id.rsplit('/').next().unwrap_or(id);
    let parts: Vec<&str> = id
        .split('-')
        .filter(|part| !part.chars().all(|c| c.is_ascii_digit() || c == '.'))
        .collect();
    parts.join("-")
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

/// The harness's current models: its report without the ones its live catalog moves to
/// another model (Codex's `upgrade`: gpt-5.6-terra and gpt-5.5 name gpt-6-sol). Pickers list
/// those under Legacy (`topModels` leaves them out), so current and legacy follow the CLI's
/// own catalog rather than its order (#38044).
fn current(reported: &[(String, String)], live: Option<&[LiveModel]>) -> Vec<(String, String)> {
    let upgraded =
        |id: &str| live.is_some_and(|live| live.iter().any(|m| m.id == id && m.upgrade.is_some()));
    reported.iter().filter(|(id, _)| !upgraded(id)).cloned().collect()
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
        let efforts = self.known_efforts.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let refused = self.refused_models.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let probe_errors = self.probe_errors.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let catalog = self.catalog.current();
        let health = self.health.rows();
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
            let reported: Vec<(String, String)> = match &live {
                Some(live) => live.iter().map(|m| (m.id.clone(), m.name.clone())).collect(),
                None => self.model_lists.acp(name).unwrap_or_default(),
            };
            for entry in
                offered(&profile.kind, curated.as_ref(), &catalog, &reported, live.is_some())
            {
                push_or_fill(&mut models, entry);
            }
            if let Some(live) = &live {
                crate::live_models::overlay(&mut models, live);
            }
            // A live model (including an explicit profile declaration) always wins over
            // a release note. A newer bundle alone cannot prove account access.
            let mut added = Vec::new();
            if live.is_some()
                && !probe_errors.contains_key(name)
                && profile.models.is_empty()
                && crate::codex_app_server::is_profile_launch(&profile.argv)
                && let Some(row) = health.iter().find(|r| r.id == *name && r.outdated)
                && let (Some(new), Some(version)) = (&row.new_codex_models, &row.latest)
            {
                for (id, display) in new {
                    if !models.iter().any(|m| {
                        m["id"].as_str() == Some(id)
                            || m["aliases"]
                                .as_array()
                                .is_some_and(|a| a.iter().any(|v| v.as_str() == Some(id)))
                    }) {
                        models.push(json!({"id": id, "name": display, "curated": false, "codexUpdateVersion": version,
                            "unavailable": format!("Included in Codex {version}. Update Codex to check availability for this account.")}));
                        added.push(id.clone());
                    }
                }
            }
            if let Some(levels) = efforts.get(name) {
                add_variant_efforts(&mut models, levels);
            }
            let disabled: &[String] = curated.as_ref().map_or(&[], |c| &c.disabled);
            drop_disabled(&mut models, disabled);
            if models.is_empty() {
                models.push(json!({"id": "default", "name": "default (agent's choice)"}));
            }
            super::model_availability::mark_unavailable(&mut models, name, &refused);
            let top =
                if live.is_some() || (profile.kind == HarnessKind::Acp && !reported.is_empty()) {
                    let menu = picker_models(&current(&reported, live.as_deref()), &models);
                    let mut top: Vec<String> = curated
                        .as_ref()
                        .map(|c| newer_than_menu(c, &catalog, &reported))
                        .unwrap_or_default();
                    top.retain(|id| !menu.contains(id));
                    top.extend(added);
                    top.extend(menu);
                    top.retain(|id| !disabled.contains(id));
                    Some(top)
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
#[path = "models_view_picker_models_tests.rs"]
mod picker_models_tests;
