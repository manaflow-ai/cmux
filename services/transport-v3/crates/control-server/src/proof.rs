//! Domain-separated proof of device-key possession. Nonces are consumed atomically in Postgres.
use crate::Error;
use ed25519_dalek::{Signature, VerifyingKey};
use libp2p_identity::{ed25519, PeerId, PublicKey};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Proof {
    pub public_key: String,
    pub nonce: Uuid,
    pub issued_at: u64,
    pub signature: String,
}
impl Proof {
    pub fn message<T: Serialize>(
        &self,
        audience: &str,
        user: &str,
        path: &str,
        payload: &T,
    ) -> Result<Vec<u8>, Error> {
        // Typed JSON avoids delimiter ambiguity. Sort object keys recursively so
        // Swift/Foundation and Rust agree on one canonical proof representation.
        let payload = canonical_json(serde_json::to_value(payload).map_err(|_| Error::Invalid)?);
        serde_json::to_vec(&(
            "cmux-v3-device-proof",
            audience,
            user,
            "POST",
            path,
            self.nonce,
            self.issued_at,
            payload,
        ))
        .map_err(|_| Error::Invalid)
    }

    pub fn verify<T: Serialize>(
        &self,
        audience: &str,
        user: &str,
        path: &str,
        payload: &T,
        now: u64,
    ) -> Result<PeerId, Error> {
        if self.issued_at > now
            || now - self.issued_at > 60
            || self.nonce.is_nil()
            || self.public_key.len() != 64
            || self.signature.len() != 128
        {
            return Err(Error::Unauthorized);
        }
        let bytes: [u8; 32] = hex::decode(&self.public_key)
            .map_err(|_| Error::Unauthorized)?
            .try_into()
            .map_err(|_| Error::Unauthorized)?;
        let key = VerifyingKey::from_bytes(&bytes).map_err(|_| Error::Unauthorized)?;
        let sig =
            Signature::from_slice(&hex::decode(&self.signature).map_err(|_| Error::Unauthorized)?)
                .map_err(|_| Error::Unauthorized)?;
        key.verify_strict(&self.message(audience, user, path, payload)?, &sig)
            .map_err(|_| Error::Unauthorized)?;
        let key = ed25519::PublicKey::try_from_bytes(&bytes).map_err(|_| Error::Unauthorized)?;
        Ok(PublicKey::from(key).to_peer_id())
    }
}

fn canonical_json(value: Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut entries: Vec<_> = object.into_iter().collect();
            entries.sort_by(|left, right| left.0.cmp(&right.0));
            let mut sorted = Map::new();
            for (key, value) in entries {
                sorted.insert(key, canonical_json(value));
            }
            Value::Object(sorted)
        }
        Value::Array(values) => Value::Array(values.into_iter().map(canonical_json).collect()),
        other => other,
    }
}
