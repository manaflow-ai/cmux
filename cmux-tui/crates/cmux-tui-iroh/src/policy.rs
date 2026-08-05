use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use cmux_remote::identity::{read_owner_only_json, write_owner_only_json};
use ed25519_dalek::{Signature, Verifier as _, VerifyingKey};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::broker::validate_root_https_url;

const POLICY_TYP: &str = "cmux-relay-policy-v1+jwt";
const POLICY_AUDIENCE: &str = "cmux-iroh-relay-policy";
const RELAY_PROTOCOL: &str = "iroh-relay-v1";
const MAX_POLICY_BYTES: usize = 64 * 1024;
const MAX_CACHE_BYTES: usize = 96 * 1024;
const MAX_POLICY_LIFETIME_SECONDS: i64 = 7 * 24 * 60 * 60;
const CLOCK_SKEW_SECONDS: i64 = 30;

// Current + next key slots per environment, mirroring the Mac and iOS pins in
// config/IrohRelayPolicy{Production,Staging}.xcconfig (CMUX_IROH_RELAY_POLICY_KEY_ID
// and ..._NEXT_KEY_ID). The broker can rotate to the next kid without a new
// binary; rotating beyond it ships updated pins to every client, TUI included.
const PRODUCTION_KEYS: &[(&str, &str)] = &[
    ("cmux-production-relay-policy-2026-07", "qoBinRqX4TI1Ro6xAuOQxKUkeZT3pkFJuERP/+R+9aw="),
    ("cmux-production-relay-policy-2026-08", "k+FND+WlELCkHs9QnWg1TfTuHXBwyv2907umX+mUOOU="),
];
const STAGING_KEYS: &[(&str, &str)] = &[
    ("cmux-staging-relay-policy-2026-07", "Otx9S0B4d/tlwIKYRf5evJaqhjCltFLPjMfXrLFd6lk="),
    ("cmux-staging-relay-policy-2026-08", "KnOZ6gKmH05Mrfan2tXgwRygBKxcSUue4bp34udiQFA="),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayEnvironment {
    Production,
    Staging,
}

impl std::str::FromStr for RelayEnvironment {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "production" => Ok(Self::Production),
            "staging" => Ok(Self::Staging),
            _ => bail!("relay environment must be production or staging"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedRelay {
    pub id: String,
    pub provider: String,
    pub region: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedRelayPolicy {
    pub jti: Uuid,
    pub sequence: u64,
    pub issued_at: i64,
    pub not_before: i64,
    pub expires_at: i64,
    pub relays: Vec<VerifiedRelay>,
    pub compact: String,
}

impl VerifiedRelayPolicy {
    pub fn relay_urls(&self) -> Vec<String> {
        self.relays.iter().map(|relay| relay.url.clone()).collect()
    }
}

pub struct RelayPolicyVerifier {
    keys: HashMap<String, VerifyingKey>,
    cache_path: PathBuf,
}

impl std::fmt::Debug for RelayPolicyVerifier {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RelayPolicyVerifier")
            .field("key_ids", &self.keys.keys().collect::<Vec<_>>())
            .field("cache_path", &self.cache_path)
            .finish()
    }
}

impl RelayPolicyVerifier {
    pub fn new(environment: RelayEnvironment, state_directory: &Path) -> Result<Self> {
        let source = match environment {
            RelayEnvironment::Production => PRODUCTION_KEYS,
            RelayEnvironment::Staging => STAGING_KEYS,
        };
        let mut keys = HashMap::new();
        for (kid, encoded) in source {
            let bytes = STANDARD.decode(encoded).context("invalid built-in relay-policy key")?;
            let bytes: [u8; 32] = bytes
                .try_into()
                .map_err(|_| anyhow::anyhow!("invalid built-in relay-policy key length"))?;
            keys.insert((*kid).to_string(), VerifyingKey::from_bytes(&bytes)?);
        }
        Ok(Self { keys, cache_path: state_directory.join("relay-policy.json") })
    }

    #[cfg(test)]
    fn with_keys(keys: HashMap<String, VerifyingKey>, cache_path: PathBuf) -> Self {
        Self { keys, cache_path }
    }

    pub fn verify(&self, compact: &str, now: i64) -> Result<VerifiedRelayPolicy> {
        ensure!((5..=MAX_POLICY_BYTES).contains(&compact.len()), "relay policy size is invalid");
        ensure!(
            !compact.bytes().any(|byte| byte.is_ascii_whitespace()),
            "relay policy has whitespace"
        );
        let mut segments = compact.split('.');
        let encoded_header = segments.next().context("relay policy has no header")?;
        let encoded_claims = segments.next().context("relay policy has no claims")?;
        let encoded_signature = segments.next().context("relay policy has no signature")?;
        ensure!(segments.next().is_none(), "relay policy is not a compact JWS");
        let header_bytes = canonical_decode(encoded_header, 4 * 1024)?;
        let claims_bytes = canonical_decode(encoded_claims, MAX_POLICY_BYTES)?;
        let signature_bytes = canonical_decode(encoded_signature, 64)?;
        ensure!(signature_bytes.len() == 64, "relay policy signature length is invalid");
        let header: PolicyHeader =
            serde_json::from_slice(&header_bytes).context("relay policy header is invalid")?;
        ensure!(header.alg == "EdDSA", "relay policy algorithm is invalid");
        ensure!(header.typ == POLICY_TYP, "relay policy type is invalid");
        ensure!(safe_key_id(&header.kid), "relay policy key ID is invalid");
        let key = self.keys.get(&header.kid).context("relay policy key is not pinned")?;
        let signature = Signature::from_slice(&signature_bytes)
            .map_err(|_| anyhow::anyhow!("relay policy signature is invalid"))?;
        let signing_input = format!("{encoded_header}.{encoded_claims}");
        key.verify(signing_input.as_bytes(), &signature)
            .map_err(|_| anyhow::anyhow!("relay policy signature is invalid"))?;

        let claims: PolicyClaims =
            serde_json::from_slice(&claims_bytes).context("relay policy claims are invalid")?;
        let policy = validate_claims(claims, compact, now)?;
        self.check_rollback_fence(&policy)?;
        Ok(policy)
    }

    pub fn record(&self, policy: &VerifiedRelayPolicy) -> Result<()> {
        self.check_rollback_fence(policy)?;
        write_owner_only_json(
            &self.cache_path,
            &CachedPolicy {
                version: 1,
                sequence: policy.sequence,
                issued_at: policy.issued_at,
                expires_at: policy.expires_at,
                relays: policy.relays.iter().map(CachedRelay::from).collect(),
                compact: policy.compact.clone(),
            },
        )
        .context("cannot persist verified relay policy")?;
        Ok(())
    }

    pub fn verify_and_record(&self, compact: &str, now: i64) -> Result<VerifiedRelayPolicy> {
        let policy = self.verify(compact, now)?;
        self.record(&policy)?;
        Ok(policy)
    }

    fn check_rollback_fence(&self, policy: &VerifiedRelayPolicy) -> Result<()> {
        if let Some(previous) = self.load_cache()? {
            ensure!(policy.sequence >= previous.sequence, "relay policy sequence rolled back");
            if policy.sequence == previous.sequence {
                ensure!(
                    policy.relays.iter().map(CachedRelay::from).collect::<Vec<_>>()
                        == previous.relays,
                    "relay policy changed the catalog without advancing its sequence"
                );
                ensure!(
                    policy.issued_at >= previous.issued_at,
                    "relay policy issuance rolled back"
                );
                ensure!(
                    policy.expires_at >= previous.expires_at,
                    "relay policy expiry rolled back"
                );
            }
        }
        Ok(())
    }

    fn load_cache(&self) -> Result<Option<CachedPolicy>> {
        if !self.cache_path.exists() {
            return Ok(None);
        }
        let cache: CachedPolicy = read_owner_only_json(&self.cache_path, MAX_CACHE_BYTES)
            .context("cannot load relay-policy rollback fence")?;
        ensure!(cache.version == 1 && cache.sequence > 0, "relay-policy cache is invalid");
        ensure!(
            cache.issued_at >= 0 && cache.expires_at > cache.issued_at,
            "relay-policy cache times are invalid"
        );
        ensure!((1..=16).contains(&cache.relays.len()), "relay-policy cache fleet is invalid");
        let mut ids = HashSet::new();
        let mut urls = HashSet::new();
        for relay in &cache.relays {
            ensure!(safe_relay_id(&relay.id), "cached relay ID is invalid");
            ensure!(safe_relay_label(&relay.provider), "cached relay provider is invalid");
            ensure!(safe_relay_label(&relay.region), "cached relay region is invalid");
            validate_root_https_url(&relay.url)?;
            ensure!(ids.insert(&relay.id), "cached relay ID is duplicated");
            ensure!(urls.insert(&relay.url), "cached relay URL is duplicated");
        }
        ensure!(cache.compact.len() <= MAX_POLICY_BYTES, "relay-policy cache is too large");
        Ok(Some(cache))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PolicyHeader {
    alg: String,
    typ: String,
    kid: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PolicyClaims {
    version: u32,
    jti: String,
    sequence: u64,
    iat: i64,
    nbf: i64,
    exp: i64,
    aud: String,
    relay_protocol: String,
    relays: Vec<RelayClaim>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RelayClaim {
    id: String,
    provider: String,
    region: String,
    url: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CachedPolicy {
    version: u32,
    sequence: u64,
    issued_at: i64,
    expires_at: i64,
    relays: Vec<CachedRelay>,
    compact: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct CachedRelay {
    id: String,
    provider: String,
    region: String,
    url: String,
}

impl From<&VerifiedRelay> for CachedRelay {
    fn from(relay: &VerifiedRelay) -> Self {
        Self {
            id: relay.id.clone(),
            provider: relay.provider.clone(),
            region: relay.region.clone(),
            url: relay.url.clone(),
        }
    }
}

fn validate_claims(claims: PolicyClaims, compact: &str, now: i64) -> Result<VerifiedRelayPolicy> {
    ensure!(claims.version == 1, "unsupported relay policy version");
    let jti = Uuid::parse_str(&claims.jti).context("relay policy JTI is invalid")?;
    ensure!(jti.to_string() == claims.jti, "relay policy JTI is not canonical");
    ensure!(claims.sequence > 0, "relay policy sequence is invalid");
    ensure!(claims.aud == POLICY_AUDIENCE, "relay policy audience is invalid");
    ensure!(claims.relay_protocol == RELAY_PROTOCOL, "relay policy protocol is invalid");
    ensure!(claims.iat <= claims.nbf + CLOCK_SKEW_SECONDS, "relay policy times are invalid");
    ensure!(claims.iat <= claims.exp, "relay policy times are invalid");
    ensure!(claims.nbf <= claims.exp, "relay policy times are invalid");
    ensure!(
        claims.exp - claims.iat <= MAX_POLICY_LIFETIME_SECONDS,
        "relay policy lifetime is too long"
    );
    ensure!(now + CLOCK_SKEW_SECONDS >= claims.nbf, "relay policy is not active");
    ensure!(now - CLOCK_SKEW_SECONDS < claims.exp, "relay policy expired");
    ensure!((1..=16).contains(&claims.relays.len()), "relay policy fleet size is invalid");
    let mut ids = HashSet::new();
    let mut urls = HashSet::new();
    let mut relays = Vec::with_capacity(claims.relays.len());
    for relay in claims.relays {
        ensure!(safe_relay_id(&relay.id), "relay ID is invalid");
        ensure!(safe_relay_label(&relay.provider), "relay provider is invalid");
        ensure!(safe_relay_label(&relay.region), "relay region is invalid");
        validate_root_https_url(&relay.url)?;
        ensure!(ids.insert(relay.id.clone()), "duplicate relay ID");
        ensure!(urls.insert(relay.url.clone()), "duplicate relay URL");
        relays.push(VerifiedRelay {
            id: relay.id,
            provider: relay.provider,
            region: relay.region,
            url: relay.url,
        });
    }
    Ok(VerifiedRelayPolicy {
        jti,
        sequence: claims.sequence,
        issued_at: claims.iat,
        not_before: claims.nbf,
        expires_at: claims.exp,
        relays,
        compact: compact.to_string(),
    })
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

fn safe_key_id(value: &str) -> bool {
    bounded_ascii_label(value, 64, |byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_')
    })
}

fn safe_relay_id(value: &str) -> bool {
    bounded_ascii_label(value, 64, |byte| {
        byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'.' | b'_')
    })
}

fn safe_relay_label(value: &str) -> bool {
    bounded_ascii_label(value, 80, |byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b' ' | b'-' | b'.' | b'_')
    })
}

fn bounded_ascii_label(value: &str, maximum_bytes: usize, allowed: impl Fn(u8) -> bool) -> bool {
    let bytes = value.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= maximum_bytes
        && bytes[0].is_ascii_alphanumeric()
        && bytes[bytes.len() - 1].is_ascii_alphanumeric()
        && bytes.iter().copied().all(allowed)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use ed25519_dalek::{Signer as _, SigningKey};
    use serde_json::json;

    use super::*;

    fn compact(signing: &SigningKey, sequence: u64, exp: i64, url: &str) -> String {
        let header = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&json!({
                "alg": "EdDSA",
                "typ": POLICY_TYP,
                "kid": "test-key"
            }))
            .unwrap(),
        );
        let claims = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&json!({
                "version": 1,
                "jti": "8e671cec-b7f5-4e31-a931-506021a868a2",
                "sequence": sequence,
                "iat": 1_000,
                "nbf": 1_000,
                "exp": exp,
                "aud": POLICY_AUDIENCE,
                "relay_protocol": RELAY_PROTOCOL,
                "relays": [{
                    "id": "test",
                    "provider": "cmux",
                    "region": "US Central",
                    "url": url
                }]
            }))
            .unwrap(),
        );
        let input = format!("{header}.{claims}");
        let signature = URL_SAFE_NO_PAD.encode(signing.sign(input.as_bytes()).to_bytes());
        format!("{input}.{signature}")
    }

    #[test]
    fn verifies_policy_and_rejects_sequence_rollback() {
        let temp = tempfile::tempdir().unwrap();
        let signing = SigningKey::from_bytes(&[7; 32]);
        let verifier = RelayPolicyVerifier::with_keys(
            HashMap::from([("test-key".into(), signing.verifying_key())]),
            temp.path().join("policy.json"),
        );
        let first = compact(&signing, 2, 2_000, "https://relay.example.com/");
        assert_eq!(verifier.verify_and_record(&first, 1_100).unwrap().sequence, 2);
        let renewal = compact(&signing, 2, 2_100, "https://relay.example.com/");
        assert_eq!(verifier.verify_and_record(&renewal, 1_100).unwrap().sequence, 2);
        let shorter = compact(&signing, 2, 2_050, "https://relay.example.com/");
        assert!(verifier.verify_and_record(&shorter, 1_100).is_err());
        let equivocation = compact(&signing, 2, 2_100, "https://other.example.com/");
        assert!(verifier.verify_and_record(&equivocation, 1_100).is_err());
        let rollback = compact(&signing, 1, 2_000, "https://relay.example.com/");
        assert!(verifier.verify_and_record(&rollback, 1_100).is_err());
    }

    #[test]
    fn rejects_non_root_and_expired_policy() {
        let temp = tempfile::tempdir().unwrap();
        let signing = SigningKey::from_bytes(&[9; 32]);
        let verifier = RelayPolicyVerifier::with_keys(
            HashMap::from([("test-key".into(), signing.verifying_key())]),
            temp.path().join("policy.json"),
        );
        let path = compact(&signing, 1, 2_000, "https://relay.example.com/path");
        assert!(verifier.verify_and_record(&path, 1_100).is_err());
        let expired = compact(&signing, 1, 1_050, "https://relay.example.com/");
        assert!(verifier.verify_and_record(&expired, 1_100).is_err());
    }

    #[test]
    fn relay_metadata_matches_the_broker_catalog_schema() {
        assert!(safe_key_id("cmux-staging-relay-policy-2026-08"));
        assert!(safe_relay_id("usc1"));
        assert!(!safe_relay_id("US Central"));
        assert!(safe_relay_label("Asia Pacific Northeast"));
        assert!(safe_relay_label("a"));
        assert!(!safe_relay_label(" Asia Pacific Northeast"));
        assert!(!safe_relay_label("Asia Pacific Northeast "));
        assert!(!safe_relay_label("Asia/Pacific"));
        assert!(!safe_relay_label(&"a".repeat(81)));
    }
}
