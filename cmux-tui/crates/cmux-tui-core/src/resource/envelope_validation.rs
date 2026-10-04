//! The shape rules every `cmux.protocol/2` request envelope meets before
//! dispatch.

use super::*;

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
