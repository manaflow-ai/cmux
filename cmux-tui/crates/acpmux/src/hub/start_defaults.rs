//! Part of `Hub`; see `hub/mod.rs`. The model and effort a new chat starts
//! on when its request names none (cx-qtmy2, cx-fusxy; Lawrence 2026-10-13):
//!
//! 1. the saved default in config.json `defaults` (family, then profile):
//!    what `acpmux defaults <family> model=… effort=…` sets, and what the
//!    person's pick in a chat writes (`note_pick`: the app pane's
//!    `session/set_model` or effort `session/set_config_option`), so a pick
//!    carries to the next new chat and across restarts;
//! 2. the harness CLI's own config (`harness_config`, cx-uq9xi; Leo
//!    2026-10-14): Codex's config.toml `model` and `model_reasoning_effort`,
//!    Claude Code's settings.json `model` (a `[1m]` variant suffix dropped),
//!    when the catalog lists that model (an alias names its id); the effort
//!    when it fits the running model and the config names no model or one the
//!    catalog lists. Codex runs the model its config.toml names even when the
//!    catalog does not list it (a provider's own model, or one newer than the
//!    snapshot), with the config's effort, as raw `codex` does (user
//!    2026-10-20). The file is read only when the saved default leaves a
//!    value open;
//! 3. the curated catalog's `defaultModel` for the harness and that model's
//!    `defaultEffort` (Claude Code: Opus 5.5, Codex: GPT-6.1 Sol, both
//!    medium). acpmux sets the start value on every new chat, so what a cmux
//!    chat runs never depends on a harness default it cannot show.
//!
//! An explicit value in the request, a preset, a folder profile, a
//! profile's own `model`/`effort` (or a model in its argv or env) and an
//! adopted conversation keep today's chain (`new_session`). A start value
//! the harness refuses (a retired model, an effort the model lacks) is
//! skipped with a warning and a `start_default_skipped` event: the chat then
//! runs the harness's own default and is never refused for it.

use super::*;

use crate::catalog::CatalogHarness;

/// Longest model id or effort a pick saves (the pane's own limits).
const MAX_VALUE: usize = 256;

/// The option ids that carry thinking effort (`model_options::resolve_config_id`).
const EFFORT_IDS: [&str; 5] =
    ["effort", "reasoning_effort", "thinking", "reasoning", "thought_level"];

/// Whether `id` (a harness's own option id) carries thinking effort.
pub(super) fn is_effort_id(id: &str) -> bool {
    EFFORT_IDS.contains(&id)
}

/// The effort a `session/set_config_option` sets, if it sets one: an effort
/// option's value, or Claude Code's Ultracode switch (on runs `ultracode`,
/// off leaves xhigh).
pub(super) fn effort_of<'a>(config_id: &str, value: &'a Value) -> Option<&'a str> {
    if config_id == crate::claude_stdio::ULTRACODE_OPTION {
        return Some(if value == "on" { "ultracode" } else { "xhigh" });
    }
    if is_effort_id(config_id) { value.as_str() } else { None }
}

/// Records that `session` runs `model` now. A model change can reset the
/// harness's effort (Codex does), so the recorded effort is dropped.
pub(super) fn model_applied(session: &Session, model: &str) {
    let mut applied = session.applied.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    applied.model = Some(model.to_owned());
    applied.effort = None;
}

/// Env keys that choose a harness's main model (not a background or
/// subagent model such as `ANTHROPIC_SMALL_FAST_MODEL`).
const MAIN_MODEL_ENV: [&str; 5] =
    ["ANTHROPIC_MODEL", "OPENAI_MODEL", "CODEX_MODEL", "GEMINI_MODEL", "MODEL"];

/// Interpreters whose `-m` names a module, not a model.
const INTERPRETERS: [&str; 7] = ["python", "node", "ruby", "perl", "bun", "deno", "uv"];

