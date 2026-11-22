//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/composer`: what a new-chat composer holds, built
//! from the functions `session/new` itself starts a chat with, and moved only by the state
//! machine in `composer_selection.rs` (Leo 2026-11-22: "design out the bad states.
//! fundamentally.").
//!
//! Each harness's [`Offer`] is read from one place per value:
//! - models and their efforts: the curated catalog entry, else the ids the harness reported;
//! - the start model and effort: `start_view` (`start_defaults.rs`), which is `new_session`'s
//!   own rule; a profile that sets its model itself starts on that model;
//! - the modes: the ones its chats report (`reported_options`), and the start mode
//!   `start_mode_answer` names; for a remote device the modes `web_modes::remote_start` lets it
//!   start in, the first being the one it starts in;
//! - accounts: none. An account is a route of a running chat (`server/accounts.rs`); a new chat
//!   runs under its harness's own login, which the harness pick names.

use super::*;

use crate::composer_selection::{ModelOffer, Offer, Pick, Selection, World};

/// A non-empty string field of a params object.
fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
}

/// `selection` as a client sent it back: `harness` is required.
fn selection_of(v: &Value) -> Result<Selection, RpcError> {
    let harness = text(v, "harness")
        .ok_or_else(|| RpcError::invalid_params("selection.harness is required"))?;
    Ok(Selection {
        harness,
        account: text(v, "account"),
        model: text(v, "model"),
        effort: text(v, "effort"),
        mode: text(v, "mode"),
    })
}

/// `pick`: exactly one of `harness`, `account`, `model`, `effort`, `mode`.
fn pick_of(v: &Value) -> Result<Pick, RpcError> {
    let mut picks: Vec<Pick> = Vec::new();
    if let Some(id) = text(v, "harness") {
        picks.push(Pick::Harness(id));
    }
    if let Some(id) = text(v, "account") {
        picks.push(Pick::Account(id));
    }
    if let Some(id) = text(v, "model") {
        picks.push(Pick::Model(id));
    }
    if let Some(id) = text(v, "effort") {
        picks.push(Pick::Effort(id));
    }
    if let Some(id) = text(v, "mode") {
        picks.push(Pick::Mode(id));
    }
    let one = picks.pop();
    match one {
        Some(pick) if picks.is_empty() => Ok(pick),
        _ => Err(RpcError::invalid_params(
            "pick names exactly one of harness, account, model, effort, mode",
        )),
    }
}

fn selection_json(s: &Selection) -> Value {
    json!({
        "harness": s.harness,
        "account": s.account,
        "model": s.model,
        "effort": s.effort,
        "mode": s.mode,
    })
}

fn offer_json(o: &Offer) -> Value {
    let models: Vec<Value> = o
        .models
        .iter()
        .map(|m| json!({"id": m.id, "efforts": m.efforts, "defaultEffort": m.default_effort}))
        .collect();
    json!({
        "models": models,
        "startModel": o.start_model,
        "startEffort": o.start_effort,
        "modes": o.modes,
        "startMode": o.start_mode,
        "accounts": o.accounts,
        "startAccount": o.start_account,
    })
}

impl Hub {
    /// `_acpmux/composer {harness?, cwd?, selection?, pick?}`: `{selection, offer, flaw}`.
    /// Without `selection`, the composer's first one on `harness` (the harness a new chat uses
    /// when none): everything a new chat there starts on. With it, the same selection settled
    /// against what is offered now (after a reload, on this machine for one made on another,
    /// for the chat a fork or a resume continues). With `pick`, the selection after that pick.
    /// `offer` is what the selection's harness offers; `flaw` is null unless a start value
    /// here would run unnamed (`World::flaw`). `remote`: the caller is a remote device, whose
    /// chats start in the modes `web_modes::remote_start` allows. Read only.
    pub async fn composer_answer(&self, params: &Value, remote: bool) -> Result<Value, RpcError> {
        let cwd = match text(params, "cwd").map(PathBuf::from) {
            Some(cwd) if !cwd.is_absolute() => {
                return Err(RpcError::invalid_params("cwd must be an absolute path"));
            }
            other => other,
        };
        let held =
            params.get("selection").filter(|v| v.is_object()).map(selection_of).transpose()?;
        let pick = params.get("pick").filter(|v| v.is_object()).map(pick_of).transpose()?;
        // As `_acpmux/harnesses`: the catalog lacks the person's harnesses until startup read
        // the login shell's PATH.
        let _ = self.catalog_ready.subscribe().wait_for(|ready| *ready).await;
        // Before the config lock: the table reads it with `try_read`.
        let web_modes = self.web_modes();
        let cfg = self.config.read().await.clone();
        // The harness `session/new` uses when none is named.
        let default = self
            .resolve_new(&cfg, None, &None, None, remote, cwd.as_deref())
            .ok()
            .map(|r| r.agent)
            .filter(|name| cfg.harnesses.contains_key(name));
        // Only the harnesses this answer can land on: the held or asked one, the picked one,
        // and the default a harness that is gone falls back to.
        let asked = held.as_ref().map(|s| s.harness.clone()).or_else(|| text(params, "harness"));
        let picked = match &pick {
            Some(Pick::Harness(id)) => Some(id.clone()),
            _ => None,
        };
        let mut world = World { harnesses: Default::default(), default_harness: default.clone() };
        for name in [asked.clone(), picked, default].into_iter().flatten() {
            if world.harnesses.contains_key(&name) {
                continue;
            }
            let Some(profile) = cfg.harnesses.get(&name) else { continue };
            let remote_modes = remote.then(|| {
                crate::web_modes::remote_start(&web_modes, &name, profile).unwrap_or_default()
            });
            let offer =
                self.composer_offer(&cfg, &name, profile, cwd.clone(), remote_modes).await?;
            world.harnesses.insert(name, offer);
        }
        let selection = match (&held, &pick) {
            (Some(held), Some(pick)) => world.apply(held, pick),
            (Some(held), None) => world.settle(held),
            (None, Some(pick)) => {
                world.initial(asked.as_deref()).and_then(|first| world.apply(&first, pick))
            }
            (None, None) => world.initial(asked.as_deref()),
        };
        let offer = selection.as_ref().and_then(|s| world.harnesses.get(&s.harness));
        Ok(json!({
            "selection": selection.as_ref().map(selection_json),
            "offer": offer.map(offer_json),
            "flaw": world.flaw(),
        }))
    }

