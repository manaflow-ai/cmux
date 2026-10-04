//! [`Ctx`]: what one op handler may touch: one backend call at a time
//! through the control plane, and the machine projection.

use super::control_plane::{ControlPlane, HttpCall, RelayError, WireCall, WireReply, WireResult};
use super::error::{CloudError, codes};
use crate::ops::Projection;
use serde::de::DeserializeOwned;
use serde_json::Value;

pub(crate) struct Ctx<'a, C> {
    control_plane: &'a mut C,
    pub(crate) projection: &'a mut Projection,
    op: &'a str,
    /// The caller's idempotency key: `Some` exactly for mutations. Every
    /// wire call of the op carries it unchanged, so a retry with the same
    /// key reaches the backend's ledger row (contract 1.1).
    key: Option<&'a str>,
    /// The request's origin, sent with each mutation.
    origin: Option<&'static str>,
}

impl<'a, C: ControlPlane> Ctx<'a, C> {
    pub(crate) fn new(
        control_plane: &'a mut C,
        projection: &'a mut Projection,
        op: &'a str,
        key: Option<&'a str>,
    ) -> Self {
        Self { control_plane, projection, op, key, origin: None }
    }

    /// Sends `origin` with this op's mutations (`OpRequest.origin`).
    pub(crate) fn with_origin(mut self, origin: super::wire::Origin) -> Self {
        self.origin = origin.wire_name();
        self
    }

    pub(crate) fn control_plane(&mut self) -> &mut C {
        self.control_plane
    }

    /// One `cmux.wire/1` op with `params` as given. A wire error becomes
    /// the typed [`CloudError`]; `auth.unauthenticated` (or no sign-in at
    /// the host) also clears the projection: a signed-out Mac shows no
    /// machines.
    pub(crate) fn wire(&mut self, op: &str, params: Value) -> Result<WireResult, CloudError> {
        let call = WireCall {
            op: op.to_owned(),
            params,
            idempotency_key: self.key.map(str::to_owned),
            origin: self.key.and(self.origin),
        };
        match self.control_plane.call(&call) {
            Ok(WireReply::Result(result)) => Ok(result),
            Ok(WireReply::Error(error)) => {
                let error = CloudError::from_wire_for(op, &error);
                if error.code == codes::AUTH_REQUIRED {
                    self.projection.clear();
                }
                Err(error)
            }
            Err(e) => Err(self.relay_error(e)),
        }
    }

    /// TRANSITIONAL: one classic route call (attach endpoint, scp endpoint,
    /// file routes; see `control_plane::HttpCall`). Non-2xx answers become
    /// typed errors; a 401 also clears the projection.
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
        let reply = match self.control_plane.classic(&call) {
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

/// Decodes a backend answer into a typed record.
pub(crate) fn decode_answer<T: DeserializeOwned>(op: &str, value: Value) -> Result<T, CloudError> {
    serde_json::from_value(value)
        .map_err(|e| CloudError::new(codes::BAD_RESPONSE, format!("{op}: {e}")))
}
