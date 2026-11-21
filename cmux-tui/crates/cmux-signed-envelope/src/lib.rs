//! cmux's signed envelope, around exact payload bytes so nothing is canonicalized twice:
//!
//! ```json
//! {"schema": 1, "payload": "<base64 payload JSON>", "signatures": [{"key_id": "…", "sig": "<base64>"}]}
//! ```
//!
//! `scripts/cmux-next/web-ota-pointer.py sign` writes it; [`open`] checks an ed25519 signature
//! by one of the caller's trusted keys over the payload bytes before any payload field is
//! read. Every kind of signed file (the web update pointer, the Cloud machine channel, the
//! Mac live update file, a store package's `STORE.sig`) opens here and then checks its own
//! payload `purpose`; each kind passes only its own keys, so a file signed with one kind's
//! key never opens as another kind.

use base64::Engine as _;
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::Deserialize;
use sha2::{Digest as _, Sha256};

/// The envelope schema [`open`] reads.
pub const SCHEMA: u64 = 1;

/// A trusted key: its id (the first 16 hex digits of the SHA-256 of the raw key) and the raw
/// 32-byte ed25519 public key.
pub type Key = (String, [u8; 32]);

#[derive(Deserialize)]
struct Envelope {
    schema: u64,
    payload: String,
    signatures: Vec<Signature>,
}

#[derive(Deserialize)]
struct Signature {
    key_id: String,
    sig: String,
}

/// The exact payload bytes of the envelope `body` when a `keys` signature covers them; else
/// why not.
pub fn open(body: &[u8], keys: &[Key]) -> Result<Vec<u8>, String> {
    let envelope: Envelope =
        serde_json::from_slice(body).map_err(|_| "the channel file is not an envelope")?;
    if envelope.schema != SCHEMA {
        return Err(format!("unknown envelope schema {}", envelope.schema));
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let payload = b64.decode(&envelope.payload).map_err(|_| "the payload is not base64")?;
    let signed = envelope.signatures.iter().any(|signature| {
        let Some((_, key)) = keys.iter().find(|(id, _)| *id == signature.key_id) else {
            return false;
        };
        let Ok(sig) = b64.decode(&signature.sig) else { return false };
        UnparsedPublicKey::new(&ED25519, key).verify(&payload, &sig).is_ok()
    });
    if !signed {
        return Err("no valid signature by a trusted key".to_owned());
    }
    Ok(payload)
}

/// The id of the raw ed25519 public key `raw`: the first 16 hex digits of its SHA-256, as
/// web-ota-pointer.py names keys.
pub fn key_id(raw: &[u8; 32]) -> String {
    Sha256::digest(raw).iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// The keys of a keys file (`{"keys": [{"id": "…", "ed25519": "<base64 raw key>"}]}`, the
/// format web-ota-pointer.py `--keys` reads). An entry that is not a 32-byte key or whose id
/// is not its [`key_id`] is left out, so no key is trusted under another key's id.
pub fn keys_from_json(json: &str) -> Vec<Key> {
    #[derive(Deserialize)]
    struct File {
        #[serde(default)]
        keys: Vec<Entry>,
    }
    #[derive(Deserialize)]
    struct Entry {
        id: String,
        ed25519: String,
    }
    let Ok(file) = serde_json::from_str::<File>(json) else { return Vec::new() };
    file.keys
        .into_iter()
        .filter_map(|entry| {
            let raw = base64::engine::general_purpose::STANDARD.decode(&entry.ed25519).ok()?;
            let raw: [u8; 32] = raw.try_into().ok()?;
            (key_id(&raw) == entry.id).then_some((entry.id, raw))
        })
        .collect()
}
