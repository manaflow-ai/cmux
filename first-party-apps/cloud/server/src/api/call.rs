//! [`Ctx`]: what one op handler may touch: one backend call at a time
//! through the control plane, and the machine projection.

use super::control_plane::{ControlPlane, RelayError, WireCall, WireReply, WireResult};
use super::error::{CloudError, codes};
use crate::ops::Projection;
use serde::de::DeserializeOwned;
use serde_json::Value;

pub(crate) struct Ctx<'a, C> {
    control_plane: &'a mut C,
    pub(crate) projection: &'a mut Projection,
    /// The caller's idempotency key: `Some` exactly for mutations. Every
    /// ordinary mutation carries it unchanged. Composed operations derive stable
    /// child keys, so retrying each target reaches the backend's ledger row.
    key: Option<&'a str>,
    /// The request's origin, sent with each mutation.
    origin: Option<&'static str>,
}

impl<'a, C: ControlPlane> Ctx<'a, C> {
    pub(crate) fn new(
        control_plane: &'a mut C,
        projection: &'a mut Projection,
        key: Option<&'a str>,
    ) -> Self {
        Self { control_plane, projection, key, origin: None }
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
        self.wire_key(op, params, self.key)
    }

    pub(crate) fn key(&self) -> Option<&str> {
        self.key
    }

    /// A composed operation's reads have no key; its mutations use stable child keys.
    pub(crate) fn wire_key(
        &mut self,
        op: &str,
        params: Value,
        key: Option<&str>,
    ) -> Result<WireResult, CloudError> {
        let call = WireCall {
            op: op.to_owned(),
            params,
            idempotency_key: key.map(str::to_owned),
            origin: key.and(self.origin),
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
