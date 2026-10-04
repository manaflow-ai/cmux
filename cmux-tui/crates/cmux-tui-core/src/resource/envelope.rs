//! The request and response envelopes of `cmux.protocol/2` (moved out of
//! resource.rs, behavior unchanged).

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    EnvelopeType, OperationClass, PROTOCOL, RequestId, ResourceError, ResourceOperation,
    validate_idempotency_key,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestEnvelope {
    pub protocol: String,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub id: RequestId,
    pub operation: ResourceOperation,
    pub params: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

impl RequestEnvelope {
    pub fn validate(&self) -> Result<(), ResourceError> {
        if self.protocol != PROTOCOL || self.envelope_type != EnvelopeType::Request {
            return Err(ResourceError::validation_invalid(
                Some("protocol"),
                "expected a cmux.protocol/2 request envelope",
            ));
        }
        if !self.params.is_object() {
            return Err(ResourceError::validation_invalid(
                Some("params"),
                "request params must be an object",
            ));
        }
        match (&self.idempotency_key, self.operation.class()) {
            (None, OperationClass::Mutation) => Err(ResourceError::validation_invalid(
                Some("idempotency_key"),
                "mutations require idempotency_key",
            )),
            (Some(_), class) if class != OperationClass::Mutation => {
                Err(ResourceError::validation_invalid(
                    Some("idempotency_key"),
                    "only mutations accept idempotency_key",
                ))
            }
            (Some(key), OperationClass::Mutation) => validate_idempotency_key(key),
            _ => Ok(()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResponseEnvelope {
    pub protocol: String,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub id: RequestId,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResourceError>,
}

impl ResponseEnvelope {
    pub fn success(id: RequestId, result: Value) -> Self {
        Self {
            protocol: PROTOCOL.to_string(),
            envelope_type: EnvelopeType::Response,
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(id: RequestId, error: ResourceError) -> Self {
        Self {
            protocol: PROTOCOL.to_string(),
            envelope_type: EnvelopeType::Response,
            id,
            ok: false,
            result: None,
            error: Some(error),
        }
    }

    pub fn validate(&self) -> Result<(), ResourceError> {
        if self.protocol != PROTOCOL || self.envelope_type != EnvelopeType::Response {
            return Err(ResourceError::validation_invalid(
                Some("protocol"),
                "expected a cmux.protocol/2 response envelope",
            ));
        }
        match (self.ok, self.result.is_some(), self.error.is_some()) {
            (true, true, false) | (false, false, true) => Ok(()),
            _ => Err(ResourceError::validation_invalid(
                None,
                "response must contain exactly one matching result or error",
            )),
        }
    }
}
