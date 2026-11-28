//! `cloud.auth.status`: the host answers from its own sign-in. No token
//! crosses to the server.

use crate::api::args;
use crate::api::{CloudError, ControlPlane, Ctx};
use serde_json::{Value, json};

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    _name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    args::object(raw, &[])?;
    match ctx.control_plane().session() {
        Ok(status) => {
            if !status.signed_in {
                ctx.projection.clear();
            }
            Ok(json!(status))
        }
        Err(crate::api::RelayError::NotSignedIn) => {
            ctx.projection.clear();
            Ok(json!({ "signedIn": false, "team": null }))
        }
        Err(e) => Err(ctx.relay_error(e)),
    }
}
