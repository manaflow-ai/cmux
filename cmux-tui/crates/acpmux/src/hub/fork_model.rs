//! Part of `Hub`; see `hub/mod.rs`. The model a fork names (`session/fork` with
//! `_meta.acpmux.model`, `fork.rs` `Retarget::model`), on the chat's own harness or another:
//! the fork runs that model from its first prompt, or the fork call is refused. A model change
//! on the chat's own harness was dropped (the fork ran the chat's model), and a model its
//! harness does not list (`claude/haiku`, the `-m HARNESS/MODEL` spelling `acpmux new` takes)
//! was accepted and failed the first prompt (Leo 2026-11-22: "are their permissions/model
//! locked right then and there? does it make sense to be able to reveal the fork or whatever
//! switching model behaviour for it?").

use super::*;

/// A model change on a fork of the chat's own harness ([`Hub::own_fork_model`]).
pub(super) struct OwnModel {
    /// As the harness lists it.
    pub model: String,
    /// The harness takes its model at spawn (`${model}`): it is the fork's `model_request`.
    pub spawn: bool,
}

/// `requested` as one of `listed` names it, or None when `listed` has models and none of
/// them is it. Tried as written, then without a leading `HEAD/` of `heads` (`claude/haiku`
/// is `haiku` on Claude Code), then as `HEAD/MODEL` of the first head (`big-pickle` is
/// OpenCode's `opencode/big-pickle`), as `session/new` reads `-m`. A harness that lists
/// nothing decides itself; Claude Code also runs any Claude model id it does not list.
pub(super) fn listed_model(
    requested: &str,
    heads: &[&str],
    listed: &[String],
    claude: bool,
) -> Option<String> {
    let bare: Vec<&str> = heads
        .iter()
        .filter_map(|h| requested.strip_prefix(h)?.strip_prefix('/'))
        .filter(|m| !m.is_empty())
        .collect();
    let spellings = std::iter::once(requested.to_owned())
        .chain(bare.iter().map(|m| (*m).to_owned()))
        .chain(heads.first().map(|h| format!("{h}/{requested}")));
    let named = |m: &String| listed.iter().any(|id| super::start_defaults::names(id, m));
    if let Some(m) = spellings.into_iter().find(named) {
        return Some(m);
    }
    if claude
        && let Some(m) = std::iter::once(requested)
            .chain(bare.iter().copied())
            .find(|m| super::model_hint::looks_like_claude_model_id(m))
    {
        return Some(m.to_owned());
    }
    listed.is_empty().then(|| requested.to_owned())
}

/// `model` as the model `meta` records (its `model` option, its `models.currentModelId`), so a
/// start that replays the meta's settings (`lifecycle.rs` `replay_config`) asks for it.
pub(super) fn record_model(meta: &mut SessionMeta, model: &str) {
    if let Some(options) = meta.config_options.as_mut().and_then(|o| o.as_array_mut()) {
        for option in options.iter_mut() {
            if option.get("id").and_then(Value::as_str) == Some("model")
                && let Some(option) = option.as_object_mut()
            {
                option.insert("currentValue".into(), Value::String(model.to_owned()));
            }
        }
    }
    if let Some(models) = meta.models.as_mut().and_then(Value::as_object_mut) {
        models.insert("currentModelId".into(), Value::String(model.to_owned()));
    }
}

/// Why a fork's model is refused: its harness lists it in no spelling.
pub(super) fn not_listed(model: &str, agent: &str, listed: &[String]) -> RpcError {
    let mut shown: Vec<&str> = listed.iter().map(String::as_str).take(20).collect();
    shown.dedup();
    RpcError::invalid_params(format!(
        "model {model:?} is not one harness {agent} lists; models: {}",
        shown.join(", ")
    ))
}

