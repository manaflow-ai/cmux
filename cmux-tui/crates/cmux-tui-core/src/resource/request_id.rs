//! Request ids and idempotency keys of `cmux.protocol/2` requests (moved out of resource.rs).

use serde::{Deserialize, Serialize};

use super::{MAX_IDEMPOTENCY_KEY_BYTES, ResourceError};

pub fn validate_idempotency_key(value: &str) -> Result<(), ResourceError> {
    if value.trim().is_empty() {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must contain at least one non-whitespace Unicode scalar",
        ));
    }
    if value.len() > MAX_IDEMPOTENCY_KEY_BYTES {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must contain 1 to 128 UTF-8 bytes",
        ));
    }
    if value.chars().any(char::is_control) {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must not contain Unicode control characters",
        ));
    }
    Ok(())
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct RequestId(String);

impl RequestId {
    pub const MAX_BYTES: usize = 128;

    pub fn parse(value: impl Into<String>) -> Result<Self, ResourceError> {
        let value = value.into();
        if value.is_empty() || value.len() > Self::MAX_BYTES {
            return Err(ResourceError::validation_invalid(
                Some("id"),
                "request id must contain 1 to 128 UTF-8 bytes",
            ));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for RequestId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}
