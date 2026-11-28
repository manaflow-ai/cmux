//! `session/signature` (`protocol/signature.rs`): the dot glyph of each id asked, a pure function
//! of the id (`cmux_wallpaper::signature`). It reads no session, so it is the same on every
//! origin and is never forwarded. A client asks only while its setting is on.

use std::sync::OnceLock;

use cmux_wallpaper::Signer;
use serde_json::Value;

use crate::protocol::signature::{MAX_SESSION_IDS, SignatureParams, SignatureResult};
use crate::rpc::RpcError;

/// The `particles` manifest, parsed once per daemon run.
fn signer() -> &'static Signer {
    static SIGNER: OnceLock<Signer> = OnceLock::new();
    SIGNER.get_or_init(Signer::particles)
}

pub(super) fn handle(params: Value) -> Result<Value, RpcError> {
    let params: SignatureParams = serde_json::from_value(params)
        .map_err(|e| RpcError::invalid_params(format!("session/signature: {e}")))?;
    if params.session_ids.len() > MAX_SESSION_IDS {
        return Err(RpcError::invalid_params(format!(
            "session/signature names at most {MAX_SESSION_IDS} sessions, not {}",
            params.session_ids.len()
        )));
    }
    let signer = signer();
    let signatures = params
        .session_ids
        .into_iter()
        .map(|id| {
            let glyph = signer.glyph(&id);
            (id, glyph)
        })
        .collect();
    let result = SignatureResult { signatures };
    serde_json::to_value(result).map_err(|e| RpcError::internal(format!("session/signature: {e}")))
}

#[cfg(test)]
#[path = "signature_tests.rs"]
mod tests;
