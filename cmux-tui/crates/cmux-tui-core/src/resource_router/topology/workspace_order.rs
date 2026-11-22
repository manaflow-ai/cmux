//! `workspace.list {order}` (`personal-mixed-order-v1`): `session`, the
//! default, is the session order; `personal` is the personal sidebar order
//! (loose workspaces and each group's members at the group's slot), then
//! this session's workspaces without a personal row, in session order.

use super::*;

pub(super) fn list_workspaces(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let listed = list_resources(
        mux,
        &request.selectors,
        ResourceTarget::Session,
        "workspaces",
        "workspace.list",
    )?;
    match optional_string(&request.fields, "order")?.as_deref() {
        None | Some("session") => Ok(listed),
        Some("personal") => {
            let order =
                mux.personal_state_read(crate::state::personal_order::sidebar_workspace_ids)?;
            let rank = order
                .iter()
                .enumerate()
                .map(|(rank, id)| (id.as_str(), rank))
                .collect::<HashMap<_, _>>();
            match listed {
                Value::Array(mut workspaces) => {
                    workspaces.sort_by_key(|workspace| {
                        workspace["id"]
                            .as_str()
                            .and_then(|id| rank.get(id).copied())
                            .unwrap_or(usize::MAX)
                    });
                    Ok(Value::Array(workspaces))
                }
                other => Ok(other),
            }
        }
        Some(other) => Err(validation_error(
            "order must be session or personal",
            json!({"field":"order","value":other}),
        )),
    }
}
