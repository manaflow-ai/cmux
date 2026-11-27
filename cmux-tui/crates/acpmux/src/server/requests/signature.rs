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
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn answers_a_glyph_per_id_known_or_not() {
        let id = "01a1f1fd-638f-73f4-b295-534adfe6d7cc";
        let reply = handle(json!({"sessionIds": [id, "no-such-session", id]})).unwrap();
        let signatures = reply["signatures"].as_object().unwrap();
        assert_eq!(signatures.len(), 2, "one glyph per distinct id");
        assert_eq!(signatures[id], serde_json::to_value(cmux_wallpaper::glyph(id)).unwrap());
        let g = &signatures["no-such-session"];
        assert!(g["seed"].is_number() && g["drift"].is_number());
        assert!(g["variant"].is_string() && g["accent"].as_str().unwrap().starts_with('#'));
        let dots = g["dots"].as_array().unwrap();
        assert!((5..=9).contains(&dots.len()));
        assert!(dots.iter().all(|d| ["x", "y", "r", "phase"].iter().all(|k| d[k].is_number())));
    }

    #[test]
    fn refuses_more_than_512_ids_and_a_bad_shape() {
        let ids: Vec<String> = (0..=MAX_SESSION_IDS).map(|i| i.to_string()).collect();
        assert_eq!(handle(json!({"sessionIds": ids})).unwrap_err().code, -32602);
        let ids: Vec<String> = (0..MAX_SESSION_IDS).map(|i| i.to_string()).collect();
        let reply = handle(json!({"sessionIds": ids})).unwrap();
        assert_eq!(reply["signatures"].as_object().unwrap().len(), MAX_SESSION_IDS);
        assert_eq!(handle(json!({})).unwrap_err().code, -32602);
        assert_eq!(handle(json!({"sessionIds": "a"})).unwrap_err().code, -32602);
        assert_eq!(handle(json!({"sessionIds": []})).unwrap(), json!({"signatures": {}}));
    }
}