impl Hub {
    /// The model ids `agent` lists: those `meta` (a chat of it) reports, its profile's, what
    /// it reported before (`known_models`), and the curated catalog's (`catalog_ids`).
    pub(super) fn listed_models(
        &self,
        cfg: &crate::config::Config,
        agent: &str,
        meta: Option<&SessionMeta>,
    ) -> Vec<String> {
        let mut ids: Vec<String> = Vec::new();
        if let Some(meta) = meta {
            if let Some(option) = meta
                .config_options
                .as_deref()
                .and_then(Value::as_array)
                .and_then(|opts| opts.iter().find(|o| o["id"] == "model"))
            {
                ids.extend(crate::model_catalog::choices(option).into_iter().map(|(id, _)| id));
            }
            if let Some(models) = meta
                .models
                .as_ref()
                .and_then(|m| m.get("availableModels"))
                .and_then(Value::as_array)
            {
                ids.extend(
                    models.iter().filter_map(|m| m.get("modelId")?.as_str().map(str::to_owned)),
                );
            }
        }
        if let Some(p) = cfg.harnesses.get(agent) {
            ids.extend(p.models.iter().map(|m| m.id().to_owned()));
            if p.kind == crate::config::HarnessKind::ClaudeStdio {
                ids.extend(crate::claude_stdio::models().iter().map(|(id, _)| id.clone()));
            }
            ids.extend(super::models_view::curated_ids(&self.catalog, agent, p));
        }
        ids.extend(self.reported_model_ids(agent));
        ids.sort();
        ids.dedup();
        ids
    }

    /// The model a fork of `parent` on its own harness (of `kind`) runs: `requested` as the chat's
    /// harness lists it, or refused before any fork is made.
    pub(super) fn own_fork_model(
        &self,
        cfg: &crate::config::Config,
        parent: &SessionMeta,
        kind: crate::config::HarnessKind,
        heads: &[&str],
        requested: &str,
        spawn: bool,
    ) -> Result<OwnModel, RpcError> {
        let agent = parent.harness.as_str();
        let listed = self.listed_models(cfg, agent, Some(parent));
        let claude = kind == crate::config::HarnessKind::ClaudeStdio;
        let model = listed_model(requested, heads, &listed, claude)
            .ok_or_else(|| not_listed(requested, agent, &listed))?;
        Ok(OwnModel { model, spawn })
    }

    /// `requested` as `fork`'s harness (`agent`), now up, lists it; None when `explicit` is
    /// false and the harness lists it in no spelling (a profile's own model: the harness
    /// decides), refused when the fork named it.
    pub(super) async fn started_fork_model(
        &self,
        fork: &Session,
        agent: &str,
        kind: crate::config::HarnessKind,
        heads: &[&str],
        requested: &str,
        explicit: bool,
    ) -> Result<String, RpcError> {
        let requested = self.rewrite_session_model(fork, requested, "session/fork").await?;
        let requested = requested.as_str();
        let listed = {
            let cfg = self.config.read().await;
            self.listed_models(&cfg, agent, Some(&fork.meta()))
        };
        let claude = kind == crate::config::HarnessKind::ClaudeStdio;
        match listed_model(requested, heads, &listed, claude) {
            Some(m) => Ok(m),
            None if explicit => Err(not_listed(requested, agent, &listed)),
            None => Ok(requested.to_owned()),
        }
    }

    /// A fork on its own harness with a model change ([`OwnModel`], not at spawn): its agent up
    /// and on that model before the reply, through `set_model` as a person's pick, so the fork's
    /// meta and its agent agree; or the error, and the caller closes the fork.
    pub(super) async fn start_on_model(
        self: &Arc<Self>,
        fork: &Arc<Session>,
        model: &str,
    ) -> Result<(), RpcError> {
        self.child_for(fork).await?;
        Box::pin(self.set_model(fork, model)).await.map_err(|e| {
            RpcError::invalid_params(format!(
                "model {model:?} for {}: {}",
                fork.meta().harness,
                e.message
            ))
        })?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "fork_model_tests.rs"]
mod tests;
