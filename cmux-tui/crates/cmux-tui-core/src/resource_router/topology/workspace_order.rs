//! `workspace.list {order}` (`personal-mixed-order-v1`). With the sidebar
//! document (`sidebar-doc-v1`) the default and `personal` are the
//! document's order of this machine's workspaces (one order with the
//! sidebar, see `state::sidebar_doc_order`); `session` stays the session
//! order. Without the document the default is the session order and
//! `personal` the personal sidebar order (loose workspaces and each group's
//! members at the group's slot), then the workspaces without a personal
//! row, in session order.

use super::*;

pub(super) fn list_workspaces(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    // The workspaces alone, not the whole session snapshot filtered: the
    // session scope keeps every workspace (`SnapshotPathIndex::contains`).
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let listed = Value::Array(crate::resource_api::public_workspaces(mux)?);
    let personal = match optional_string(&request.fields, "order")?.as_deref() {
        Some("session") => return Ok(listed),
        None => false,
        Some("personal") => true,
        Some(other) => {
            return Err(validation_error(
                "order must be session or personal",
                json!({"field":"order","value":other}),
            ));
        }
    };
    let Value::Array(mut workspaces) = listed else { return Ok(listed) };
    // Committed rows on the read-only connection, as the list itself: no
    // wait for a writer that holds the registry lock.
    let document_order = crate::resource_api::read_committed_registry(mux, |connection, _| {
        crate::state::sidebar_doc_order::document_order(connection)
    })
    .map_err(crate::resource_api::operation_failed)?;
    if let Some(order) = document_order {
        crate::state::sidebar_doc_order::sort_workspaces(
            &mut workspaces,
            "id",
            &order,
            crate::user_settings::NewWorkspacePlacement::current(),
        );
    } else if personal {
        let order = crate::resource_api::read_committed_registry(mux, |connection, _| {
            crate::state::sidebar_doc_legacy::workspace_order(connection)
        })
        .map_err(crate::resource_api::operation_failed)?;
        let rank = order
            .iter()
            .enumerate()
            .map(|(rank, id)| (id.as_str(), rank))
            .collect::<HashMap<_, _>>();
        workspaces.sort_by_key(|workspace| {
            workspace["id"].as_str().and_then(|id| rank.get(id).copied()).unwrap_or(usize::MAX)
        });
    }
    Ok(Value::Array(workspaces))
}
