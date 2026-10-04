//! [`Ctx`]: what one op handler may touch: one Cloud API call at a time
//! through the control plane, and the machine projection.

use super::control_plane::{ControlPlane, HttpCall, RelayError};
use super::error::{CloudError, codes};
use crate::ops::Projection;
use serde::de::DeserializeOwned;
use serde_json::Value;

pub(crate) struct Ctx<'a, C> {
    control_plane: &'a mut C,
    pub(crate) projection: &'a mut Projection,
    op: &'a str,
    key: Option<&'a str>,
}

impl<'a, C: ControlPlane> Ctx<'a, C> {
    pub(crate) fn new(
        control_plane: &'a mut C,
        projection: &'a mut Projection,
        op: &'a str,
        key: Option<&'a str>,
    ) -> Self {
        Self { control_plane, projection, op, key }
    }

    pub(crate) fn control_plane(&mut self) -> &mut C {
        self.control_plane
    }

    /// One Cloud API call. Non-2xx answers become typed errors. A 401 (or no
    /// sign-in at all) also clears the projection: a signed-out Mac shows no
    /// machines.
    pub(crate) fn call(
        &mut self,
        method: &'static str,
        path: String,
        body: Option<Value>,
    ) -> Result<Value, CloudError> {
        let call = HttpCall {
            op: self.op.to_owned(),
            method,
            path,
            body,
            idempotency_key: if method == "GET" { None } else { self.key.map(str::to_owned) },
        };
        let reply = match self.control_plane.call(&call) {
            Ok(reply) => reply,
            Err(e) => return Err(self.relay_error(e)),
        };
        if !(200..300).contains(&reply.status) {
            let error =
                CloudError::from_http(reply.status, &reply.body, reply.error_code.as_deref());
            if error.code == codes::AUTH_REQUIRED {
                self.projection.clear();
            }
            return Err(error);
        }
        Ok(reply.body)
    }

    pub(crate) fn relay_error(&mut self, error: RelayError) -> CloudError {
        match error {
            RelayError::NotSignedIn => {
                self.projection.clear();
                CloudError::new(codes::AUTH_REQUIRED, "Sign in to cmux Cloud first")
            }
            RelayError::Unavailable(why) => {
                CloudError { retryable: true, ..CloudError::new(codes::RELAY_UNAVAILABLE, why) }
            }
        }
    }
}

/// Decodes a Cloud API answer into a typed record.
pub(crate) fn decode_answer<T: DeserializeOwned>(
    path: &str,
    value: Value,
) -> Result<T, CloudError> {
    serde_json::from_value(value)
        .map_err(|e| CloudError::new(codes::BAD_RESPONSE, format!("{path}: {e}")))
}