/// Whether a profile chooses its main model itself: `--model`, `--model=…`,
/// `-m` (not after an interpreter), `-c`/`--config model=…` in its argv, or a
/// main-model key in its env or its defaults' env. Then no start model is
/// set over it.
pub(super) fn profile_sets_model(
    profile: &HarnessProfile,
    defaults_env: &std::collections::BTreeMap<String, String>,
) -> bool {
    let argv = &profile.argv;
    let program = argv.first().map(|a| {
        std::path::Path::new(a)
            .file_name()
            .map(|f| f.to_string_lossy().to_lowercase())
            .unwrap_or_default()
    });
    let interpreter =
        program.as_deref().is_some_and(|p| INTERPRETERS.iter().any(|i| p.starts_with(i)));
    let in_argv = argv.iter().enumerate().any(|(i, a)| {
        a == "--model"
            || a.starts_with("--model=")
            || (a == "-m" && !interpreter)
            || ((a == "-c" || a == "--config")
                && argv.get(i + 1).is_some_and(|v| v.trim_start().starts_with("model=")))
    });
    let in_env = |env: &std::collections::BTreeMap<String, String>| {
        env.keys().any(|k| MAIN_MODEL_ENV.contains(&k.to_ascii_uppercase().as_str()))
    };
    in_argv || in_env(&profile.env) || in_env(defaults_env)
}

/// Where a start value came from (`_acpmux/harnesses` `start.*Source`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StartSource {
    /// config.json `defaults` (an `acpmux defaults` write or a pick).
    Saved,
    /// The profile's own `model`/`effort`.
    Profile,
    /// The harness CLI's own config (`harness_config`).
    Harness,
    /// The curated catalog's default.
    Catalog,
}

impl StartSource {
    fn as_str(self) -> &'static str {
        match self {
            StartSource::Saved => "saved",
            StartSource::Profile => "profile",
            StartSource::Harness => "harness",
            StartSource::Catalog => "catalog",
        }
    }
}

/// A start value and where it came from. Every start value is soft: a
/// refusal skips it (module docs).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct StartValue {
    pub value: String,
    pub source: StartSource,
}

fn usable(value: &str) -> bool {
    !value.is_empty() && value.len() <= MAX_VALUE && value != "default"
}

/// Whether the curated catalog lists `effort` for `model` (true when the
/// catalog does not describe the model's efforts: the harness decides).
fn effort_fits(curated: Option<&CatalogHarness>, model: Option<&str>, effort: &str) -> bool {
    let Some(entry) = curated.and_then(|c| c.models.iter().find(|m| Some(m.id.as_str()) == model))
    else {
        return true;
    };
    // Claude Code's Ultracode runs at xhigh.
    let level = if effort == "ultracode" { "xhigh" } else { effort };
    entry.efforts.as_ref().is_none_or(|list| list.iter().any(|e| e == level))
}

impl Hub {
    /// `session/set_model`. The model the chat already runs (acpmux's start
    /// value, or the same pick again) is not sent again: a Codex model set
    /// resets its effort. Any other model is sent; from the app pane
    /// (`pick`), once the harness takes it, it is the person's saved pick.
    pub async fn client_set_model(
        self: &Arc<Self>,
        session: &Arc<Session>,
        model: &str,
        pick: bool,
    ) -> Result<Value, RpcError> {
        let runs = super::model_options::current_model(&session.meta()).or_else(|| {
            session.applied.lock().unwrap_or_else(std::sync::PoisonError::into_inner).model.clone()
        });
        if runs.as_deref() == Some(model) {
            return Ok(json!({}));
        }
        let r = self.set_model(session, model).await?;
        if pick {
            self.note_pick(session, Some(model), None).await;
        }
        Ok(r)
    }

    /// `session/set_config_option`. From the app pane (`pick`), an effort the
    /// chat did not already run is the person's saved pick once the harness
    /// takes it.
    pub async fn client_set_config(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
        pick: bool,
    ) -> Result<Value, RpcError> {
        let before = session
            .applied
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .effort
            .clone();
        let r = self.set_config(session, config_id, value.clone()).await?;
        let resolved = super::model_options::resolve_config_id(&session.meta(), config_id);
        let effort = effort_of(&resolved, &value);
        if pick && effort.is_some() && before.as_deref() != effort {
            self.note_pick(session, None, effort).await;
        }
        Ok(r)
    }

