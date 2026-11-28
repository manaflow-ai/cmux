//! The install principal's token mint and revoke (cmux-cloud-config's `install_auth` step
//! machine) for the phones. One call, `install_auth_json(op, request)`, answers what the Mac
//! reaches over cmux-layout-reducer-ffi's C ABI: `step` is the Mac's
//! `cloud_identity_install_auth_step` (`{state, event, now_ms}` in, `{state, effect}` out; the
//! app performs the effect and sends back what it got). Both call
//! `cmux_cloud_config::install_auth::step`, so the exchange cannot differ between the Mac and
//! a phone. The phone keeps the I/O: HTTP, the Secure Enclave or Keystore signer (the private
//! key never enters Rust), the Keychain record and the one shared in-flight mint.
//!
//! - `step` `{state: State|null, event: Event, now_ms}` -> `{state, effect}`.
//! - `headers` `{client_version?}` -> `{headers}`: what every request carries.
//! - `profile` `{kind: "ios"|"mac"}` -> the profile a `start` event names.
//!
//! JSON, not records: the state is opaque to the app and the effects are the Mac's wire, so a
//! string in, string out shape keeps one contract for the C ABI, Swift and Kotlin.

use std::fmt;

use cmux_cloud_config::install_auth::{self, Event, Profile, State};
use serde_json::{Value, json};

/// Why `install_auth_json` gave no answer. A refusal the machine makes (a bad challenge, a
/// refused mint) is an answer (`{"effect": "fail", ...}`), not this.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum InstallAuthJsonError {
    /// No op of that name.
    UnknownOperation { operation: String },
    // Not `message`: Kotlin errors extend Throwable, which owns `message`.
    /// The request is not the op's JSON.
    Invalid { detail: String },
}

impl fmt::Display for InstallAuthJsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownOperation { operation } => {
                write!(f, "unknown install auth op {operation:?}")
            }
            Self::Invalid { detail } => write!(f, "invalid install auth request: {detail}"),
        }
    }
}

impl std::error::Error for InstallAuthJsonError {}

fn invalid(error: impl fmt::Display) -> InstallAuthJsonError {
    InstallAuthJsonError::Invalid { detail: error.to_string() }
}

fn field<T: serde::de::DeserializeOwned>(
    request: &Value,
    name: &str,
) -> Result<T, InstallAuthJsonError> {
    serde_json::from_value(request.get(name).cloned().unwrap_or(Value::Null))
        .map_err(|error| invalid(format!("{name}: {error}")))
}

/// Answers one install auth op: `request` and the answer are the op's JSON.
#[uniffi::export]
pub fn install_auth_json(
    operation: String,
    request: String,
) -> Result<String, InstallAuthJsonError> {
    let request: Value = serde_json::from_str(&request).map_err(invalid)?;
    if !request.is_object() {
        return Err(invalid("the request is not a JSON object"));
    }
    let answer = match operation.as_str() {
        "step" => {
            let state: Option<State> = field(&request, "state")?;
            let event: Event = field(&request, "event")?;
            let now_ms: f64 = field(&request, "now_ms")?;
            let (state, effect) = install_auth::step(state, event, now_ms);
            json!({ "state": state, "effect": effect })
        }
        "headers" => {
            let client_version: Option<String> = field(&request, "client_version")?;
            json!({ "headers": install_auth::headers(client_version.as_deref()) })
        }
        "profile" => {
            let kind: String = field(&request, "kind")?;
            let profile = match kind.as_str() {
                "ios" => Profile::ios(),
                "mac" => Profile::mac(),
                _ => return Err(invalid(format!("kind: no install profile {kind:?}"))),
            };
            json!(profile)
        }
        _ => return Err(InstallAuthJsonError::UnknownOperation { operation }),
    };
    Ok(answer.to_string())
}

#[cfg(test)]
#[path = "install_auth_tests.rs"]
mod tests;
