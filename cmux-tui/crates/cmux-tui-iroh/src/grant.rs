//! Pair-grant JWS verification.
//!
//! The broker signs compact EdDSA JWS grants (`typ: cmux-pair-grant+jwt`)
//! binding both peers' binding id, device id, tag, platform, EndpointID, and
//! identity generation, plus the ALPN and scope. Verification keys arrive only
//! through the authenticated discovery response. A verified grant is the
//! same-account proof: the broker mints grants only for two active bindings
//! of one account.

use anyhow::{Context, bail};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};

pub const TUI_ALPN: &[u8] = b"cmux/tui/1";
pub const TUI_ALPN_STR: &str = "cmux/tui/1";
pub const TUI_SCOPE: &str = "cmux.tui.attach";
pub const GRANT_TYP: &str = "cmux-pair-grant+jwt";
/// Mirrors the broker's clock-skew allowance for `iat`/`nbf`.
const CLOCK_SKEW_SECONDS: i64 = 30;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GrantPeer {
    #[serde(rename = "bindingId")]
    pub binding_id: String,
    #[serde(rename = "deviceId")]
    pub device_id: String,
    pub tag: String,
    pub platform: String,
    #[serde(rename = "endpointId")]
    pub endpoint_id: String,
    #[serde(rename = "identityGeneration")]
    pub identity_generation: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GrantClaims {
    pub jti: String,
    pub iat: i64,
    pub nbf: i64,
    pub exp: i64,
    pub alpn: String,
    pub scope: String,
    pub initiator: GrantPeer,
    pub acceptor: GrantPeer,
}

#[derive(Debug, Deserialize)]
struct GrantHeader {
    alg: String,
    typ: String,
    kid: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VerificationKey {
    pub kid: String,
    pub alg: String,
    pub spki_der_base64: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VerificationKeySet {
    /// Required by the wire shape; presence validates the payload even though
    /// verification only consults `keys`.
    #[allow(dead_code)]
    pub version: u32,
    #[allow(dead_code)]
    pub current_kid: String,
    pub keys: Vec<VerificationKey>,
}

impl VerificationKeySet {
    pub fn from_value(value: &serde_json::Value) -> anyhow::Result<Self> {
        serde_json::from_value(value.clone()).context("parsing grant verification key set")
    }
}

/// Verifies the JWS signature and structural claims, returning the claims.
/// Peer-binding checks against the local endpoint happen in [`check_admission`].
pub fn verify_grant(
    jws: &str,
    keys: &VerificationKeySet,
    now_unix: i64,
) -> anyhow::Result<GrantClaims> {
    if jws.len() > 16 * 1024 {
        bail!("grant exceeds size bound");
    }
    let mut parts = jws.split('.');
    let (Some(header_b64), Some(claims_b64), Some(signature_b64), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        bail!("grant is not a compact JWS");
    };
    let header: GrantHeader =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(header_b64).context("grant header base64")?)
            .context("grant header json")?;
    if header.alg != "EdDSA" {
        bail!("unsupported grant algorithm");
    }
    if header.typ != GRANT_TYP {
        bail!("unexpected grant type");
    }
    let key = keys
        .keys
        .iter()
        .find(|key| key.kid == header.kid && key.alg == "EdDSA")
        .context("grant kid is not in the verification key set")?;
    let spki = base64::engine::general_purpose::STANDARD
        .decode(&key.spki_der_base64)
        .context("verification key base64")?;
    if spki.len() < 32 {
        bail!("verification key SPKI too short");
    }
    let raw: [u8; 32] = spki[spki.len() - 32..].try_into().expect("32-byte slice");
    let verifying = VerifyingKey::from_bytes(&raw).context("verification key bytes")?;
    let signature_bytes =
        URL_SAFE_NO_PAD.decode(signature_b64).context("grant signature base64")?;
    let signature = Signature::from_slice(&signature_bytes).context("grant signature bytes")?;
    let signing_input = format!("{header_b64}.{claims_b64}");
    verifying
        .verify_strict(signing_input.as_bytes(), &signature)
        .context("grant signature verification failed")?;

    let claims: GrantClaims =
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(claims_b64).context("grant claims base64")?)
            .context("grant claims json")?;
    if claims.alpn != TUI_ALPN_STR {
        bail!("grant alpn is not {TUI_ALPN_STR}");
    }
    if claims.scope != TUI_SCOPE {
        bail!("grant scope is not {TUI_SCOPE}");
    }
    if claims.nbf > now_unix + CLOCK_SKEW_SECONDS
        || claims.iat > now_unix + CLOCK_SKEW_SECONDS
        || claims.exp <= now_unix
        || claims.exp <= claims.nbf
    {
        bail!("grant is outside its validity window");
    }
    if claims.initiator.endpoint_id == claims.acceptor.endpoint_id
        || claims.initiator.device_id == claims.acceptor.device_id
        || claims.initiator.binding_id == claims.acceptor.binding_id
    {
        bail!("grant peers are not distinct");
    }
    Ok(claims)
}

/// The local acceptor identity a grant must name exactly.
pub struct AcceptorIdentity<'a> {
    pub device_id: &'a str,
    pub tag: &'a str,
    pub endpoint_id: &'a str,
    pub platform: &'a str,
}

