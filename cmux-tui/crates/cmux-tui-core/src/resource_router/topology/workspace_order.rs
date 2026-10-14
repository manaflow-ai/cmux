//! `workspace.list {order}` (`personal-mixed-order-v1`): `personal`, the
//! default, is the personal sidebar order (loose workspaces and each
//! group's members at the group's slot), then this session's workspaces
//! without a personal row, in session order; `session` is the session order
//! (creation order unless a workspace was moved). With the sidebar document
//! (`sidebar-doc-v1`) the personal order is the document's order of this
//! machine's workspaces.
//!
//! The default is the order the person sees and reorders in the sidebar, so
//! a client that lists workspaces (`cmux workspace list`, an agent's MCP
//! `workspace_list`) shows them in that order. Each row's `index` stays its
//! session index.

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
        Some("session") => Ok(listed),
        None | Some("personal") => {
            let order =
                mux.personal_state_read(crate::state::sidebar_doc_legacy::workspace_order)?;
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
