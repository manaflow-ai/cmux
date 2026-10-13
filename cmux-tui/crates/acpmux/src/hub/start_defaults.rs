//! Part of `Hub`; see `hub/mod.rs`. The model and effort a new chat starts
//! on when its request names none (cx-qtmy2, cx-fusxy; Lawrence 2026-10-13):
//!
//! 1. the saved default in config.json `defaults` (family, then profile):
//!    what `acpmux defaults <family> model=… effort=…` sets, and what the
//!    person's last pick in a chat writes (`note_pick`: a local client's
//!    `session/set_model` or effort `session/set_config_option`), so a pick
//!    carries to the next new chat and across restarts;
//! 2. the curated catalog's `defaultModel` for the harness and that model's
//!    `defaultEffort` (Claude Code: Opus 5.5, Codex: GPT-6.1 Sol, both
//!    medium). acpmux sets it on every new chat, so the harness CLI's own
//!    default (`~/.claude/settings.json`, `~/.codex/config.toml`) never
//!    decides what a cmux chat runs.
//!
//! An explicit value in the request, a preset, a folder profile and a
//! profile's own `model`/`effort` always win (`new_session`). A saved
//! default the harness refuses fails creation loudly (today's rule); a
//! catalog default it refuses is skipped with a warning, and the chat then
//! runs the harness's own default.

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

/// Where a start value came from (`_acpmux/harnesses` `start.*Source`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StartSource {
    /// config.json `defaults` (an `acpmux defaults` write or a pick).
    Saved,
    /// The curated catalog's default.
    Catalog,
}

impl StartSource {
    fn as_str(self) -> &'static str {
        match self {
            StartSource::Saved => "saved",
            StartSource::Catalog => "catalog",
        }
    }
}

/// A start value and where it came from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct StartValue {
    pub value: String,
    pub source: StartSource,
}

impl StartValue {
    /// A catalog default: skipped when the harness refuses it.
    pub fn soft(&self) -> bool {
        self.source == StartSource::Catalog
    }
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
    entry.efforts.as_ref().is_none_or(|list| list.iter().any(|e| e == effort))
}

impl Hub {
    /// A local client's `session/set_model`. The model the session already
    /// runs (acpmux's start value, or the same pick again) is no new pick and
    /// is not sent again: a Codex model set resets its effort. Any other
    /// model is sent, and once the harness takes it, saved as the person's
    /// pick (`note_pick`).
    pub async fn client_set_model(
        self: &Arc<Self>,
        session: &Arc<Session>,
        model: &str,
        local: bool,
    ) -> Result<Value, RpcError> {
        let runs =
            session.applied.lock().unwrap_or_else(std::sync::PoisonError::into_inner).model.clone();
        if runs.as_deref() == Some(model) {
            return Ok(json!({}));
        }
        let r = self.set_model(session, model).await?;
        if local {
            self.note_pick(session, Some(model), None).await;
        }
        Ok(r)
    }

    /// A local client's `session/set_config_option`: an effort the session
    /// does not already run is saved as the person's pick once the harness
    /// takes it.
    pub async fn client_set_config(
        self: &Arc<Self>,
        session: &Arc<Session>,
        config_id: &str,
        value: Value,
        local: bool,
    ) -> Result<Value, RpcError> {
        let before = session
            .applied
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .effort
            .clone();
        let r = self.set_config(session, config_id, value.clone()).await?;
        let resolved = super::model_options::resolve_config_id(&session.meta(), config_id);
        if local && is_effort_id(&resolved) && before.as_deref() != value.as_str() {
            self.note_pick(session, None, value.as_str()).await;
        }
        Ok(r)
    }

    /// Saves a pick on `session` as the saved default of its harness profile
    /// (config.json `defaults`, the entry `acpmux defaults` writes). Not for
    /// a preset's chat: an orchestration's settings are not the person's
    /// choice. A value of "default" (the harness's own), or one the profile
    /// pins itself, saves nothing.
    async fn note_pick(&self, session: &Session, model: Option<&str>, effort: Option<&str>) {
        let meta = session.meta();
        if meta.preset.is_some() || meta.harness.is_empty() {
            return;
        }
        let mut cfg = self.config.write().await;
        let pins =
            cfg.harnesses.get(&meta.harness).map(|p| (p.model.is_some(), p.effort.is_some()));
        let (model_pinned, effort_pinned) = pins.unwrap_or((false, false));
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
        let start_model = match model {
            Some(_) => None,
            None => saved
                .model
                .clone()
                .map(|value| StartValue { value, source: StartSource::Saved })
                .or_else(|| {
                    curated
                        .as_ref()
                        .and_then(|c| c.default_model.clone())
                        .map(|value| StartValue { value, source: StartSource::Catalog })
                }),
        };
        let runs = model.or(start_model.as_ref().map(|m| m.value.as_str()));
        let start_effort = saved
            .effort
            .clone()
            .map(|value| StartValue { value, source: StartSource::Saved })
            .or_else(|| {
                curated
                    .as_ref()
                    .and_then(|c| c.models.iter().find(|m| Some(m.id.as_str()) == runs))
                    .and_then(|m| m.default_effort.clone())
                    .filter(|e| effort_fits(curated.as_ref(), runs, e))
                    .map(|value| StartValue { value, source: StartSource::Catalog })
            });
        (start_model, start_effort)
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
        let pinned = profile.model.clone();
        let (model, effort) = self.start_defaults(agent, profile, &saved, pinned.as_deref());
        let model = match pinned {
            Some(value) => Some(StartValue { value, source: StartSource::Saved }),
            None => model,
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