    /// The model `name`'s newest chat that was asked for none reported: the one the harness
    /// starts on by itself, for a harness with no live list.
    fn model_started_unasked(&self, name: &str) -> Option<String> {
        let all: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        newest_first(all).iter().find_map(|s| {
            let meta = s.meta.lock().unwrap_or_else(|e| e.into_inner());
            (meta.harness == name && meta.model_request.is_none())
                .then(|| current_model(&meta))
                .flatten()
        })
    }

    /// What `name` offers a new chat in `cwd` (module docs). `remote_modes`: for a remote
    /// device, the modes it may start a chat in.
    async fn composer_offer(
        &self,
        cfg: &crate::config::Config,
        name: &str,
        profile: &HarnessProfile,
        cwd: Option<PathBuf>,
        remote_modes: Option<Vec<String>>,
    ) -> Result<Offer, RpcError> {
        let curated = super::models_view::curated_for(&self.catalog, name, profile);
        let mut models: Vec<ModelOffer> = match &curated {
            Some(entry) if !entry.models.is_empty() => entry
                .models
                .iter()
                .map(|m| ModelOffer {
                    id: m.id.clone(),
                    efforts: m.efforts.clone().unwrap_or_default(),
                    default_effort: m.default_effort.clone(),
                })
                .collect(),
            _ => self
                .reported_model_ids(name)
                .into_iter()
                .map(|id| ModelOffer { id, efforts: Vec::new(), default_effort: None })
                .collect(),
        };
        let start = self.start_view(cfg, name, profile);
        let field = |key: &str| start.as_ref().and_then(|s| text(s, key));
        let start_effort = field("effort");
        // The model the harness itself starts on (its live list marks it), which runs when
        // acpmux names none: an account that lacks the catalog default.
        let own_default =
            || self.live_models_for(name).into_iter().flatten().find(|m| m.is_default);
        // The model the chat runs: the one acpmux sets, else the one the profile sets itself,
        // by the id its catalog entry lists it under.
        let saved = cfg.defaults_for(name);
        let start_model = field("model")
            .or_else(|| super::start_defaults::profile_model(profile, &saved.env))
            .or_else(|| own_default().map(|m| m.id))
            .or_else(|| self.model_started_unasked(name))
            .map(|model| {
                super::start_defaults::catalog_model(curated.as_ref(), &model)
                    .map_or(model, |listed| listed.id.clone())
            });
        // No effort set: the chat runs at the start model's own default.
        let start_effort = start_effort.or_else(|| {
            let id = start_model.as_deref()?;
            own_default()
                .filter(|m| m.id == id)
                .and_then(|m| m.default_effort)
                .or_else(|| models.iter().find(|m| m.id == id)?.default_effort.clone())
        });
        // A start model the list lacks (a profile's own, a saved one the catalog dropped) still
        // runs: it is listed, with the effort it starts on.
        if let Some(id) = &start_model
            && !models.iter().any(|m| m.id == *id)
        {
            models.push(ModelOffer {
                id: id.clone(),
                efforts: start_effort.iter().cloned().collect(),
                default_effort: start_effort.clone(),
            });
        }
        let (modes, start_mode) = match remote_modes {
            Some(modes) => {
                let first = modes.first().cloned();
                (modes, first)
            }
            None => {
                let reported = self.reported_options(name, profile);
                let modes: Vec<String> = reported
                    .as_ref()
                    .and_then(|r| r.get("modes"))
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|m| text(m, "id"))
                    .collect();
                let answer =
                    self.start_mode_answer(Some(name.to_owned()), None, cwd, false).await?;
                (modes, text(&answer, "modeId"))
            }
        };
        Ok(Offer {
            models,
            start_model,
            start_effort,
            modes,
            start_mode,
            accounts: Vec::new(),
            start_account: None,
        })
    }
}
