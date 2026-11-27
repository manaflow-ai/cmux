//! Models a harness's backend refuses outright. A turn that fails with the upstream error code
//! `unsupported_parameter` (for example a Codex model that sends image web search to a backend
//! that refuses it) marks that model unavailable for that harness, with the backend's message,
//! and `_acpmux/models` reports it, so the picker never offers a model that always fails.

use std::collections::HashMap;

use serde_json::Value;

use super::{Hub, Session, current_model};

/// The backend's message when `error` is an `unsupported_parameter` refusal, else None.
pub(crate) fn refusal_reason(error: &str) -> Option<String> {
    if !error.contains("unsupported_parameter") {
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

impl Hub {
    /// A turn that ended normally but whose reply is the backend's error object (Codex streams a
    /// refused request as the agent's message) counts as that refusal too.
    pub(super) fn note_reply_refusal(&self, session: &Session) {
        let reply = session.stream.lock().unwrap().trailing_text.clone();
        let is_error_object = serde_json::from_str::<Value>(reply.trim())
            .is_ok_and(|value| value.get("type").and_then(Value::as_str) == Some("error"));
        if is_error_object {
            self.note_model_refusal(session, &reply);
        }
    }

    /// Remembers the session's current model as refused when `error` is such a refusal.
    pub(super) fn note_model_refusal(&self, session: &Session, error: &str) {
        let Some(reason) = refusal_reason(error) else { return };
        let meta = session.meta();
        let Some(model) = current_model(&meta) else { return };
        self.refused_models.lock().unwrap().insert((meta.harness.clone(), model), reason);
    }
}
