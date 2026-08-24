//! Trust policy: the owner-at-keyboard YOLO receipt and the fail-closed
//! effective trust rules. Behavior port of `packages/relay/bin/
//! trust-policy.mjs`; the tests mirror `trust-policy.test.mjs`.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::config::Config;

/// The relay trust levels (`TrustLevel` in chatmux `packages/protocol`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trust {
    Observe,
    Supervised,
    Autonomous,
}

pub const DEFAULT_RELAY_TRUST: Trust = Trust::Supervised;
pub const YOLO_CONFIRMATION_POLICY_VERSION: i64 = 1;

impl Trust {
    pub fn as_str(self) -> &'static str {
        match self {
            Trust::Observe => "observe",
            Trust::Supervised => "supervised",
            Trust::Autonomous => "autonomous",
        }
    }

    /// Strict, value-safe decode; `None` for anything else.
    pub fn parse(value: &str) -> Option<Trust> {
        match value {
            "observe" => Some(Trust::Observe),
            "supervised" => Some(Trust::Supervised),
            "autonomous" => Some(Trust::Autonomous),
            _ => None,
        }
    }
}

impl std::fmt::Display for Trust {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

/// Canonical relay trust value, or the supervised default.
pub fn relay_trust(value: Option<&str>) -> Trust {
    value.and_then(Trust::parse).unwrap_or(DEFAULT_RELAY_TRUST)
}

/// Strict decode for the non-authorizing pairing UI hint.
pub fn requested_trust_hint(value: Option<&str>) -> Option<Trust> {
    value.and_then(Trust::parse)
}

fn token_fingerprint(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

/// Build the durable receipt written only after an owner types YOLO locally.
/// It is bound to the backend and both halves of the pairing identity. A
/// copied receipt cannot authorize a replacement backend, device id, or
/// credential, and a policy-version bump can invalidate every older
/// confirmation without reading untrusted text.
pub fn yolo_confirmation_receipt(config: &Config, confirmed_at: i64) -> Option<Value> {
    if config.device_id.is_empty()
        || config.token.is_empty()
        || config.backend.is_empty()
        || confirmed_at <= 0
    {
        return None;
    }
    Some(json!({
        "policyVersion": YOLO_CONFIRMATION_POLICY_VERSION,
        "backend": config.backend,
        "deviceId": config.device_id,
        "tokenHash": token_fingerprint(&config.token),
        "timestamp": confirmed_at,
    }))
}

/// Exact backend, machine, credential, and policy match for a local receipt.
pub fn has_yolo_confirmation(config: &Config) -> bool {
    let Some(receipt) = config.yolo_confirmed_at.as_ref().and_then(Value::as_object) else {
        return false;
    };
    let field = |name: &str| receipt.get(name).and_then(Value::as_str);
    receipt.get("policyVersion").and_then(Value::as_i64) == Some(YOLO_CONFIRMATION_POLICY_VERSION)
        && !config.backend.is_empty()
        && field("backend") == Some(config.backend.as_str())
        && !config.device_id.is_empty()
        && field("deviceId") == Some(config.device_id.as_str())
        && !config.token.is_empty()
        && field("tokenHash") == Some(token_fingerprint(&config.token).as_str())
        && receipt.get("timestamp").and_then(Value::as_i64).is_some_and(|value| value > 0)
}

/// Effective local authority for a connection. Autonomous is fail-closed when
/// its owner-at-keyboard receipt is absent, stale, copied, or from an older
/// confirmation policy. Invalid legacy config also defaults to supervised.
pub fn effective_local_trust(config: &Config) -> Trust {
    let candidate = relay_trust(config.pending_trust.as_deref().or(config.trust.as_deref()));
    if candidate == Trust::Autonomous && !has_yolo_confirmation(config) {
        DEFAULT_RELAY_TRUST
    } else {
        candidate
    }
}

/// Remove a receipt that no longer belongs to this exact pairing identity.
pub fn clear_invalid_yolo_confirmation(config: &mut Config) {
    if !has_yolo_confirmation(config) {
        config.yolo_confirmed_at = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paired_config() -> Config {
        Config {
            backend: "https://api.chatmux.dev".to_owned(),
            device_id: "dev_1234".to_owned(),
            token: "credential-1".to_owned(),
            ..Config::default()
        }
    }

    #[test]
    fn supervised_is_the_default_for_url_onboarding_and_old_config() {
        assert_eq!(relay_trust(None), Trust::Supervised);
        assert_eq!(relay_trust(Some("bogus")), Trust::Supervised);
        assert_eq!(relay_trust(Some("observe")), Trust::Observe);
        assert_eq!(requested_trust_hint(Some("nonsense")), None);
        assert_eq!(requested_trust_hint(Some("autonomous")), Some(Trust::Autonomous));
        assert_eq!(effective_local_trust(&Config::default()), Trust::Supervised);
    }

    #[test]
    fn autonomous_intent_cannot_authorize_without_a_receipt() {
        let mut config = paired_config();
        config.pending_trust = Some("autonomous".to_owned());
        assert_eq!(effective_local_trust(&config), Trust::Supervised);
        config.pending_trust = None;
        config.trust = Some("autonomous".to_owned());
        assert_eq!(effective_local_trust(&config), Trust::Supervised);
    }

    #[test]
    fn one_keyboard_confirmation_creates_an_exact_identity_receipt() {
        let mut config = paired_config();
        let receipt = yolo_confirmation_receipt(&config, 1_755_000_000_000).expect("receipt");
        assert_eq!(
            receipt.get("policyVersion").and_then(Value::as_i64),
            Some(YOLO_CONFIRMATION_POLICY_VERSION)
        );
        // The receipt never contains the credential itself.
        assert!(!receipt.to_string().contains("credential-1"));
        config.trust = Some("autonomous".to_owned());
        config.yolo_confirmed_at = Some(receipt);
        assert!(has_yolo_confirmation(&config));
        assert_eq!(effective_local_trust(&config), Trust::Autonomous);
    }

    #[test]
    fn a_receipt_only_authorizes_the_same_pairing() {
        let mut config = paired_config();
        config.trust = Some("autonomous".to_owned());
        config.yolo_confirmed_at = yolo_confirmation_receipt(&config, 1_755_000_000_000);
        assert_eq!(effective_local_trust(&config), Trust::Autonomous);

        let mut other_device = config.clone();
        other_device.device_id = "dev_other".to_owned();
        assert!(!has_yolo_confirmation(&other_device));
        assert_eq!(effective_local_trust(&other_device), Trust::Supervised);

        let mut other_token = config.clone();
        other_token.token = "credential-2".to_owned();
        assert!(!has_yolo_confirmation(&other_token));

        let mut other_backend = config;
        other_backend.backend = "https://api-staging.chatmux.dev".to_owned();
        assert!(!has_yolo_confirmation(&other_backend));
    }

    #[test]
    fn policy_version_replay_and_malformed_receipts_fail_closed() {
        let mut config = paired_config();
        config.trust = Some("autonomous".to_owned());
        let mut receipt = yolo_confirmation_receipt(&config, 1_755_000_000_000).expect("receipt");
        receipt["policyVersion"] = Value::from(0);
        config.yolo_confirmed_at = Some(receipt);
        assert!(!has_yolo_confirmation(&config));

        config.yolo_confirmed_at = Some(Value::from("2025-01-01"));
        assert!(!has_yolo_confirmation(&config));
        clear_invalid_yolo_confirmation(&mut config);
        assert!(config.yolo_confirmed_at.is_none());
        assert_eq!(effective_local_trust(&config), Trust::Supervised);
    }

    #[test]
    fn incomplete_identity_cannot_mint_a_receipt() {
        let mut config = paired_config();
        config.token = String::new();
        assert!(yolo_confirmation_receipt(&config, 1_755_000_000_000).is_none());
        let config = paired_config();
        assert!(yolo_confirmation_receipt(&config, 0).is_none());
    }

    #[test]
    fn observe_and_supervised_do_not_retain_autonomous_authority() {
        let mut config = paired_config();
        config.trust = Some("observe".to_owned());
        config.yolo_confirmed_at = yolo_confirmation_receipt(&config, 1_755_000_000_000);
        assert_eq!(effective_local_trust(&config), Trust::Observe);
        // A receipt for the same identity stays valid but grants nothing
        // until autonomous is requested again.
        assert!(has_yolo_confirmation(&config));
    }
}
