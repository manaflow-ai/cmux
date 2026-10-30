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
    let listed = list_resources(
        mux,
        &request.selectors,
        ResourceTarget::Session,
        "workspaces",
        "workspace.list",
    )?;
    let personal = match optional_string(&request.fields, "order")?.as_deref() {
        Some("session") => None,
        None => Some(false),
        Some("personal") => Some(true),
        Some(other) => {
            return Err(validation_error(
                "order must be session or personal",
                json!({"field":"order","value":other}),
            ));
        }
    };
    let Value::Array(mut workspaces) = listed else { return Ok(listed) };
    let document = mux.personal_state_read(crate::state::sidebar_doc_order::document_order);
    // The session order never needed the document: an unreadable one costs it only the pins.
    let document = if personal.is_none() { document.ok().flatten() } else { document? };
    insert_pinned(mux, &mut workspaces, document.as_ref());
    match (personal, &document) {
        (None, _) => {}
        (Some(_), Some(order)) => crate::state::sidebar_doc_order::sort_workspaces(
            &mut workspaces,
            "id",
            order,
            crate::user_settings::NewWorkspacePlacement::current(),
        ),
        (Some(true), None) => {
            let order =
                mux.personal_state_read(crate::state::sidebar_doc_legacy::workspace_order)?;
            let rank = order
                .iter()
                .enumerate()
                .map(|(rank, id)| (id.as_str(), rank))
                .collect::<HashMap<_, _>>();
            workspaces.sort_by_key(|workspace| {
                workspace["id"].as_str().and_then(|id| rank.get(id).copied()).unwrap_or(usize::MAX)
            });
        }
        (Some(false), None) => {}
    }
    Ok(Value::Array(workspaces))
}

/// Each listed workspace's `extra.pinned` (cmux#25586): what the sidebar
/// shows, the document's pin (top level of Pinned, or pinned in its group)
/// when it places the workspace, else the daemon's `workspace-pin-v1` flag.
/// It rides in `extra` because `WorkspaceSnapshot` forbids unknown fields.
fn insert_pinned(
    mux: &Mux,
    workspaces: &mut [Value],
    document: Option<&crate::state::sidebar_doc_order::DocumentOrder>,
) {
    let presentation = mux.presentation_snapshot();
    let flags = mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .map(|workspace| {
                let pinned =
                    presentation.workspace(&workspace.key).is_some_and(|record| record.pinned);
                (workspace.public_id.as_str().to_owned(), pinned)
            })
            .collect::<HashMap<_, _>>()
    });
    for workspace in workspaces {
        let Some(id) = workspace["id"].as_str() else { continue };
        let pinned = document
            .and_then(|order| order.pinned(id))
            .unwrap_or_else(|| flags.get(id).copied().unwrap_or(false));
        if let Some(row) = workspace.as_object_mut() {
            let extra = row.entry("extra").or_insert_with(|| Value::Object(Default::default()));
            if let Some(extra) = extra.as_object_mut() {
                extra.insert("pinned".into(), Value::Bool(pinned));
            }
        }
    }
}