/// Admission check on the accepting side: the grant's acceptor must be this
/// exact endpoint and the TLS-authenticated remote must be the initiator.
pub fn check_admission(
    claims: &GrantClaims,
    local: &AcceptorIdentity<'_>,
    tls_remote_endpoint_id: &str,
) -> anyhow::Result<()> {
    if claims.acceptor.endpoint_id != local.endpoint_id {
        bail!("grant acceptor endpoint does not match this endpoint");
    }
    if claims.acceptor.device_id != local.device_id {
        bail!("grant acceptor device does not match this device");
    }
    if claims.acceptor.tag != local.tag {
        bail!("grant acceptor tag does not match this device");
    }
    if claims.acceptor.platform != local.platform {
        bail!("grant acceptor platform does not match this device");
    }
    if claims.initiator.endpoint_id != tls_remote_endpoint_id {
        bail!("grant initiator does not match the connecting endpoint");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn key_set(signing: &SigningKey, kid: &str) -> VerificationKeySet {
        // Minimal SPKI: fixed 12-byte Ed25519 header + raw key.
        let mut spki = vec![0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
        spki.extend_from_slice(signing.verifying_key().as_bytes());
        VerificationKeySet {
            version: 1,
            current_kid: kid.to_string(),
            keys: vec![VerificationKey {
                kid: kid.to_string(),
                alg: "EdDSA".to_string(),
                spki_der_base64: base64::engine::general_purpose::STANDARD.encode(spki),
            }],
        }
    }

    fn signed_grant(signing: &SigningKey, kid: &str, claims: &GrantClaims) -> String {
        let header = serde_json::json!({"alg": "EdDSA", "typ": GRANT_TYP, "kid": kid});
        let header_b64 = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap());
        let claims_b64 = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap());
        let signing_input = format!("{header_b64}.{claims_b64}");
        let signature = signing.sign(signing_input.as_bytes());
        format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(signature.to_bytes()))
    }

    fn peer(seed: u8, platform: &str) -> GrantPeer {
        GrantPeer {
            binding_id: format!("binding-{seed}"),
            device_id: format!("device-{seed}"),
            tag: format!("tag-{seed}"),
            platform: platform.to_string(),
            endpoint_id: format!("{seed:02x}").repeat(32),
            identity_generation: 1,
        }
    }

    fn claims(now: i64) -> GrantClaims {
        GrantClaims {
            jti: "3fa07c60-0000-4000-8000-000000000000".to_string(),
            iat: now,
            nbf: now - 5,
            exp: now + 600,
            alpn: TUI_ALPN_STR.to_string(),
            scope: TUI_SCOPE.to_string(),
            initiator: peer(1, "mac"),
            acceptor: peer(2, "linux"),
        }
    }

    #[test]
    fn verifies_and_admits_a_valid_grant() {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let keys = key_set(&signing, "k1");
        let now = 1_700_000_000;
        let grant = signed_grant(&signing, "k1", &claims(now));
        let verified = verify_grant(&grant, &keys, now).unwrap();
        let acceptor = claims(now).acceptor;
        let local = AcceptorIdentity {
            device_id: &acceptor.device_id,
            tag: &acceptor.tag,
            endpoint_id: &acceptor.endpoint_id,
            platform: "linux",
        };
        check_admission(&verified, &local, &verified.initiator.endpoint_id.clone()).unwrap();
    }

    #[test]
    fn rejects_tampered_claims() {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let keys = key_set(&signing, "k1");
        let now = 1_700_000_000;
        let grant = signed_grant(&signing, "k1", &claims(now));
        let mut parts: Vec<&str> = grant.split('.').collect();
        let mut forged = claims(now);
        forged.acceptor.device_id = "device-evil".to_string();
        let forged_b64 = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&forged).unwrap());
        parts[1] = &forged_b64;
        let tampered = parts.join(".");
        assert!(verify_grant(&tampered, &keys, now).is_err());
    }

    #[test]
    fn rejects_expired_and_wrong_alpn_grants() {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let keys = key_set(&signing, "k1");
        let now = 1_700_000_000;
        let mut expired = claims(now);
        expired.exp = now - 1;
        let grant = signed_grant(&signing, "k1", &expired);
        assert!(verify_grant(&grant, &keys, now).is_err());

        let mut wrong_alpn = claims(now);
        wrong_alpn.alpn = "cmux/mobile/1".to_string();
        let grant = signed_grant(&signing, "k1", &wrong_alpn);
        assert!(verify_grant(&grant, &keys, now).is_err());
    }

    #[test]
    fn rejects_unknown_kid_and_wrong_key() {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let other = SigningKey::from_bytes(&[9u8; 32]);
        let now = 1_700_000_000;
        let grant = signed_grant(&signing, "k1", &claims(now));
        assert!(verify_grant(&grant, &key_set(&signing, "k2"), now).is_err());
        assert!(verify_grant(&grant, &key_set(&other, "k1"), now).is_err());
    }

    #[test]
    fn admission_rejects_a_grant_for_another_acceptor_or_peer() {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let keys = key_set(&signing, "k1");
        let now = 1_700_000_000;
        let grant = signed_grant(&signing, "k1", &claims(now));
        let verified = verify_grant(&grant, &keys, now).unwrap();
        let acceptor = claims(now).acceptor;
        let local = AcceptorIdentity {
            device_id: &acceptor.device_id,
            tag: &acceptor.tag,
            endpoint_id: &acceptor.endpoint_id,
            platform: "linux",
        };
        // TLS peer differs from the grant's initiator: denied.
        assert!(check_admission(&verified, &local, &"ff".repeat(32)).is_err());
        // Grant names a different acceptor device: denied.
        let other = AcceptorIdentity {
            device_id: "device-x",
            tag: &acceptor.tag,
            endpoint_id: &acceptor.endpoint_id,
            platform: "linux",
        };
        assert!(check_admission(&verified, &other, &verified.initiator.endpoint_id).is_err());
    }
}
