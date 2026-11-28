//! The signed config ring (cmuxterm-hq docs/rfd/0224-one-update-system.md, "Hot patches"):
//! one file per ring, this crate's envelope around a payload with purpose [`PURPOSE`], that
//! sets feature flags without a new build. Flipping a flag here is the default fix for a bad
//! feature, so a reader must never take a file that turns an old flag state back on:
//!
//! ```json
//! {"schema": 1, "purpose": "cmux-config-ring", "ring": "lane-vms", "seq": 7,
//!  "issued_at": 1795341681, "expires_at": 1797936518,
//!  "flags": {"chat.fast_resume": false, "update.rollout_pct": 25, "web.banner": "…"}}
//! ```
//!
//! [`verify`] opens the envelope with the caller's trusted keys before it reads a field
//! ([`trusted_keys`] for the shipped key), then holds the file to the reader: the ring must be
//! the one the reader asked for, the file must not have expired, and `seq` must not be lower than
//! the last one the reader applied, so a replayed older file (one that turned a flag back on) is
//! refused even though its signature is good. An equal `seq` is the same file fetched again.
//!
//! A flag's value is a JSON scalar (bool, number or string): a flag is a switch or a setting,
//! never a document. Names are lower case `[a-z0-9._-]`, at most [`MAX_NAME`] bytes, so a ring
//! cannot carry a name no reader could have asked for.

use std::collections::BTreeMap;

use base64::Engine as _;
use serde::Deserialize;
use serde_json::Value;

use crate::Key;

/// The payload's `purpose`: no other signed file says it, so none stands in for a ring.
pub const PURPOSE: &str = "cmux-config-ring";
/// The payload schema this reader knows.
pub const PAYLOAD_SCHEMA: u64 = 1;
/// A ring file is a few kilobytes.
pub const MAX_RING_BYTES: usize = 64 * 1024;
/// More flags than this is a mistake, not a config.
pub const MAX_FLAGS: usize = 512;
/// The longest flag or ring name.
pub const MAX_NAME: usize = 64;
/// The longest string value.
pub const MAX_STRING: usize = 1024;

/// The keys a ring file may be signed with: `(id, base64 raw ed25519 key)`. It starts as the
/// web update key, as the Linux release file does (the test `keys_are_the_web_update_keys` keeps
/// them equal). To rotate, add the next key here and ship it before CI signs with it.
pub const KEYS: &[(&str, &str)] =
    &[("e5d7bbcacc70703d", "uroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY=")];

/// [`KEYS`], decoded.
pub fn trusted_keys() -> Vec<Key> {
    KEYS.iter()
        .filter_map(|(id, b64)| {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            let raw: [u8; 32] = raw.try_into().ok()?;
            Some(((*id).to_owned(), raw))
        })
        .collect()
}

/// A flag's value.
#[derive(Clone, Debug, PartialEq)]
pub enum FlagValue {
    Bool(bool),
    Number(f64),
    String(String),
}

/// A verified ring: what a reader applies, and the `seq` it records as applied.
#[derive(Clone, Debug, PartialEq)]
pub struct Ring {
    pub ring: String,
    pub seq: u64,
    pub issued_at: u64,
    pub expires_at: u64,
    pub flags: BTreeMap<String, FlagValue>,
}

impl Ring {
    /// The flag `name` when it is a bool; `None` when absent or another kind, so the caller's
    /// built-in default holds.
    pub fn bool(&self, name: &str) -> Option<bool> {
        match self.flags.get(name)? {
            FlagValue::Bool(value) => Some(*value),
            _ => None,
        }
    }

    /// The flag `name` when it is a number.
    pub fn number(&self, name: &str) -> Option<f64> {
        match self.flags.get(name)? {
            FlagValue::Number(value) => Some(*value),
            _ => None,
        }
    }

    /// The flag `name` when it is a string.
    pub fn string(&self, name: &str) -> Option<&str> {
        match self.flags.get(name)? {
            FlagValue::String(value) => Some(value),
            _ => None,
        }
    }
}

#[derive(Deserialize)]
struct Payload {
    schema: u64,
    purpose: String,
    ring: String,
    seq: u64,
    issued_at: u64,
    expires_at: u64,
    flags: BTreeMap<String, Value>,
}

/// A ring or flag name a reader could ask for.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
}

/// The ring in `body` when a `keys` signature covers it and it is `ring`'s, unexpired at `now`
/// (unix seconds) and not older than `last_seq` (the reader's last applied, `None` before its
/// first); else why not.
pub fn verify(
    body: &[u8],
    keys: &[Key],
    ring: &str,
    now: u64,
    last_seq: Option<u64>,
) -> Result<Ring, String> {
    if body.len() > MAX_RING_BYTES {
        return Err(format!("the ring file is {} bytes, over {MAX_RING_BYTES}", body.len()));
    }
    let bytes = crate::open(body, keys)?;
    let payload: Payload = serde_json::from_slice(&bytes)
        .map_err(|err| format!("the ring payload is not a ring: {err}"))?;
    if payload.purpose != PURPOSE {
        return Err(format!("the payload's purpose is {:?}, not {PURPOSE:?}", payload.purpose));
    }
    if payload.schema != PAYLOAD_SCHEMA {
        return Err(format!("unknown ring payload schema {}", payload.schema));
    }
    if payload.ring != ring {
        return Err(format!("the file is ring {:?}, not {ring:?}", payload.ring));
    }
    if payload.issued_at > payload.expires_at {
        return Err("the ring expires before it was issued".to_owned());
    }
    if now >= payload.expires_at {
        return Err(format!("the ring expired at {} (now {now})", payload.expires_at));
    }
    if let Some(last) = last_seq
        && payload.seq < last
    {
        return Err(format!(
            "the ring's seq {} is older than the applied {last}: a replayed file is refused",
            payload.seq
        ));
    }
    if payload.flags.len() > MAX_FLAGS {
        return Err(format!("the ring has {} flags, over {MAX_FLAGS}", payload.flags.len()));
    }
    let mut flags = BTreeMap::new();
    for (name, value) in payload.flags {
        if !valid_name(&name) {
            return Err(format!("flag name {name:?} is not [a-z0-9._-] of at most {MAX_NAME}"));
        }
        let value = match value {
            Value::Bool(value) => FlagValue::Bool(value),
            Value::Number(number) => FlagValue::Number(
                number
                    .as_f64()
                    .ok_or_else(|| format!("flag {name}: the number is out of range"))?,
            ),
            Value::String(text) if text.len() <= MAX_STRING => FlagValue::String(text),
            Value::String(_) => {
                return Err(format!("flag {name}: the string is over {MAX_STRING} bytes"));
            }
            _ => return Err(format!("flag {name}: the value is not a bool, number or string")),
        };
        flags.insert(name, value);
    }
    Ok(Ring {
        ring: payload.ring,
        seq: payload.seq,
        issued_at: payload.issued_at,
        expires_at: payload.expires_at,
        flags,
    })
}

#[cfg(test)]
#[path = "config_ring_tests.rs"]
mod tests;
