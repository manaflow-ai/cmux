//! The host replica sealed at rest (RFD 0163 backlog row 7, slice 1; off by
//! default). With a seal on the lease, every `state` the publisher sends
//! (the `session` and `chief` snapshots, each event's `effects.state` and
//! each answer to a reader's `snapshot.request`) leaves the Mac as one
//! `cmux-relay-snapshot-v1` envelope per paired viewer key: ECIES on P-256 to
//! the viewer, signed by the host's identity key, bound to the stream and to
//! `(epoch 0, seq)` (the replica's seq never goes back per stream, so the
//! epoch stays 0). HostDO stores the same JSON text it stores today and
//! never holds a key that opens or forges it; `seq`, `stream`, `decided`
//! and the routing fields stay readable, so reads, the tail and the mailbox
//! work unchanged.
//!
//! The sealed `state`:
//!
//! ```json
//! {"sealed": "cmux-relay-snapshot-v1", "source": "<hex key id>",
//!  "to": {"<hex viewer key id>": "<base64 envelope>"}}
//! ```
//!
//! There is no plaintext fallback: a state that does not seal is not sent.
//! [`HostReplicaOptions::require_seal`](super::HostReplicaOptions) (off by
//! default) refuses any lease without a seal. Readers open it in a later
//! slice (the phone's FFI open with a persisted floor); nothing sets a seal
//! yet, so today's frames do not change.

use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_relay_snapshot::{Position, key_id};
use p256::PublicKey;
use p256::ecdsa::SigningKey;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::Driver;
use crate::CloudError;

/// The `sealed` value of a sealed `state`.
pub const SEALED_FORMAT: &str = cmux_relay_snapshot::CONTEXT_DOMAIN;
/// Paired viewers one state is sealed to (each adds about 350 bytes).
pub const MAX_VIEWERS: usize = 16;

/// The `seal` of `cloud-host-replica-set`: the keys of the lease's user.
#[derive(Deserialize)]
pub struct ReplicaSeal {
    /// The host's P-256 identity key: its 32-byte private scalar, base64.
    pub source_key: String,
    /// The owner's paired devices: P-256 public keys (SEC1, X9.63 uncompressed
    /// or compressed), base64. Each gets its own envelope.
    pub viewers: Vec<String>,
}

impl fmt::Debug for ReplicaSeal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ReplicaSeal")
            .field("source_key", &"[redacted]")
            .field("viewers", &self.viewers.len())
            .finish()
    }
}

/// The parsed seal of one lease.
pub(super) struct Sealer {
    source: SigningKey,
    source_id: String,
    viewers: Vec<(String, PublicKey)>,
}

fn bad(message: &str) -> CloudError {
    CloudError::BadRequest(format!("seal: {message}"))
}

impl Sealer {
    pub(super) fn new(seal: ReplicaSeal) -> Result<Self, CloudError> {
        let scalar = Zeroizing::new(
            STANDARD
                .decode(seal.source_key.trim())
                .map_err(|_| bad("source_key must be base64"))?,
        );
        drop(Zeroizing::new(seal.source_key));
        let source = SigningKey::from_slice(&scalar)
            .map_err(|_| bad("source_key must be a 32-byte P-256 private key"))?;
        if seal.viewers.is_empty() || seal.viewers.len() > MAX_VIEWERS {
            return Err(bad(&format!("viewers must hold 1-{MAX_VIEWERS} public keys")));
        }
        let mut viewers: Vec<(String, PublicKey)> = Vec::with_capacity(seal.viewers.len());
        for text in &seal.viewers {
            let bytes =
                STANDARD.decode(text.trim()).map_err(|_| bad("each viewer must be base64"))?;
            let key = PublicKey::from_sec1_bytes(&bytes)
                .map_err(|_| bad("each viewer must be a P-256 public key"))?;
            let id = hex::encode(key_id(&key));
            if !viewers.iter().any(|(have, _)| *have == id) {
                viewers.push((id, key));
            }
        }
        let source_id = hex::encode(key_id(&PublicKey::from(source.verifying_key())));
        Ok(Self { source, source_id, viewers })
    }

    /// `state` of `stream` at `seq` as the sealed value the replica stores.
    pub(super) fn seal(&self, stream: &str, seq: u64, state: &Value) -> Result<Value, String> {
        let plaintext = Zeroizing::new(serde_json::to_vec(state).map_err(|e| e.to_string())?);
        let position = Position { epoch: 0, seq };
        let mut to = Map::new();
        for (id, viewer) in &self.viewers {
            let envelope =
                cmux_relay_snapshot::seal(&self.source, viewer, stream, position, &plaintext)
                    .map_err(|error| format!("seal_failed: {error}"))?;
            to.insert(id.clone(), Value::String(STANDARD.encode(envelope)));
        }
        Ok(json!({ "sealed": SEALED_FORMAT, "source": self.source_id, "to": to }))
    }
}

impl Driver {
    /// `state` as this connection stores it: sealed when the lease has a seal.
    pub(super) fn at_rest(&self, stream: &str, seq: u64, state: Value) -> Result<Value, String> {
        match &self.seal {
            Some(sealer) => sealer.seal(stream, seq, &state),
            None => Ok(state),
        }
    }
}

#[cfg(test)]
#[path = "seal_tests.rs"]
mod tests;
