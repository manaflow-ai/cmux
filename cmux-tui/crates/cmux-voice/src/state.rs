//! The JSON the acpmux `_acpmux/voice/*` methods answer.

use serde::Serialize;
use serde_json::{Value, json};

use crate::catalog::{KeyUse, Kind, PROVIDERS, Provider, Wire};
use crate::endpoint::Resolved;
use crate::error::VoiceError;
use crate::provider::Transcript;

/// `_acpmux/voice/state`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    pub engine: &'static str,
    pub label: &'static str,
    pub kind: Kind,
    pub wire: Wire,
    pub key: KeyUse,
    /// The effective base URL, or empty (on-device, or no usable URL).
    pub url: String,
    /// The effective model, or empty.
    pub model: String,
    /// `<provider>@<origin>`, or `None` when no key is ever sent to this endpoint.
    pub key_account: Option<String>,
    pub key_service: &'static str,
    pub has_key: bool,
    /// Why the chosen engine cannot be used as set (`not_configured`, `bad_endpoint`), else
    /// `None`. Always `None` for the on-device engine.
    pub error: Option<VoiceError>,
    pub providers: &'static [Provider],
}

/// The state of `resolved`, with whether a key is saved at its account.
pub fn state(resolved: &Resolved, has_key: bool) -> State {
    let p = resolved.provider;
    let (url, key_account, error) = match &resolved.endpoint {
        Ok(e) => (e.base_url.clone(), e.key_account(), None),
        Err(_) if p.wire == Wire::Builtin => (String::new(), None, None),
        Err(e) => (String::new(), None, Some(e.clone())),
    };
    State {
        engine: p.id,
        label: p.label,
        kind: p.kind,
        wire: p.wire,
        key: p.key,
        url,
        model: resolved.model.clone(),
        has_key: has_key && key_account.is_some(),
        key_account,
        key_service: crate::KEY_SERVICE,
        error,
        providers: PROVIDERS,
    }
}

/// `{"text": ...}` or `{"error": {code, detail}}`.
pub fn transcribe_reply(result: &Result<Transcript, VoiceError>) -> Value {
    match result {
        Ok(t) => json!({"text": t.text}),
        Err(e) => json!({"error": e}),
    }
}

/// `{"ok": true}` or `{"ok": false, "error": {code, detail}}`.
pub fn check_reply(result: &Result<(), VoiceError>) -> Value {
    match result {
        Ok(()) => json!({"ok": true}),
        Err(e) => json!({"ok": false, "error": e}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::{Settings, resolve};
    use crate::error::ErrorCode;

    fn of(engine: &str, url: &str) -> Resolved {
        resolve(&Settings { engine: engine.into(), url: url.into(), model: String::new() })
    }

    #[test]
    fn state_shape_for_a_cloud_provider() {
        let v = serde_json::to_value(state(&of("openai", ""), true)).unwrap();
        let mut obj = v.as_object().unwrap().clone();
        assert_eq!(obj.remove("providers").unwrap().as_array().unwrap().len(), PROVIDERS.len());
        assert_eq!(
            Value::Object(obj),
            json!({
                "engine": "openai", "label": "OpenAI", "kind": "cloud", "wire": "openaiTranscriptions",
                "key": "required", "url": "https://api.openai.com/v1", "model": "gpt-4o-mini-transcribe",
                "keyAccount": "openai@https://api.openai.com", "keyService": "cmux-voice-key",
                "hasKey": true, "error": null,
            })
        );
    }

    #[test]
    fn state_for_on_device_unknown_and_unconfigured() {
        for engine in ["onDevice", "whatever"] {
            let s = state(&of(engine, ""), true);
            assert_eq!(s.engine, "onDevice");
            assert_eq!((s.url.as_str(), s.key_account.as_deref(), s.has_key), ("", None, false));
            assert_eq!(s.error, None);
        }
        let s = state(&of("custom", ""), false);
        assert_eq!(s.error.map(|e| e.code), Some(ErrorCode::NotConfigured));
        let s = state(&of("groq", "http://example.com"), true);
        assert_eq!(s.error.map(|e| e.code), Some(ErrorCode::BadEndpoint));
        assert!(!s.has_key);
        let s = state(&of("whisperCpp", ""), true);
        assert_eq!((s.key_account, s.has_key), (None, false));
    }

    #[test]
    fn reply_shapes() {
        assert_eq!(transcribe_reply(&Ok(Transcript { text: "hi".into() })), json!({"text": "hi"}));
        assert_eq!(
            transcribe_reply(&Err(VoiceError::bare(ErrorCode::Offline))),
            json!({"error": {"code": "offline", "detail": ""}})
        );
        assert_eq!(check_reply(&Ok(())), json!({"ok": true}));
        assert_eq!(
            check_reply(&Err(VoiceError::bare(ErrorCode::KeyMissing))),
            json!({"ok": false, "error": {"code": "key_missing", "detail": ""}})
        );
    }
}
