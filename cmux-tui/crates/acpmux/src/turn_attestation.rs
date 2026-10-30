//! Daemon-owned proof that a caller names the live turn acpmux is running.
//!
//! The sequence is the existing `turn_started` journal sequence (`turnSeq`); this
//! module never allocates a second counter. The key is generated for the daemon
//! launch and its public half is returned for the existing install enrollment to
//! register. Private material stays in the daemon process and is never logged.

use base64::Engine as _;
use ring::{
    rand::SystemRandom,
    signature::{ED25519, Ed25519KeyPair, KeyPair, UnparsedPublicKey},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

const DOMAIN: &[u8] = b"cmux-acpmux-turn-attestation-v1";
const MAX_TTL_MS: u64 = 5 * 60 * 1000;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TurnAttestation {
    pub session_id: String,
    pub turn_seq: u64,
    pub team_install: String,
    pub issued_at: u64,
    pub expiry: u64,
    pub nonce: String,
    pub public_key: String,
    pub signature: String,
}

pub struct TurnAttestor {
    key: Ed25519KeyPair,
}

impl TurnAttestor {
    pub fn generate() -> Self {
        let rng = SystemRandom::new();
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).expect("ed25519 key generation");
        Self { key: Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).expect("ed25519 key parsing") }
    }

    pub fn public_key(&self) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(self.key.public_key().as_ref())
    }

    pub fn issue(
        &self,
        session_id: &str,
        turn_seq: u64,
        team_install: &str,
        issued_at: u64,
        ttl_ms: u64,
    ) -> Result<TurnAttestation, &'static str> {
        if session_id.is_empty() || team_install.is_empty() || ttl_ms == 0 || ttl_ms > MAX_TTL_MS {
            return Err("invalid attestation fields");
        }
        let expiry = issued_at.checked_add(ttl_ms).ok_or("attestation expiry overflow")?;
        let nonce = Uuid::now_v7().to_string();
        let message = signing_bytes(session_id, turn_seq, team_install, issued_at, expiry, &nonce);
        let signature = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(self.key.sign(&message).as_ref());
        Ok(TurnAttestation {
            session_id: session_id.to_owned(),
            turn_seq,
            team_install: team_install.to_owned(),
            issued_at,
            expiry,
            nonce,
            public_key: self.public_key(),
            signature,
        })
    }
}

pub fn verify(attestation: &TurnAttestation, now: u64) -> bool {
    if attestation.session_id.is_empty()
        || attestation.team_install.is_empty()
        || attestation.nonce.is_empty()
        || now < attestation.issued_at
        || now >= attestation.expiry
        || attestation.expiry - attestation.issued_at > MAX_TTL_MS
    {
        return false;
    }
    let Ok(public_key) =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&attestation.public_key)
    else {
        return false;
    };
    let Ok(signature) =
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(&attestation.signature)
    else {
        return false;
    };
    UnparsedPublicKey::new(&ED25519, public_key)
        .verify(
            &signing_bytes(
                &attestation.session_id,
                attestation.turn_seq,
                &attestation.team_install,
                attestation.issued_at,
                attestation.expiry,
                &attestation.nonce,
            ),
            &signature,
        )
        .is_ok()
}

fn signing_bytes(
    session_id: &str,
    turn_seq: u64,
    team_install: &str,
    issued_at: u64,
    expiry: u64,
    nonce: &str,
) -> Vec<u8> {
    serde_json::to_vec(&(DOMAIN, session_id, turn_seq, team_install, issued_at, expiry, nonce))
        .expect("attestation encoding")
}

pub fn request_fields(params: &Value) -> Result<(&str, &str, u64), &'static str> {
    let session = params.get("sessionId").and_then(Value::as_str).ok_or("sessionId is required")?;
    let team_install =
        params.get("teamInstall").and_then(Value::as_str).ok_or("teamInstall is required")?;
    let ttl = params.get("ttlMs").and_then(Value::as_u64).unwrap_or(60_000);
    Ok((session, team_install, ttl))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn issues_and_verifies_only_inside_expiry() {
        let signer = TurnAttestor::generate();
        let proof = signer.issue("s1", 7, "ti1", 1_000, 100).unwrap();
        assert!(verify(&proof, 1_099));
        assert!(!verify(&proof, 1_100));
    }

    #[test]
    fn rejects_other_session_and_replay_nonce_is_not_reissuable() {
        let signer = TurnAttestor::generate();
        let mut proof = signer.issue("s1", 7, "ti1", 1_000, 100).unwrap();
        proof.session_id = "s2".into();
        assert!(!verify(&proof, 1_001));
        proof.session_id = "s1".into();
        assert!(verify(&proof, 1_001));
        let second = signer.issue("s1", 7, "ti1", 1_000, 100).unwrap();
        assert_ne!(proof.nonce, second.nonce);
    }
}
