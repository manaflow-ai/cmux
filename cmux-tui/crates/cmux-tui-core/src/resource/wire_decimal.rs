//! An unsigned 64-bit integer that travels as a decimal string, so JSON
//! readers without 64-bit integers keep its exact value.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct WireDecimal(u64);

impl WireDecimal {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn get(self) -> u64 {
        self.0
    }

    /// The value of its wire text: decimal digits with no sign and no leading zero, at most
    /// `u64::MAX`. `None` for any other text.
    pub fn parse(text: &str) -> Option<Self> {
        if text.len() > 20 || text.starts_with('+') || (text.starts_with('0') && text.len() != 1) {
            return None;
        }
        text.parse::<u64>().ok().map(Self)
    }
}

impl Serialize for WireDecimal {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.0.to_string())
    }
}

impl<'de> Deserialize<'de> for WireDecimal {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::parse(&value)
            .ok_or_else(|| serde::de::Error::custom("invalid unsigned decimal string"))
    }
}