    /// Saves a pick on `session` as the saved default of its harness profile
    /// (config.json `defaults`, the entry `acpmux defaults` writes). Not for
    /// a preset's chat (an orchestration's settings are not the person's
    /// choice) or a folder profile's (its file decides). A value of
    /// "default" (the harness's own), or one the profile pins itself, saves
    /// nothing.
    async fn note_pick(&self, session: &Session, model: Option<&str>, effort: Option<&str>) {
        let meta = session.meta();
        if meta.preset.is_some() || meta.harness.is_empty() {
            return;
        }
        let mut cfg = self.config.write().await;
        if !cfg.harnesses.contains_key(&meta.harness) {
            return;
        }
        let defaults_env = cfg.defaults_for(&meta.harness).env;
        let Some(profile) = cfg.harnesses.get(&meta.harness) else { return };
        let model_pinned = profile.model.is_some() || profile_sets_model(profile, &defaults_env);
        let effort_pinned = profile.effort.is_some();
        let model = model.filter(|m| usable(m) && !model_pinned);
        let effort = effort.filter(|e| usable(e) && !effort_pinned);
        if model.is_none() && effort.is_none() {
            return;
        }
        let entry = cfg.defaults.entry(meta.harness.clone()).or_default();
        let before = (entry.model.clone(), entry.effort.clone());
        if let Some(m) = model {
            entry.model = Some(m.to_owned());
        }
        if let Some(e) = effort {
            entry.effort = Some(e.to_owned());
        }
        if (entry.model.clone(), entry.effort.clone()) == before {
            return;
        }
        if let Err(e) = cfg.save() {
            tracing::warn!(harness = %meta.harness, "pick not saved to config.json: {e}");
        }
        // The pick is now the harness's `start` in `_acpmux/harnesses`: pages already open (a
        // prewarmed New Tab) read it again instead of drawing the old start model and effort.
        let names: Vec<&String> = cfg.harnesses.keys().collect();
        self.send_harness_change(
            json!({"harnesses": names, "diagnostics": cfg.profile_diagnostics}),
        );
    }

    /// The model and effort a new chat on `agent` starts on when nothing
    /// pins them (module docs). `model`: the model the chat runs when the
    /// request or a pin names it, which only the effort then follows.
    pub(super) fn start_defaults(
        &self,
        agent: &str,
        profile: &HarnessProfile,
        saved: &crate::config::SessionDefaults,
        model: Option<&str>,
    ) -> (Option<StartValue>, Option<StartValue>) {
        let curated = super::models_view::curated_for(&self.catalog, agent, profile);
        // The harness's own config, read (blocking file IO) only when the request and the saved
        // pick leave a value open.
        let read = std::cell::OnceCell::new();
        let own = || {
            read.get_or_init(|| {
                crate::harness_config::read(
                    &crate::config::derive_family(agent, profile),
                    &[&profile.env, &saved.env],
                )
            })
        };
        // The config's model as the catalog names it; one the catalog does not list (a retired
        // model, a typo) gives way to the catalog default.
        let own_model = || {
            own().model.as_deref().and_then(|m| {
                curated
                    .as_ref()?
                    .models
                    .iter()
                    .find(|x| x.id == m || x.aliases.iter().flatten().any(|a| a == m))
            })
        };
        // The catalog default only when the harness offers it: an account that
        // lacks it (Codex refusing GPT-6.1 Sol at the first prompt) starts on the
        // harness's own default, its config's model, instead (cnx-ios full verify D4).
        let reported = self.reported_model_ids(agent);
        // Codex: a config model the catalog does not list still runs (module docs).
        let codex = crate::config::derive_family(agent, profile) == "codex";
        let own_unlisted =
            || own().model.clone().filter(|m| codex && !m.is_empty() && own_model().is_none());
        let start_model = match model {
            Some(_) => None,
            None => saved
                .model
                .clone()
                .map(|value| StartValue { value, source: StartSource::Saved })
                .or_else(|| {
                    own_model()
                        .map(|m| StartValue { value: m.id.clone(), source: StartSource::Harness })
                })
                .or_else(|| {
                    own_unlisted().map(|value| StartValue { value, source: StartSource::Harness })
                })
                .or_else(|| {
                    curated
                        .as_ref()
                        .and_then(|c| c.default_model.clone())
                        .filter(|m| {
                            let ids: Vec<String> = c_ids(curated.as_ref());
                            offers(&reported, &ids, m)
                        })
                        .map(|value| StartValue { value, source: StartSource::Catalog })
                }),
        };
        let runs = model.or(start_model.as_ref().map(|m| m.value.as_str()));
        // A saved effort the running model lacks (a pick made on another
        // model) gives way to that model's own default; a model the catalog
        // does not describe (a router's own model) takes no saved effort.
        let described =
            |m: &str| curated.as_ref().is_none_or(|c| c.models.iter().any(|x| x.id == m));
        let fits =
            |e: &String| runs.is_none_or(described) && effort_fits(curated.as_ref(), runs, e);
        let start_effort = saved
            .effort
            .clone()
            .filter(fits)
            .map(|value| StartValue { value, source: StartSource::Saved })
            .or_else(|| {
                // Codex applies its effort to whatever model runs, so an effort with no model
                // in the config is taken; one paired with a model the catalog refused was
                // chosen for that model, not the catalog default, and is not.
                let paired = own().model.is_none() || own_model().is_some();
                // The config's own unlisted model runs with the config's effort as it is.
                let own_runs = own_unlisted().is_some_and(|m| runs == Some(m.as_str()));
                own()
                    .effort
                    .clone()
                    .filter(|e| own_runs || (paired && fits(e)))
                    .map(|value| StartValue { value, source: StartSource::Harness })
            })
            .or_else(|| {
                curated
                    .as_ref()
                    .and_then(|c| c.models.iter().find(|m| Some(m.id.as_str()) == runs))
                    .and_then(|m| m.default_effort.clone())
                    .map(|value| StartValue { value, source: StartSource::Catalog })
            });
        (start_model, start_effort)
    }

