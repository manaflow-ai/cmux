//! Redacted live-turn proof. The signing key is the completed cmux server enrollment's
//! existing ES256 key, never a new store or a caller-supplied identity. On Unix that
//! store is protected by the OS account (0600), not against unsandboxed same-UID code.

use crate::rpc::RpcError;
use cmux_server::pairing::EnrolledIdentity;
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const DOMAIN: &str = "cmux-acpmux-turn-attestation-v1";
pub const MAX_TTL_MS: u64 = 300_000;
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

// No Debug: a signature/nonce is a short-lived bearer proof, not diagnostic data.
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TurnAttestation {
    pub session_id: String,
    pub turn_seq: u64,
    pub team_install: String,
    pub team: String,
    pub user: String,
    pub issued_at: u64,
    pub expiry: u64,
    pub nonce: String,
    pub signature: String,
}

impl TurnAttestation {
    pub fn signing_bytes(&self) -> Result<Vec<u8>, RpcError> {
        serde_json::to_vec(&(
            DOMAIN,
            &self.session_id,
            self.turn_seq,
            &self.team_install,
            &self.team,
            &self.user,
            self.issued_at,
            self.expiry,
            &self.nonce,
        ))
        .map_err(|_| refused("turn_attestation.encoding"))
    }

    pub(crate) fn issue(
        identity: &EnrolledIdentity,
        session: &str,
        seq: u64,
        now: u64,
        ttl: u64,
    ) -> Result<Self, RpcError> {
        let expiry = now
            .checked_add(ttl)
            .filter(|v| *v <= MAX_SAFE_INTEGER)
            .ok_or_else(|| refused("turn_attestation.invalid"))?;
        if seq == 0 || seq > MAX_SAFE_INTEGER || now == 0 || ttl == 0 || ttl > MAX_TTL_MS {
            return Err(refused("turn_attestation.invalid"));
        }
        let paired = identity.paired();
        let mut proof = Self {
            session_id: session.to_owned(),
            turn_seq: seq,
            team_install: paired.install.clone(),
            team: paired.team.clone(),
            user: paired.user.clone(),
            issued_at: now,
            expiry,
            nonce: crate::pairing::random_secret()?,
            signature: String::new(),
        };
        proof.signature = identity
            .sign(&proof.signing_bytes()?)
            .map_err(|_| refused("turn_attestation.signing_failed"))?;
        Ok(proof)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    pub session_id: String,
    #[serde(default = "default_ttl")]
    pub ttl_ms: u64,
}
fn default_ttl() -> u64 {
    60_000
}

pub(crate) fn request(
    params: &Value,
    caller: Option<&str>,
    local: bool,
) -> Result<Request, RpcError> {
    if !local || caller.is_none() {
        return Err(refused("turn_attestation.caller_required"));
    }
    let ask: Request =
        serde_json::from_value(params.clone()).map_err(|_| refused("turn_attestation.invalid"))?;
    if caller != Some(ask.session_id.as_str()) {
        return Err(refused("turn_attestation.caller_mismatch"));
    }
    if ask.ttl_ms == 0 || ask.ttl_ms > MAX_TTL_MS {
        return Err(refused("turn_attestation.invalid"));
    }
    Ok(ask)
}

pub(crate) fn refused(reason: &str) -> RpcError {
    RpcError::new(-32000, "turn attestation refused")
        .with_data(serde_json::json!({"reason": reason}))
}
