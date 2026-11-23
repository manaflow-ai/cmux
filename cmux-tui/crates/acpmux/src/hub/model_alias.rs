//! Part of `Hub`; see `hub/mod.rs`. Every model a session is asked to run, from any entry point
//! (`acpmux new -m`, `exec -m`, `session set model=`, ACP `session/new` and `session/set_model`,
//! the MCP sub-session start, a preset's or the defaults' model), is read through the catalog's
//! alias fold (`model_catalog::canonical_model`) before the harness sees it, and a rewrite says so
//! in one line: `model fable-5.2 -> claude-fable-5-2`.
//!
//! Leo, 2026-11-22: "ok but you guys need to be able to hot patch these and reroute and
//! auto-reroute to proper names. there's not much confusion possible here, so this is totally a
//! candidate for that kind of thing. you guys need to be catching these yourselves". A Claude
//! Code session asked for `fable-5.2` died on its first turn (`unrecognized_model`); 16 lanes sat
//! dead on it.
//!
//! Only a name that folds to more than one id is refused. A name the catalog does not know passes
//! through unchanged. A session whose turn fails on its model anyway (a model saved before this
//! rule, a harness the catalog lacks a row for) is retried once under its canonical id
//! (`auto_resume/model_reroute.rs`).

use super::*;
use crate::model_catalog::{self, Canonical};

/// The mux record a rewrite leaves in the session's log, drawn as a notice row:
/// `{from, to, at, text}`.
pub(super) const REWRITE_RECORD: &str = "model_rewrite";
/// The mux record an auto-reroute leaves (`auto_resume/model_reroute.rs`): `{from, to, turnId,
/// text}`.
pub(super) const REROUTE_RECORD: &str = "model_reroute";

impl Hub {
    /// `model` for the harness profile `agent` (`profile`), as its catalog names it: the
    /// canonical id, or `model` unchanged when the catalog does not know it or its harness is
    /// not one whose names fold. Ambiguous: refused, naming the choices.
    pub(super) fn canonical_model_for(
        &self,
        agent: &str,
        profile: &HarnessProfile,
        model: &str,
    ) -> Result<Canonical, RpcError> {
        let Some(entry) = super::models_view::curated_for(&self.catalog, agent, profile) else {
            return Ok(Canonical {
                model: model.trim().to_owned(),
                given: model.trim().to_owned(),
                known: false,
            });
        };
        model_catalog::canonical_model(&entry, model).map_err(|e| {
            RpcError::invalid_params(e.to_string()).with_data(json!({
                "reason": "model.ambiguous",
                "model": e.given,
                "choices": e.choices,
            }))
        })
    }

    /// [`Hub::canonical_model_for`], logging a rewrite (`where` names the entry point) and, for a
    /// `session` that exists, recording it in its log. Returns the model to run.
    pub(super) fn rewrite_model(
        &self,
        session: Option<&Session>,
        agent: &str,
        profile: &HarnessProfile,
        model: &str,
        at: &str,
    ) -> Result<String, RpcError> {
        let canonical = self.canonical_model_for(agent, profile, model)?;
        if canonical.changed() {
            match session {
                Some(s) => self.record_model_rewrite(s, &canonical, at),
                None => tracing::info!(harness = agent, "{at}: {}", canonical.line()),
            }
        }
        Ok(canonical.model)
    }

    /// A rewrite, in the daemon's log and as a notice row in `session`'s transcript.
    pub(super) fn record_model_rewrite(&self, session: &Session, canonical: &Canonical, at: &str) {
        let line = canonical.line();
        tracing::info!(session = %session.id, "{at}: {line}");
        self.append(
            session,
            "mux",
            REWRITE_RECORD,
            json!({"from": canonical.given, "to": canonical.model, "at": at, "text": line}),
        );
    }

    /// The model `session` is asked to run, as its catalog names it ([`Hub::rewrite_model`] for
    /// the session's own harness profile).
    pub(super) async fn rewrite_session_model(
        &self,
        session: &Session,
        model: &str,
        at: &str,
    ) -> Result<String, RpcError> {
        let harness = session.meta().harness.clone();
        let profile = self.config.read().await.profile(&harness).cloned();
        match profile {
            Some(profile) => self.rewrite_model(Some(session), &harness, &profile, model, at),
            None => Ok(model.to_owned()),
        }
    }
}

/// Whether `session`'s `model` config option lists `model` as one of its values: the harness's
/// own id, never rewritten.
pub(super) fn option_lists(session: &Session, model: &str) -> bool {
    let meta = session.meta();
    meta.config_options
        .as_deref()
        .and_then(Value::as_array)
        .and_then(|opts| opts.iter().find(|o| o.get("id").and_then(Value::as_str) == Some("model")))
        .is_some_and(|o| model_catalog::choices(o).iter().any(|(id, _)| id == model))
}