    /// The model ids `agent` itself reported (its last session or probe);
    /// empty when it reported none (Claude Code, a harness not probed yet).
    pub(super) fn reported_model_ids(&self, agent: &str) -> Vec<String> {
        self.known_models
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(agent)
            .map(|list| list.iter().map(|(id, _)| id.clone()).collect())
            .unwrap_or_default()
    }

    /// Whether the catalog start model `model` is one `agent`'s harness offers ([`offers`]).
    pub(super) fn harness_offers(
        &self,
        agent: &str,
        profile: &HarnessProfile,
        model: &str,
    ) -> bool {
        let curated = super::models_view::curated_for(&self.catalog, agent, profile);
        offers(&self.reported_model_ids(agent), &c_ids(curated.as_ref()), model)
    }

    /// `start` for one `_acpmux/harnesses` row: `{model?, effort?,
    /// modelSource?, effortSource?}`, what a new chat there starts on.
    pub(super) fn start_view(
        &self,
        cfg: &crate::config::Config,
        agent: &str,
        profile: &HarnessProfile,
    ) -> Option<Value> {
        let saved = cfg.defaults_for(agent);
        if profile_sets_model(profile, &saved.env) {
            return None;
        }
        let pinned = profile.model.clone();
        let (model, effort) = self.start_defaults(agent, profile, &saved, pinned.as_deref());
        let model = match pinned {
            Some(value) => Some(StartValue { value, source: StartSource::Profile }),
            None => model,
        };
        let effort = match &profile.effort {
            Some(value) => Some(StartValue { value: value.clone(), source: StartSource::Profile }),
            None => effort,
        };
        if model.is_none() && effort.is_none() {
            return None;
        }
        let mut v = json!({});
        if let Some(m) = model {
            v["model"] = json!(m.value);
            v["modelSource"] = json!(m.source.as_str());
        }
        if let Some(e) = effort {
            v["effort"] = json!(e.value);
            v["effortSource"] = json!(e.source.as_str());
        }
        Some(v)
    }
}

/// The curated model ids of a catalog entry.
fn c_ids(curated: Option<&CatalogHarness>) -> Vec<String> {
    curated.map(|c| c.models.iter().map(|m| m.id.clone()).collect()).unwrap_or_default()
}

/// Whether reported id `id` names `model`: the same id, or a DSH route
/// (`["provider","model"]`) for `model` or `provider/model`, as
/// `model_catalog::resolve` accepts them.
fn names(id: &str, model: &str) -> bool {
    id == model
        || serde_json::from_str::<Vec<String>>(id)
            .is_ok_and(|p| p.len() == 2 && (p[1] == model || format!("{}/{}", p[0], p[1]) == model))
}

/// Whether a harness that reported `reported` offers the catalog's `model`.
/// Any model when it reported none, or when its ids are not the catalog's
/// (Claude Code's aliases `default`/`opus`/`sonnet`): then the harness decides,
/// as before. Otherwise only a model it lists, so an account that lacks the
/// catalog default (Codex without GPT-6.1 Sol) starts on its own default.
pub(super) fn offers(reported: &[String], curated: &[String], model: &str) -> bool {
    if reported.is_empty() || !reported.iter().any(|r| curated.iter().any(|c| names(r, c))) {
        return true;
    }
    reported.iter().any(|r| names(r, model))
}
