//! `_acpmux/voice/*`: the person's own dictation provider (crate `cmux-voice`).
//!
//! Each call reads `agentPane.dictationEngine`, `agentPane.dictationEngineURL` and
//! `agentPane.dictationEngineModel` from cmux-next.json (`user_settings`); an unknown engine is
//! on-device. The key lives in the Keychain (service `cmux-voice-key`, account
//! `<providerId>@<origin>`); it is read only inside these calls, which the app makes from a
//! person's action (Settings, the mic), never at daemon start, and it never leaves this file but
//! as the provider's `Authorization` header. A lookup that finds nothing is no key.
//!
//! Who may call: the unix socket only (the app's host). Never the local app's web connection, Web
//! or a peer. No hub state is read or locked; the HTTP runs on the runtime, off the request loop's
//! locks, bounded by the provider's own timeouts.

use std::time::Duration;

use cmux_voice::{Audio, AudioError, BatchRequest, Endpoint, Http, Resolved, Settings};
use serde_json::Value;

use super::Origin;
use crate::rpc::{RpcError, method};

pub(super) const METHODS: &[&str] = &[
    method::MUX_VOICE_STATE,
    method::MUX_VOICE_TRANSCRIBE,
    method::MUX_VOICE_CHECK,
    method::MUX_VOICE_RELAY,
];

/// The longest `state` waits on the Keychain, so a Settings page never hangs on it.
const STATE_KEY_WAIT: Duration = Duration::from_secs(3);
/// The longest `transcribe` and `check` wait on the Keychain.
const USE_KEY_WAIT: Duration = Duration::from_secs(10);

pub(super) const ENGINE_KEY: &str = "agentPane.dictationEngine";
pub(super) const URL_KEY: &str = "agentPane.dictationEngineURL";
pub(super) const MODEL_KEY: &str = "agentPane.dictationEngineModel";

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<T, RpcError> {
    tokio::task::spawn_blocking(work).await.map_err(|e| RpcError::internal(e.to_string()))
}

/// The three settings from `doc` (nested or flat keys); missing or non-text values are empty.
fn settings_from(doc: &Value) -> Settings {
    let text = |key: &str| {
        crate::user_settings::value(doc, key)
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default()
    };
    Settings { engine: text(ENGINE_KEY), url: text(URL_KEY), model: text(MODEL_KEY) }
}

/// The settings now. A missing or unreadable file is every default: on-device.
fn read_settings() -> Settings {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => settings_from(&doc),
        crate::user_settings::Settings::Missing | crate::user_settings::Settings::Unreadable(_) => {
            Settings::default()
        }
    }
}

/// The key saved for `endpoint`, waiting at most `wait`; `None` when the endpoint takes none,
/// nothing is saved, or the secret store does not answer in time.
async fn saved_key(endpoint: &Endpoint, wait: Duration) -> Option<String> {
    let account = endpoint.key_account()?;
    // The account (`openai@https://api.openai.com`) goes as one argument to `security -a` or
    // `secret-tool ... account`, never through a shell or `resolve_reference`'s split.
    let lookup = tokio::task::spawn_blocking(move || {
        crate::config::profiles::keychain_lookup(cmux_voice::KEY_SERVICE, Some(&account))
    });
    match tokio::time::timeout(wait, lookup).await {
        Ok(Ok(Ok(key))) => Some(key).filter(|k| !k.trim().is_empty()),
        _ => None,
    }
}

/// The caller supplies recording bytes, never authority to read a daemon-side path.
fn audio_param(params: &Value) -> Result<Audio, RpcError> {
    if params.get("path").is_some() {
        return Err(RpcError::invalid_params("path is not supported; send audio as base64"));
    }
    let audio = params
        .get("audio")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| RpcError::invalid_params("audio is required as base64"))?;
    Ok(Audio::Base64(audio.to_owned()))
}

async fn transcribe(resolved: Resolved, params: &Value) -> Result<Value, RpcError> {
    let audio = audio_param(params)?;
    let language = params.get("language").and_then(Value::as_str).map(str::to_owned);
    let endpoint = match resolved.endpoint {
        Ok(e) => e,
        Err(e) => return Ok(cmux_voice::transcribe_reply(&Err(e))),
    };
    // The recording first: one over the cap is refused before any lookup or connection.
    let bytes = match blocking(move || audio.load(cmux_voice::MAX_AUDIO_BYTES)).await? {
        Ok(bytes) => bytes,
        Err(AudioError::TooLarge(e)) => return Ok(cmux_voice::transcribe_reply(&Err(e))),
        Err(AudioError::Invalid(why)) => return Err(RpcError::invalid_params(why)),
    };
    let key = saved_key(&endpoint, USE_KEY_WAIT).await;
    let provider = match cmux_voice::provider_for(endpoint, key, Http::default()) {
        Ok(p) => p,
        Err(e) => return Ok(cmux_voice::transcribe_reply(&Err(e))),
    };
    let result =
        provider.transcribe(BatchRequest { audio: &bytes, language: language.as_deref() }).await;
    Ok(cmux_voice::transcribe_reply(&result))
}

