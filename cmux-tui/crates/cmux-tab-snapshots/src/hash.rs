//! Blob identity (sha256 of the bytes) and the blob mime id.

use serde::de::{self, Deserializer};
use serde::{Deserialize, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::fmt;

/// The sha256 of a blob's bytes. Hex in JSON, 32 raw bytes in a blob frame.
/// The phone treats it as opaque.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct BlobHash(pub [u8; 32]);

impl BlobHash {
    /// Hashes `bytes`.
    pub fn of(bytes: &[u8]) -> Self {
        Self(Sha256::digest(bytes).into())
    }

    /// Lowercase hex, 64 characters.
    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }

    /// Parses 64 hex characters (either case). Anything else is `None`.
    pub fn from_hex(text: &str) -> Option<Self> {
        let mut out = [0u8; 32];
        hex::decode_to_slice(text, &mut out).ok()?;
        Some(Self(out))
    }
}

impl fmt::Debug for BlobHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let hex = self.to_hex();
        write!(f, "BlobHash({})", hex.get(..12).unwrap_or(&hex))
    }
}

impl fmt::Display for BlobHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_hex())
    }
}

impl Serialize for BlobHash {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_hex())
    }
}

impl<'de> Deserialize<'de> for BlobHash {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Self::from_hex(&text).ok_or_else(|| de::Error::custom("hash is not 64 hex characters"))
    }
}

/// The blob mime id carried in the blob frame and in a row's `thumbMime`.
/// An id this build does not know decodes to [`Mime::Unknown`]; it never
/// fails.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub enum Mime {
    /// Id 0: application/octet-stream.
    #[default]
    OctetStream,
    /// Id 1: image/jpeg.
    Jpeg,
    /// Id 2: image/png.
    Png,
    /// Id 3: text/x-cmux-screen, a terminal's screen as UTF-8 text.
    ScreenText,
    /// Any other id. Treated as application/octet-stream.
    Unknown(u8),
}

impl Mime {
    pub fn from_id(id: u8) -> Self {
        match id {
            0 => Self::OctetStream,
            1 => Self::Jpeg,
            2 => Self::Png,
            3 => Self::ScreenText,
            other => Self::Unknown(other),
        }
    }

    pub fn id(self) -> u8 {
        match self {
            Self::OctetStream => 0,
            Self::Jpeg => 1,
            Self::Png => 2,
            Self::ScreenText => 3,
            Self::Unknown(id) => id,
        }
    }

    /// The mime type string. Unknown ids read as application/octet-stream.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Jpeg => "image/jpeg",
            Self::Png => "image/png",
            Self::ScreenText => "text/x-cmux-screen",
            Self::OctetStream | Self::Unknown(_) => "application/octet-stream",
        }
    }

    fn from_str_lossy(text: &str) -> Self {
        match text {
            "image/jpeg" => Self::Jpeg,
            "image/png" => Self::Png,
            "text/x-cmux-screen" => Self::ScreenText,
            _ => Self::OctetStream,
        }
    }
}

/// `thumbMime` is written as the numeric id. A decoder also accepts the mime
/// string, and any other value reads as application/octet-stream.
impl Serialize for Mime {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u8(self.id())
    }
}

impl<'de> Deserialize<'de> for Mime {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let value = serde_json::Value::deserialize(deserializer)?;
        Ok(match value {
            serde_json::Value::Number(n) => n
                .as_u64()
                .and_then(|id| u8::try_from(id).ok())
                .map_or(Self::OctetStream, Self::from_id),
            serde_json::Value::String(s) => Self::from_str_lossy(&s),
            _ => Self::OctetStream,
        })
    }
}
