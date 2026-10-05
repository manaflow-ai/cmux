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

/// Test support: pins a session's current model as a `${model}` request would.
#[cfg(test)]
pub(crate) fn set_model_for_test(session: &Session, model: &str) {
    session.meta.lock().unwrap().model_request = Some(model.to_owned());
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_unsupported_parameter_refusal_marks_its_model_with_the_backend_message() {
        let error = r#"{"type":"error","error":{"message":"Image web search is not supported by rustponsesapi.","type":"invalid_request_error","param":"tools.search_content_types","code":"unsupported_parameter"},"status":400}"#;
        assert_eq!(
            refusal_reason(error).as_deref(),
            Some("Image web search is not supported by rustponsesapi.")
        );
        assert_eq!(refusal_reason("rate limited"), None);
        let refused = HashMap::from([(
            ("codex".to_owned(), "gpt-5.5".to_owned()),
            "no image search".to_owned(),
        )]);
        let mut models = vec![json!({"id": "gpt-5.5"}), json!({"id": "gpt-6.1-sol"})];
        mark_unavailable(&mut models, "codex", &refused);
        assert_eq!(models[0]["unavailable"], "no image search");
        assert!(models[1].get("unavailable").is_none());
        let mut other = vec![json!({"id": "gpt-5.5"})];
        mark_unavailable(&mut other, "opencode", &refused);
        assert!(other[0].get("unavailable").is_none());
    }
}