async fn check(resolved: Resolved) -> Value {
    let endpoint = match resolved.endpoint {
        Ok(e) => e,
        Err(e) => return cmux_voice::check_reply(&Err(e)),
    };
    let key = saved_key(&endpoint, USE_KEY_WAIT).await;
    let result = match cmux_voice::provider_for(endpoint, key, Http::default()) {
        Ok(provider) => provider.check().await,
        Err(e) => Err(e),
    };
    cmux_voice::check_reply(&result)
}

async fn state(resolved: Resolved) -> Result<Value, RpcError> {
    let has_key = match &resolved.endpoint {
        Ok(endpoint) => saved_key(endpoint, STATE_KEY_WAIT).await.is_some(),
        Err(_) => false,
    };
    serde_json::to_value(cmux_voice::state(&resolved, has_key))
        .map_err(|e| RpcError::internal(e.to_string()))
}

pub(super) async fn handle(origin: Origin, m: &str, params: &Value) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::invalid_params("dictation: only the unix socket may ask"));
    }
    // Reducer state belongs to the native microphone owner, never the page. This call does
    // no I/O, key lookup, prompt sending or playback; the host executes its returned effects.
    if m == method::MUX_VOICE_RELAY {
        let state = match params.get("state").filter(|v| !v.is_null()) {
            Some(value) => serde_json::from_value(value.clone())
                .map_err(|_| RpcError::invalid_params("invalid voice relay state"))?,
            None => cmux_voice::relay::RelayState::default(),
        };
        let event = serde_json::from_value(params.get("event").cloned().unwrap_or(Value::Null))
            .map_err(|_| RpcError::invalid_params("invalid voice relay event"))?;
        return serde_json::to_value(cmux_voice::relay::reduce(state, event))
            .map_err(|e| RpcError::internal(e.to_string()));
    }
    // A voice session captures these values once. The key is still looked up for the captured
    // origin on each use, so changing the global URL cannot redirect an in-flight recording.
    let settings = match params.get("settings") {
        Some(snapshot) if m != method::MUX_VOICE_STATE => snapshot_settings(snapshot)?,
        _ => blocking(read_settings).await?,
    };
    let resolved = cmux_voice::resolve(&settings);
    match m {
        method::MUX_VOICE_STATE => {
            let mut result = state(resolved).await?;
            result
                .as_object_mut()
                .ok_or_else(|| RpcError::internal("voice state must be an object"))?
                .insert(
                    "settings".into(),
                    serde_json::json!({
                        "engine": settings.engine, "url": settings.url, "model": settings.model,
                    }),
                );
            Ok(result)
        }
        method::MUX_VOICE_TRANSCRIBE => transcribe(resolved, params).await,
        method::MUX_VOICE_CHECK => Ok(check(resolved).await),
        _ => Err(RpcError::method_not_found(m)),
    }
}

fn snapshot_settings(value: &Value) -> Result<Settings, RpcError> {
    let field = |name| {
        value.get(name).and_then(Value::as_str).map(str::to_owned).ok_or_else(|| {
            RpcError::invalid_params("voice settings require engine, url and model strings")
        })
    };
    Ok(Settings { engine: field("engine")?, url: field("url")?, model: field("model")? })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn settings_read_nested_or_flat() {
        let nested = json!({"agentPane": {"dictationEngine": "groq", "dictationEngineURL": "https://x.dev/v1",
            "dictationEngineModel": "m"}});
        assert_eq!(
            settings_from(&nested),
            Settings { engine: "groq".into(), url: "https://x.dev/v1".into(), model: "m".into() }
        );
        let flat = json!({"agentPane.dictationEngine": "whisperCpp"});
        assert_eq!(settings_from(&flat).engine, "whisperCpp");
        assert_eq!(
            settings_from(&json!({"agentPane": {"dictationEngine": 3}})),
            Settings::default()
        );
    }

    #[test]
    fn audio_param_requires_bytes_and_rejects_any_path() {
        assert_eq!(
            audio_param(&json!({"audio": "UklGRg=="})).unwrap(),
            Audio::Base64("UklGRg==".into())
        );
        for params in [json!({}), json!({"audio": ""}), json!({"audio": null}), json!({"audio": 1})]
        {
            assert!(audio_param(&params).is_err(), "{params}");
        }
        for path in [json!("/a.wav"), json!("relative.wav"), Value::Null, json!(1)] {
            assert!(audio_param(&json!({"path": path})).is_err());
            assert!(audio_param(&json!({"path": path, "audio": "UklGRg=="})).is_err());
        }
    }
}
