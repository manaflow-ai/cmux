//! Chunk ids: `BLAKE3(bytes)` for public bytes, `BLAKE3_keyed(key, bytes)` for private ones.

use crate::Result;

/// A chunk's (or a manifest's) id.
pub type Id = [u8; 32];

/// How bytes are named.
#[derive(Clone, PartialEq, Eq)]
pub enum IdScheme {
    /// `BLAKE3(bytes)`: app archives, binaries, web trees, image blocks, CI seeds. Equal bytes
    /// are the same chunk for everyone, which is what dedups them across users and machines.
    Public,
    /// `BLAKE3_keyed(key, bytes)` with a pair or team key (RFD 0142 R7): attachments, history,
    /// session packs. Ids under two keys never match, so a peer that does not hold the key
    /// learns nothing from an id, not even that two users hold the same bytes.
    Keyed([u8; 32]),
}

impl std::fmt::Debug for IdScheme {
    // The key never reaches a log.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Public => f.write_str("Public"),
            Self::Keyed(_) => f.write_str("Keyed(..)"),
        }
    }
}

impl IdScheme {
    /// The id of `bytes`.
    pub fn id(&self, bytes: &[u8]) -> Id {
        match self {
            Self::Public => *blake3::hash(bytes).as_bytes(),
            Self::Keyed(key) => *blake3::keyed_hash(key, bytes).as_bytes(),
        }
    }

    /// The scheme's name in a manifest: `blake3` or `blake3-keyed`.
    pub fn name(&self) -> &'static str {
        match self {
            Self::Public => "blake3",
            Self::Keyed(_) => "blake3-keyed",
        }
    }
}

/// An id as 64 hex digits.
pub fn hex(id: &Id) -> String {
    let mut s = String::with_capacity(64);
    for b in id {
        // A digit under 16 always has a char.
        s.extend(char::from_digit(u32::from(b >> 4), 16));
        s.extend(char::from_digit(u32::from(b & 15), 16));
    }
    s
}

/// The id 64 hex digits name.
pub fn unhex(s: &str) -> Result<Id> {
    let b = s.as_bytes();
    if b.len() != 64 {
        return Err(format!("chunk id {s:?} is not 64 hex digits").into());
    }
    let mut id = [0u8; 32];
    for (slot, [hi, lo]) in id.iter_mut().zip(b.as_chunks::<2>().0) {
        let digit = |c: u8| match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            _ => Err(format!("chunk id {s:?} is not 64 hex digits")),
        };
        *slot = digit(*hi)? << 4 | digit(*lo)?;
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trips() {
        let id = IdScheme::Public.id(b"abc");
        assert_eq!(unhex(&hex(&id)).unwrap(), id);
        assert!(unhex("zz").is_err());
        assert!(unhex(&"G".repeat(64)).is_err());
    }

    #[test]
    fn public_id_is_plain_blake3() {
        assert_eq!(IdScheme::Public.id(b"abc"), *blake3::hash(b"abc").as_bytes());
    }

    #[test]
    fn keyed_ids_are_isolated_per_key() {
        let bytes = b"a screenshot both users happen to hold";
        let alice = IdScheme::Keyed([1; 32]);
        let bob = IdScheme::Keyed([2; 32]);
        let a = alice.id(bytes);
        let b = bob.id(bytes);
        // The same bytes under two keys are two ids, and neither is the public id.
        assert_ne!(a, b);
        assert_ne!(a, IdScheme::Public.id(bytes));
        assert_ne!(b, IdScheme::Public.id(bytes));
        // Under one key, the same bytes are the same id (dedup within a pair or team holds).
        assert_eq!(a, alice.id(bytes));
        // The key stays out of Debug.
        assert_eq!(format!("{alice:?}"), "Keyed(..)");
    }
}
