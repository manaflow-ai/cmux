//! Chunk and tree ids: `BLAKE3(bytes)` for public artifacts, `BLAKE3_keyed(key, bytes)` for
//! private data (RFD 0142 R7), as 64 lowercase hex digits on the wire.

use crate::Result;
use std::fmt;

/// A chunk's or a manifest's id.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Id(pub [u8; 32]);

impl Id {
    /// The public id of `bytes`.
    pub fn of(bytes: &[u8]) -> Self {
        Self(*blake3::hash(bytes).as_bytes())
    }

    /// The private id of `bytes` under a pair or team `key`: equal bytes under two keys differ.
    pub fn keyed(key: &[u8; 32], bytes: &[u8]) -> Self {
        Self(*blake3::keyed_hash(key, bytes).as_bytes())
    }

    /// The id as 64 hex digits.
    pub fn hex(&self) -> String {
        let mut s = String::with_capacity(64);
        for b in self.0 {
            s.extend(char::from_digit(u32::from(b >> 4), 16));
            s.extend(char::from_digit(u32::from(b & 15), 16));
        }
        s
    }

    /// The id 64 hex digits name.
    pub fn parse(s: &str) -> Result<Self> {
        let b = s.as_bytes();
        if b.len() != 64 {
            return Err(format!("id {s:?} is not 64 hex digits").into());
        }
        let digit = |c: u8| match c {
            b'0'..=b'9' => Ok(c - b'0'),
            b'a'..=b'f' => Ok(c - b'a' + 10),
            _ => Err(format!("id {s:?} is not 64 lowercase hex digits")),
        };
        let mut id = [0u8; 32];
        for (pair, slot) in b.chunks_exact(2).zip(id.iter_mut()) {
            let [hi, lo] = pair else { return Err("incomplete hex pair".into()) };
            *slot = digit(*hi)? << 4 | digit(*lo)?;
        }
        Ok(Self(id))
    }
}

impl fmt::Debug for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hex())
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.hex())
    }
}

impl serde::Serialize for Id {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        s.serialize_str(&self.hex())
    }
}

impl<'de> serde::Deserialize<'de> for Id {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let s = String::deserialize(d)?;
        Self::parse(&s).map_err(serde::de::Error::custom)
    }
}
