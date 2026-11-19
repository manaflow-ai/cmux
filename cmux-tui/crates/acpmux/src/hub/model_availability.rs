//! Models a harness's backend refuses outright. A turn that fails with the upstream error code
//! `unsupported_parameter` (for example a Codex model that sends image web search to a backend
//! that refuses it), or with a model the sign-in cannot use (the ChatGPT Codex backend's 400
//! `model_not_found`, "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT
//! account", `turn_errors::is_model_unavailable`), marks that model unavailable for that harness,
//! with the backend's message, and `_acpmux/models` reports it, so the picker never offers a
//! model that always fails. A live list can say so before any turn (`live_models::account_models`).
//!
//! A model the sign-in cannot use also moves the chat: the turn's `turn_result` names the model
//! the chat runs from its next prompt (`modelFallback`, [`Hub::usable_model`]), and a new chat
//! never starts on a refused model (`start_defaults.rs`), whether a saved pick, the harness
//! config's `model` or the catalog default named it.

use std::collections::HashMap;
use std::sync::PoisonError;

use serde_json::{Value, json};

use super::{Hub, Session, current_model};

/// The backend's message when `error` is a refusal of the model itself, else None.
pub(crate) fn refusal_reason(error: &str) -> Option<String> {
    if !error.contains("unsupported_parameter") && !crate::turn_errors::is_model_unavailable(error)
    {
        return None;
    }
    // The upstream error is JSON inside the turn error text: take its message when it has one.
    let message = error.find('{').and_then(|start| {
        let value: Value =
            serde_json::from_str(error[start..].trim_end_matches(|c| c != '}')).ok()?;
        value.pointer("/error/message").and_then(Value::as_str).map(str::to_owned)
    });
    Some(message.unwrap_or_else(|| error.chars().take(200).collect()))
}

/// The model a refusal names ("The 'gpt-6.1-sol' model is not supported ..."), for a session
/// whose metadata names none.
fn named_model(error: &str) -> Option<String> {
    let (_, rest) = error.split_once("The '")?;
    let (model, after) = rest.split_once('\'')?;
    (after.trim_start().starts_with("model") && !model.is_empty() && model.len() <= 256)
        .then(|| model.to_owned())
}

/// Adds `unavailable: <reason>` to each of `models` that `harness`'s backend refused.
pub(crate) fn mark_unavailable(
    models: &mut [Value],
    harness: &str,
    refused: &HashMap<(String, String), String>,
) {
    for model in models {
        let Some(id) = model.get("id").and_then(Value::as_str) else { continue };
        if let Some(reason) = refused.get(&(harness.to_owned(), id.to_owned())) {
            model["unavailable"] = Value::String(reason.clone());
        }
    }
}

/// The model a chat moves to: its id and the name pickers show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Fallback {
    pub id: String,
    pub name: String,
}

impl Fallback {
    /// `turn_result`'s `modelFallback`.
    pub(crate) fn to_json(&self, from: &str) -> Value {
        json!({"from": from, "model": self.id, "name": self.name})
    }
}

/// A turn's refusal of its model ([`Hub::note_model_refusal`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Refusal {
    /// The refused model.
    pub model: String,
    /// Not refused before: pickers are told to read `_acpmux/models` again.
    pub new: bool,
    /// The model the chat moves to: only for a model its sign-in cannot use, and only when a
    /// usable one is known ([`Hub::usable_model`]).
    pub fallback: Option<Fallback>,
}

impl Hub {
    /// A turn that ended normally but whose reply is the backend's error object (Codex streams a
    /// refused request as the agent's message) counts as that refusal too.
    pub(super) fn note_reply_refusal(&self, session: &Session) -> Option<Refusal> {
        let reply = session.stream.lock().unwrap().trailing_text.clone();
        let is_error_object = serde_json::from_str::<Value>(reply.trim())
            .is_ok_and(|value| value.get("type").and_then(Value::as_str) == Some("error"));
        if is_error_object { self.note_model_refusal(session, &reply) } else { None }
    }

    /// Remembers the session's current model as refused when `error` is such a refusal.
    pub(super) fn note_model_refusal(&self, session: &Session, error: &str) -> Option<Refusal> {
        let reason = refusal_reason(error)?;
        let meta = session.meta();
        let model = current_model(&meta)
            .or_else(|| {
                session.applied.lock().unwrap_or_else(PoisonError::into_inner).model.clone()
            })
            .or_else(|| named_model(error))?;
        let new = self
            .refused_models
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert((meta.harness.clone(), model.clone()), reason)
            .is_none();
        let fallback = crate::turn_errors::is_model_unavailable(error)
            .then(|| self.usable_model(&meta.harness, &model))
            .flatten();
        Some(Refusal { model, new, fallback })
    }

