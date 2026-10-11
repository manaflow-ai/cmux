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
        if value.len() > 20
            || value.starts_with('+')
            || (value.starts_with('0') && value.len() != 1)
        {
            return Err(serde::de::Error::custom("invalid unsigned decimal string"));
        }
        value
            .parse::<u64>()
            .map(Self)
            .map_err(|_| serde::de::Error::custom("invalid unsigned decimal string"))
    }
}
