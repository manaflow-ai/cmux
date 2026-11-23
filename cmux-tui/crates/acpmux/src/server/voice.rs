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

use std::path::PathBuf;
use std::time::Duration;

use cmux_voice::{Audio, AudioError, BatchRequest, Endpoint, Http, Resolved, Settings};
use serde_json::Value;

use super::Origin;
use crate::rpc::{RpcError, method};

pub(super) const METHODS: &[&str] =
    &[method::MUX_VOICE_STATE, method::MUX_VOICE_TRANSCRIBE, method::MUX_VOICE_CHECK];

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

/// The recording `params` names: `path` (absolute) or `audio` (base64).
fn audio_param(params: &Value) -> Result<Audio, RpcError> {
    let text = |key: &str| params.get(key).and_then(Value::as_str).filter(|v| !v.is_empty());
    match (text("path"), text("audio")) {
        (Some(path), None) => Ok(Audio::Path(PathBuf::from(path))),
        (None, Some(audio)) => Ok(Audio::Base64(audio.to_owned())),
        (Some(_), Some(_)) => Err(RpcError::invalid_params("give path or audio, not both")),
        (None, None) => Err(RpcError::invalid_params("path or audio is required")),
    }
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
    let resolved = cmux_voice::resolve(&blocking(read_settings).await?);
    match m {
        method::MUX_VOICE_STATE => state(resolved).await,
        method::MUX_VOICE_TRANSCRIBE => transcribe(resolved, params).await,
        method::MUX_VOICE_CHECK => Ok(check(resolved).await),
        _ => Err(RpcError::method_not_found(m)),
    }
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
    fn audio_param_needs_exactly_one() {
        assert_eq!(audio_param(&json!({"path": "/a.wav"})).unwrap(), Audio::Path("/a.wav".into()));
        assert_eq!(
            audio_param(&json!({"audio": "UklGRg=="})).unwrap(),
            Audio::Base64("UklGRg==".into())
        );
        assert!(audio_param(&json!({})).is_err());
        assert!(audio_param(&json!({"path": "/a", "audio": "b"})).is_err());
    }
}