    /// After a turn refused its model: pickers are told when the refusal is new (an open New Tab
    /// would otherwise start its next chat on the refused model), and the chat moves to the
    /// refusal's fallback, if it has one. The model it runs now, once the harness took it.
    pub(super) async fn move_off_refused(
        self: &std::sync::Arc<Self>,
        session: &std::sync::Arc<Session>,
        refusal: &Refusal,
    ) -> Option<Fallback> {
        if refusal.new {
            self.announce_harnesses().await;
        }
        let to = refusal.fallback.clone()?;
        // Its own task, started from a plain function: `set_model` can reach a turn's end again
        // (a respawn recovers its work), so the turn's end must not hold its future.
        match self.spawn_model_switch(session, to.id.clone()).await {
            Ok(Ok(_)) => {
                tracing::info!(session = %session.id, from = %refusal.model, to = %to.id, "the sign-in cannot use the chat's model; switched");
                Some(to)
            }
            Ok(Err(e)) => {
                tracing::warn!(session = %session.id, from = %refusal.model, "the chat's model could not be switched: {}", e.message);
                None
            }
            Err(e) => {
                tracing::warn!(session = %session.id, from = %refusal.model, "the chat's model switch ended: {e}");
                None
            }
        }
    }

    /// Switches `session` to `model` in a task of its own, the hub's (a shutdown that closes the
    /// hub's scope ends it, and the switch reads as not taken): its id once the harness took it.
    fn spawn_model_switch(
        self: &std::sync::Arc<Self>,
        session: &std::sync::Arc<Session>,
        model: String,
    ) -> tokio::task::JoinHandle<Result<String, crate::rpc::RpcError>> {
        let (hub, chat) = (self.clone(), session.clone());
        self.scope.spawn_named(
            "model-switch",
            Box::pin(async move { hub.set_model(&chat, &model).await.map(|_| model) }),
        )
    }

