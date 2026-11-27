//! RFD 0170 phase 1 RPCs: the team navigator, the recipient picker and Session Info, each the
//! calling principal's projection of the published team directory (`hub/team_directory.rs`).
//!
//! Behind the same gate as the rest of team messaging (`team.rs` `authorize`, so
//! `meshRelay.teamMessaging`). Every answer is the `cmux-team-messaging` view as it serializes
//! (camelCase), with the directory's `generation`. The snapshot is shared and read without a
//! lock; a call never rebuilds it, so a picker keystroke costs one projection.

use super::*;
use cmux_team_messaging::{navigator, picker, session_info};

/// The most picker candidates one call returns.
const MAX_PICK: usize = 200;
/// Candidates a pick returns when the call names no limit.
const DEFAULT_PICK: usize = 20;

/// The answer to `method` if it is one of the directory views; None for every other method.
pub(super) fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    let view = match method {
        crate::rpc::method::MUX_TEAM_NAVIGATOR
        | crate::rpc::method::MUX_TEAM_PICK
        | crate::rpc::method::MUX_TEAM_SESSION_INFO => hub.team_view(),
        _ => return None,
    };
    Some(answer(view.as_deref(), conn.is_person(), conn.caller(), method, params))
}

/// One directory view for the connection that is `person` or runs in session `caller`.
pub(crate) fn answer(
    view: Option<&crate::hub::TeamView>,
    person: bool,
    caller: Option<&str>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let view = view.ok_or_else(|| {
        RpcError::invalid_params("the team directory is not read yet: no address book from the hub")
            .with_data(json!({"reason": "team_directory_unavailable"}))
    })?;
    let viewer = view.viewer(person, caller).ok_or_else(|| {
        RpcError::invalid_params("this connection is not a principal of the team directory")
            .with_data(json!({"reason": "team_directory_unknown_viewer"}))
    })?;
    let team_id = params.get("teamId").and_then(Value::as_str).unwrap_or(&view.team_id);
    let query = params.get("query").and_then(Value::as_str).unwrap_or("");
    let body = match method {
        crate::rpc::method::MUX_TEAM_NAVIGATOR => {
            let cx = view.nav(team_id);
            let nav = navigator::navigator(viewer, &cx).ok_or_else(not_visible)?;
            let hits = navigator::search(viewer, query, &cx);
            serde_json::to_value(nav).map(|mut v| {
                v["hits"] = json!(hits);
                v
            })
        }
        crate::rpc::method::MUX_TEAM_PICK => {
            let team = view.team(team_id).ok_or_else(not_visible)?;
            let limit = params
                .get("limit")
                .and_then(Value::as_u64)
                .map_or(DEFAULT_PICK, |n| (n as usize).clamp(1, MAX_PICK));
            let mut picked = picker::pick(viewer, query, &view.picker(viewer, team));
            picked.candidates.truncate(limit);
            serde_json::to_value(picked)
        }
        _ => {
            let session = params
                .get("sessionId")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            let cx = view.session(session).ok_or_else(not_visible)?;
            serde_json::to_value(session_info::session_info(viewer, &cx).ok_or_else(not_visible)?)
        }
    };
    let mut body = body.map_err(|e| RpcError::internal(e.to_string()))?;
    if let Value::Object(map) = &mut body {
        map.insert("generation".into(), json!(view.generation));
    }
    Ok(body)
}

/// The viewer may not see what it asked for, or it does not exist: one answer for both, so a
/// refusal tells nothing about what is there.
fn not_visible() -> RpcError {
    RpcError::invalid_params("not visible to this connection")
        .with_data(json!({"reason": "team_directory_not_visible"}))
}
