use std::collections::HashSet;

use anyhow::{Context, Result, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Verifier as _, VerifyingKey};
use serde::Deserialize;
use uuid::Uuid;

use crate::broker::{
    Binding, DiscoverySnapshot, GrantVerificationKeySet, Platform, canonical_endpoint_id,
    safe_token, same_relay_fleet,
};
use crate::{CMUX_TUI_ALPN_TEXT, CMUX_TUI_PAIR_SCOPE};

const GRANT_TYP: &str = "cmux-pair-grant+jwt";
const MAX_GRANT_BYTES: usize = 32 * 1024;
const MAX_GRANT_LIFETIME_SECONDS: i64 = 7 * 24 * 60 * 60;
const CLOCK_SKEW_SECONDS: i64 = 30;
const ED25519_SPKI_PREFIX: &[u8] =
    &[0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct GrantHeader {
    alg: String,
    typ: String,
    kid: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GrantPeer {
    #[serde(deserialize_with = "crate::broker::deserialize_canonical_uuid")]
    pub binding_id: Uuid,
    #[serde(deserialize_with = "crate::broker::deserialize_canonical_uuid")]
    pub device_id: Uuid,
    pub tag: String,
    pub platform: Platform,
    pub endpoint_id: String,
    pub identity_generation: u32,
}

impl GrantPeer {
    fn validate(&self) -> Result<()> {
        ensure!(canonical_endpoint_id(&self.endpoint_id), "grant EndpointID is invalid");
        ensure!(self.identity_generation > 0, "grant generation is invalid");
        ensure!(safe_token(&self.tag), "grant tag is invalid");
        Ok(())
    }

    fn matches_binding(&self, binding: &Binding) -> bool {
        self.binding_id == binding.binding_id
            && self.device_id == binding.device_id
            && self.tag == binding.tag
            && self.platform == binding.platform
            && self.endpoint_id == binding.endpoint_id
            && self.identity_generation == binding.identity_generation
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct PairGrantClaims {
    #[serde(deserialize_with = "crate::broker::deserialize_canonical_uuid")]
    pub jti: Uuid,
    pub iat: i64,
    pub nbf: i64,
    pub exp: i64,
    pub alpn: String,
    pub scope: String,
    pub initiator: GrantPeer,
    pub acceptor: GrantPeer,
}

impl PairGrantClaims {
    pub fn expires_at(&self) -> i64 {
        self.exp
    }
}

pub fn verify_pair_grant(
    compact: &str,
    key_set: &GrantVerificationKeySet,
    now: i64,
) -> Result<PairGrantClaims> {
    ensure!((5..=MAX_GRANT_BYTES).contains(&compact.len()), "pair grant size is invalid");
    ensure!(!compact.bytes().any(|byte| byte.is_ascii_whitespace()), "pair grant has whitespace");
    let mut segments = compact.split('.');
    let encoded_header = segments.next().context("pair grant has no header")?;
    let encoded_claims = segments.next().context("pair grant has no claims")?;
    let encoded_signature = segments.next().context("pair grant has no signature")?;
    ensure!(segments.next().is_none(), "pair grant is not a compact JWS");
    let header: GrantHeader = serde_json::from_slice(&canonical_decode(encoded_header, 4096)?)
        .context("pair grant header is invalid")?;
    ensure!(header.alg == "EdDSA", "pair grant algorithm is invalid");
    ensure!(header.typ == GRANT_TYP, "pair grant type is invalid");
    ensure!(safe_token(&header.kid), "pair grant key ID is invalid");
    let verifying_key = grant_verification_key(key_set, &header.kid)?;
    let signature_bytes = canonical_decode(encoded_signature, 64)?;
    ensure!(signature_bytes.len() == 64, "pair grant signature length is invalid");
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| anyhow::anyhow!("pair grant signature is invalid"))?;
    let signing_input = format!("{encoded_header}.{encoded_claims}");
    verifying_key
        .verify(signing_input.as_bytes(), &signature)
        .map_err(|_| anyhow::anyhow!("pair grant signature is invalid"))?;

    let claims: PairGrantClaims =
        serde_json::from_slice(&canonical_decode(encoded_claims, MAX_GRANT_BYTES)?)
            .context("pair grant claims are invalid")?;
    validate_claims(&claims, now)?;
    Ok(claims)
}

pub fn verify_grant_pair(
    claims: &PairGrantClaims,
    initiator: &Binding,
    acceptor: &Binding,
) -> Result<()> {
    ensure!(claims.initiator.matches_binding(initiator), "grant initiator does not match binding");
    ensure!(claims.acceptor.matches_binding(acceptor), "grant acceptor does not match binding");
    ensure!(acceptor.platform == Platform::Linux, "grant acceptor is not a TUI server");
    ensure!(acceptor.pairing_enabled, "grant acceptor pairing is disabled");
    ensure!(
        acceptor.capabilities.iter().any(|capability| capability == CMUX_TUI_PAIR_SCOPE),
        "grant acceptor lacks the TUI attach capability"
    );
    ensure!(initiator.device_id != acceptor.device_id, "grant peers use the same device");
    Ok(())
}

pub fn verify_server_preflight(
    compact: &str,
    tls_initiator_endpoint: &str,
    local_acceptor: &Binding,
    key_set: &GrantVerificationKeySet,
    now: i64,
) -> Result<PairGrantClaims> {
    ensure!(canonical_endpoint_id(tls_initiator_endpoint), "TLS initiator EndpointID is invalid");
    let claims = verify_pair_grant(compact, key_set, now)?;
    ensure!(
        claims.initiator.endpoint_id == tls_initiator_endpoint,
        "grant initiator does not match TLS peer"
    );
    ensure!(
        claims.acceptor.matches_binding(local_acceptor),
        "grant acceptor does not match local identity"
    );
    ensure!(local_acceptor.platform == Platform::Linux, "local acceptor is not a TUI server");
    ensure!(local_acceptor.pairing_enabled, "local acceptor pairing is disabled");
    ensure!(
        local_acceptor.capabilities.iter().any(|capability| capability == CMUX_TUI_PAIR_SCOPE),
        "local acceptor lacks the TUI attach capability"
    );
    ensure!(
        claims.initiator.device_id != claims.acceptor.device_id,
        "grant peers use the same device"
    );
    Ok(claims)
}

pub fn verify_server_admission(
    compact: &str,
    tls_initiator_endpoint: &str,
    local_acceptor: &Binding,
    snapshot: &DiscoverySnapshot,
    installed_relay_fleet: &[String],
    now: i64,
) -> Result<PairGrantClaims> {
    ensure!(canonical_endpoint_id(tls_initiator_endpoint), "TLS initiator EndpointID is invalid");
    ensure!(
        same_relay_fleet(&snapshot.relay_fleet, installed_relay_fleet),
        "broker relay fleet does not match installed policy"
    );
    let claims = verify_pair_grant(compact, &snapshot.grant_verification_keys, now)?;
    ensure!(
        claims.initiator.endpoint_id == tls_initiator_endpoint,
        "grant initiator does not match TLS peer"
    );
    ensure!(
        claims.acceptor.matches_binding(local_acceptor),
        "grant acceptor does not match local identity"
    );
    let initiators = snapshot
        .bindings
        .iter()
        .filter(|binding| binding.binding_id == claims.initiator.binding_id)
        .collect::<Vec<_>>();
    let acceptors = snapshot
        .bindings
        .iter()
        .filter(|binding| binding.binding_id == claims.acceptor.binding_id)
        .collect::<Vec<_>>();
    ensure!(initiators.len() == 1, "grant initiator binding is missing or ambiguous");
    ensure!(acceptors.len() == 1, "grant acceptor binding is missing or ambiguous");
    verify_grant_pair(&claims, initiators[0], acceptors[0])?;
    ensure!(acceptors[0].same_identity(local_acceptor), "local acceptor binding is stale");
    Ok(claims)
}

fn validate_claims(claims: &PairGrantClaims, now: i64) -> Result<()> {
    ensure!(claims.alpn == CMUX_TUI_ALPN_TEXT, "pair grant ALPN is invalid");
    ensure!(claims.scope == CMUX_TUI_PAIR_SCOPE, "pair grant scope is invalid");
    ensure!(claims.iat <= now + CLOCK_SKEW_SECONDS, "pair grant issued in the future");
    ensure!(claims.nbf <= now + CLOCK_SKEW_SECONDS, "pair grant is not active");
    ensure!(claims.exp > now - CLOCK_SKEW_SECONDS, "pair grant expired");
    ensure!(claims.nbf <= claims.exp, "pair grant times are invalid");
    ensure!(claims.iat <= claims.exp, "pair grant times are invalid");
    ensure!(
        claims.exp - claims.iat <= MAX_GRANT_LIFETIME_SECONDS,
        "pair grant lifetime is too long"
    );
    claims.initiator.validate()?;
    claims.acceptor.validate()?;
    ensure!(claims.initiator.binding_id != claims.acceptor.binding_id, "grant peers are identical");
    Ok(())
}

fn grant_verification_key(
    key_set: &GrantVerificationKeySet,
    selected_kid: &str,
) -> Result<VerifyingKey> {
    ensure!(key_set.version == 1, "unsupported grant key-set version");
    ensure!((1..=2).contains(&key_set.keys.len()), "grant key set size is invalid");
    let mut kids = HashSet::new();
    let mut selected = None;
    for key in &key_set.keys {
        ensure!(safe_token(&key.kid), "grant key ID is invalid");
        ensure!(kids.insert(&key.kid), "duplicate grant key ID");
        ensure!(key.alg == "EdDSA", "grant key algorithm is invalid");
        let der = STANDARD.decode(&key.spki_der_base64).context("grant key is not base64")?;
        ensure!(STANDARD.encode(&der) == key.spki_der_base64, "grant key base64 is not canonical");
        ensure!(der.len() == ED25519_SPKI_PREFIX.len() + 32, "grant key length is invalid");
        ensure!(der.starts_with(ED25519_SPKI_PREFIX), "grant key SPKI is invalid");
        let raw: [u8; 32] =
            der[ED25519_SPKI_PREFIX.len()..].try_into().expect("grant key length checked");
        let verifying = VerifyingKey::from_bytes(&raw).context("grant key is invalid")?;
        if key.kid == selected_kid {
            selected = Some(verifying);
        }
    }
    ensure!(kids.contains(&key_set.current_kid), "current grant key is absent");
    selected.context("pair grant uses an unknown key")
}

fn canonical_decode(value: &str, maximum_bytes: usize) -> Result<Vec<u8>> {
    ensure!(!value.is_empty(), "JWS segment is empty");
    ensure!(
        value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')),
        "JWS segment is not canonical base64url"
    );
    let bytes = URL_SAFE_NO_PAD.decode(value).context("JWS segment is invalid")?;
    ensure!(bytes.len() <= maximum_bytes, "JWS segment is too large");
    ensure!(URL_SAFE_NO_PAD.encode(&bytes) == value, "JWS segment is not canonical");
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use ed25519_dalek::{Signer as _, SigningKey};
    use serde_json::json;

    use crate::broker::GrantVerificationKey;

    use super::*;

    fn signed_grant(signing: &SigningKey, initiator_endpoint: &str, alpn: &str) -> String {
        let header = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&json!({
                "alg": "EdDSA",
                "typ": GRANT_TYP,
                "kid": "grant-key"
            }))
            .unwrap(),
        );
        let peer = |binding: &str, device: &str, platform: &str, endpoint: &str| {
            json!({
                "bindingId": binding,
                "deviceId": device,
                "tag": "tui-test",
                "platform": platform,
                "endpointId": endpoint,
                "identityGeneration": 1
            })
        };
        let claims = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&json!({
                "jti": "b848527f-c42f-4627-969a-a31fe2fd1c22",
                "iat": 1_000,
                "nbf": 995,
                "exp": 2_000,
                "alpn": alpn,
                "scope": CMUX_TUI_PAIR_SCOPE,
                "initiator": peer(
                    "ef64e442-52df-4b9f-97cc-fbe366911957",
                    "343eb618-7eba-4475-b880-966b55e40025",
                    "mac",
                    initiator_endpoint
                ),
                "acceptor": peer(
                    "cb7204f4-0416-4cd1-b8e9-cdff433fcd93",
                    "de4643b5-a926-4c1a-9b5c-03fa069ac9d0",
                    "linux",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                )
            }))
            .unwrap(),
        );
        let input = format!("{header}.{claims}");
        let signature = URL_SAFE_NO_PAD.encode(signing.sign(input.as_bytes()).to_bytes());
        format!("{input}.{signature}")
    }

    fn key_set(signing: &SigningKey) -> GrantVerificationKeySet {
        let mut der = ED25519_SPKI_PREFIX.to_vec();
        der.extend(signing.verifying_key().to_bytes());
        GrantVerificationKeySet {
            version: 1,
            current_kid: "grant-key".into(),
            keys: vec![GrantVerificationKey {
                kid: "grant-key".into(),
                alg: "EdDSA".into(),
                spki_der_base64: STANDARD.encode(der),
            }],
        }
    }

    #[test]
    fn verifies_tui_grant_and_tls_endpoint() {
        let signing = SigningKey::from_bytes(&[3; 32]);
        let endpoint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let compact = signed_grant(&signing, endpoint, CMUX_TUI_ALPN_TEXT);
        let claims = verify_pair_grant(&compact, &key_set(&signing), 1_100).unwrap();
        assert_eq!(claims.initiator.endpoint_id, endpoint);
    }

    #[test]
    fn rejects_mobile_alpn_and_unknown_key() {
        let signing = SigningKey::from_bytes(&[4; 32]);
        let endpoint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let compact = signed_grant(&signing, endpoint, "cmux/mobile/1");
        assert!(verify_pair_grant(&compact, &key_set(&signing), 1_100).is_err());
        let other = SigningKey::from_bytes(&[5; 32]);
        let compact = signed_grant(&other, endpoint, CMUX_TUI_ALPN_TEXT);
        assert!(verify_pair_grant(&compact, &key_set(&signing), 1_100).is_err());
    }

    #[test]
    fn admission_tolerates_heartbeat_timestamps_and_fleet_order() {
        let signing = SigningKey::from_bytes(&[8; 32]);
        let initiator_endpoint = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let compact = signed_grant(&signing, initiator_endpoint, CMUX_TUI_ALPN_TEXT);
        let local = Binding {
            binding_id: Uuid::parse_str("cb7204f4-0416-4cd1-b8e9-cdff433fcd93").unwrap(),
            device_id: Uuid::parse_str("de4643b5-a926-4c1a-9b5c-03fa069ac9d0").unwrap(),
            app_instance_id: Uuid::parse_str("94197e10-4c15-4c8a-af35-8361ed360f1c").unwrap(),
            tag: "tui-test".into(),
            platform: Platform::Linux,
            display_name: None,
            endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into(),
            identity_generation: 1,
            pairing_enabled: true,
            capabilities: vec![CMUX_TUI_PAIR_SCOPE.into()],
            path_hints: Vec::new(),
            last_seen_at: "2026-08-03T00:00:00.000Z".into(),
        };
        // The broker moved the acceptor's heartbeat timestamp after our
        // registration; identity is unchanged, so admission must succeed.
        let mut published = local.clone();
        published.last_seen_at = "2026-08-04T09:00:00.000Z".into();
        let initiator_binding = Binding {
            binding_id: Uuid::parse_str("ef64e442-52df-4b9f-97cc-fbe366911957").unwrap(),
            device_id: Uuid::parse_str("343eb618-7eba-4475-b880-966b55e40025").unwrap(),
            app_instance_id: Uuid::parse_str("11197e10-4c15-4c8a-af35-8361ed360f1c").unwrap(),
            tag: "tui-test".into(),
            platform: Platform::Mac,
            display_name: None,
            endpoint_id: initiator_endpoint.into(),
            identity_generation: 1,
            pairing_enabled: true,
            capabilities: Vec::new(),
            path_hints: Vec::new(),
            last_seen_at: "2026-08-04T09:00:00.000Z".into(),
        };
        let snapshot = DiscoverySnapshot {
            route_contract_version: 1,
            revision: 5,
            bindings: vec![initiator_binding, published],
            relay_fleet: vec![
                "https://b.relay.example.com/".into(),
                "https://a.relay.example.com/".into(),
            ],
            lan_rendezvous: serde_json::json!({}),
            grant_verification_keys: key_set(&signing),
        };
        // Same fleet membership in a different order than the installed policy.
        let installed = vec![
            "https://a.relay.example.com/".to_string(),
            "https://b.relay.example.com/".to_string(),
        ];
        verify_server_admission(&compact, initiator_endpoint, &local, &snapshot, &installed, 1_100)
            .unwrap();
        // A genuine identity change must still be rejected as stale.
        let mut rekeyed_snapshot = snapshot;
        rekeyed_snapshot.bindings[1].identity_generation = 2;
        assert!(
            verify_server_admission(
                &compact,
                initiator_endpoint,
                &local,
                &rekeyed_snapshot,
                &installed,
                1_100,
            )
            .is_err()
        );
    }

    #[test]
    fn preflight_binds_tls_peer_and_local_acceptor_without_discovery() {
        let signing = SigningKey::from_bytes(&[6; 32]);
        let initiator = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let compact = signed_grant(&signing, initiator, CMUX_TUI_ALPN_TEXT);
        let local = Binding {
            binding_id: Uuid::parse_str("cb7204f4-0416-4cd1-b8e9-cdff433fcd93").unwrap(),
            device_id: Uuid::parse_str("de4643b5-a926-4c1a-9b5c-03fa069ac9d0").unwrap(),
            app_instance_id: Uuid::parse_str("94197e10-4c15-4c8a-af35-8361ed360f1c").unwrap(),
            tag: "tui-test".into(),
            platform: Platform::Linux,
            display_name: None,
            endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into(),
            identity_generation: 1,
            pairing_enabled: true,
            capabilities: vec![CMUX_TUI_PAIR_SCOPE.into()],
            path_hints: Vec::new(),
            last_seen_at: "2026-08-03T00:00:00.000Z".into(),
        };
        assert!(
            verify_server_preflight(&compact, initiator, &local, &key_set(&signing), 1_100).is_ok()
        );
        assert!(
            verify_server_preflight(
                &compact,
                "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                &local,
                &key_set(&signing),
                1_100,
            )
            .is_err()
        );
    }
}