    /// Why `harness`'s backend refuses `model` for its sign-in: a turn it refused, or its live
    /// list's mark (`live_models::account_models`). None when nothing says so.
    pub(super) fn model_refused(&self, harness: &str, model: &str) -> Option<String> {
        let refused = self
            .refused_models
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&(harness.to_owned(), model.to_owned()))
            .cloned();
        refused.or_else(|| {
            self.live_models_for(harness)?.into_iter().find(|m| m.id == model)?.unavailable
        })
    }

    /// The model a chat on `harness` moves to from `except`, one its backend refuses: from its
    /// live list (`hub/live_models.rs`), the CLI's default, else its first current model (no
    /// `upgrade`), else any; without a live list, the first model its sessions reported. Never
    /// one refused or marked unavailable. None when no such model is known.
    pub(super) fn usable_model(&self, harness: &str, except: &str) -> Option<Fallback> {
        let refused = self.refused_models.lock().unwrap_or_else(PoisonError::into_inner).clone();
        let free = |id: &str| {
            id != except
                && id != "default"
                && !id.is_empty()
                && !refused.contains_key(&(harness.to_owned(), id.to_owned()))
        };
        if let Some(live) = self.live_models_for(harness).filter(|l| !l.is_empty()) {
            let usable: Vec<_> =
                live.iter().filter(|m| m.unavailable.is_none() && free(&m.id)).collect();
            return usable
                .iter()
                .find(|m| m.is_default)
                .or_else(|| usable.iter().find(|m| m.upgrade.is_none()))
                .or_else(|| usable.first())
                .map(|m| Fallback { id: m.id.clone(), name: m.name.clone() });
        }
        let known = self.known_models.lock().unwrap_or_else(PoisonError::into_inner);
        known
            .get(harness)?
            .iter()
            .find(|(id, _)| free(id))
            .map(|(id, name)| Fallback { id: id.clone(), name: name.clone() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, HarnessKind, HarnessProfile, StoreMode};
    use std::collections::BTreeMap;

    const REFUSED: &str = r#"unexpected status 400 Bad Request: {"type":"error","status":400,"error":{"type":"invalid_request_error","code":"model_not_found","message":"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."}}"#;

    /// A hub with a Codex profile whose config.toml (in `codex_home`) names gpt-6.1-sol, as a
    /// person's `~/.codex/config.toml` does.
    fn codex_hub(codex_home: &std::path::Path) -> std::sync::Arc<Hub> {
        std::fs::create_dir_all(codex_home).unwrap();
        std::fs::write(
            codex_home.join("config.toml"),
            "model = \"gpt-6.1-sol\"\nmodel_catalog_json = \"/x/model_catalog.json\"\n",
        )
        .unwrap();
        let profile = HarnessProfile {
            kind: HarnessKind::Acp,
            argv: vec!["/nonexistent/codex".into(), "app-server".into()],
            env: BTreeMap::from([("CODEX_HOME".into(), codex_home.display().to_string())]),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        let mut cfg = Config::default();
        cfg.harnesses.insert("codex".into(), profile);
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("acpmux-model-availability-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_chatgpt_account_model_refusal_is_a_refusal_with_the_backends_words() {
        assert_eq!(
            refusal_reason(REFUSED).as_deref(),
            Some(
                "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account."
            )
        );
        assert_eq!(named_model(REFUSED).as_deref(), Some("gpt-6.1-sol"));
        assert_eq!(refusal_reason("stream disconnected before completion"), None);
    }

    /// The user's setup: `~/.codex/config.toml` names gpt-6.1-sol and a catalog of its own, and
    /// the ChatGPT sign-in is served gpt-5.6-* only, so the live list marks gpt-6.1-sol and
    /// gpt-6-astra unavailable. A new chat starts on a model the account serves, never the
    /// config's, and pickers neither offer nor lead with the marked ones.
    #[tokio::test]
    async fn a_new_codex_chat_never_starts_on_a_model_its_chatgpt_sign_in_is_not_served() {
        let home = scratch("start");
        let hub = codex_hub(&home.join("codex-home"));
        let live: Vec<crate::live_models::LiveModel> = serde_json::from_value(json!([
            {"id": "gpt-6.1-sol", "name": "GPT-6.1-Sol", "isDefault": true, "unavailable": crate::live_models::account_models::UNAVAILABLE},
            {"id": "gpt-6-astra", "name": "GPT-6-Astra", "unavailable": crate::live_models::account_models::UNAVAILABLE},
            {"id": "gpt-5.6-sol", "name": "GPT-5.6-Sol"},
            {"id": "gpt-5.6-luna", "name": "GPT-5.6-Luna"},
        ]))
        .unwrap();
        hub.live_models.lock().unwrap().insert("codex".into(), live);
        let cfg = hub.config.read().await;
        let profile = cfg.harnesses["codex"].clone();
        let start = hub.start_view(&cfg, "codex", &profile).unwrap();
        assert_eq!(start["model"], "gpt-5.6-sol", "{start}");
        assert_eq!(start["effort"], "medium", "{start}");
        drop(cfg);
        let models = hub.models_catalog().await;
        let row = models["harnesses"]
            .as_array()
            .unwrap()
            .iter()
            .find(|h| h["harness"] == "codex")
            .unwrap()
            .clone();
        let entry = |id: &str| {
            row["models"].as_array().unwrap().iter().find(|m| m["id"] == id).unwrap().clone()
        };
        assert!(entry("gpt-6.1-sol")["unavailable"].is_string(), "{row}");
        assert!(entry("gpt-5.6-sol").get("unavailable").is_none(), "{row}");
        let top: Vec<&str> =
            row["topModels"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
        assert_eq!(top, ["gpt-5.6-sol", "gpt-5.6-luna"], "{row}");
        let _ = std::fs::remove_dir_all(&home);
    }

    /// Without a live list, the models the harness's sessions reported decide: the first one not
    /// refused, never the refused one or "default".
    #[tokio::test]
    async fn the_fallback_is_a_model_nothing_refused() {
        let home = scratch("fallback");
        let hub = codex_hub(&home.join("codex-home"));
        hub.known_models.lock().unwrap().insert(
            "codex".into(),
            ["default", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.6-sol"]
                .map(|id| (id.to_owned(), id.to_uppercase()))
                .to_vec(),
        );
        hub.refused_models
            .lock()
            .unwrap()
            .insert(("codex".into(), "gpt-6-astra".into()), "refused".into());
        let to = hub.usable_model("codex", "gpt-6.1-sol").unwrap();
        assert_eq!(to, Fallback { id: "gpt-5.6-sol".into(), name: "GPT-5.6-SOL".into() });
        assert_eq!(hub.model_refused("codex", "gpt-6-astra").as_deref(), Some("refused"));
        assert_eq!(hub.model_refused("codex", "gpt-5.6-sol"), None);
        let _ = std::fs::remove_dir_all(&home);
    }
}
