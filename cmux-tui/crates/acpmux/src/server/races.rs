//! Parent-scoped races use the same proven-caller/person boundary as sub-session starts.
use super::{Conn, str_param};
use crate::hub::Hub;
use crate::hub::races::Target;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !m.starts_with("_acpmux/race/") {
        return None;
    }
    Some(handle(hub, conn, m, params).await)
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let parent = super::subsessions::start_parent(hub, conn, params)?;
    match m {
        method::MUX_RACE_START => {
            let candidates: Vec<Target> = serde_json::from_value(params["candidates"].clone())
                .map_err(|e| RpcError::invalid_params(format!("invalid race candidates: {e}")))?;
            let reviewer: Target = serde_json::from_value(params["reviewer"].clone())
                .map_err(|e| RpcError::invalid_params(format!("invalid race reviewer: {e}")))?;
            let local = super::remote_guard::control_of(conn.origin, conn.auth, params)
                != crate::hub::Control::Web;
            hub.race_start(
                &parent,
                str_param(params, "prompt").unwrap_or_default().to_owned(),
                candidates,
                reviewer,
                local,
            )
            .await
        }
        method::MUX_RACE_LIST => Ok(hub.race_list(&parent)),
        method::MUX_RACE_STATS => Ok(hub.race_stats(&parent)),
        method::MUX_RACE_GET | method::MUX_RACE_CANCEL => {
            let id = str_param(params, "raceId")
                .ok_or_else(|| RpcError::invalid_params("raceId is required"))?;
            if m == method::MUX_RACE_CANCEL {
                hub.race_cancel(&parent, id).await
            } else {
                Ok(json!(hub.race_get(&parent, id)?))
            }
        }
        _ => Err(RpcError::invalid_params("unknown race method")),
    }
}
