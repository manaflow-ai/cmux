//! `list-workspaces` with `known` (`list-workspaces-known-v1`) and `limit`
//! (`list-workspaces-limit-v1`): an O(1) `unchanged` for a client that holds
//! the current tree, and the first screen of a god session in sidebar order.
//! A remote device is answered from what it may see (incognito_remote.rs).

use super::*;

/// `known` on `list-workspaces`: `{"unchanged": true}` in O(1) when the
/// client's tree is current, and `tree_revision` on the whole reply.
pub const LIST_WORKSPACES_KNOWN_CAPABILITY: &str = "list-workspaces-known-v1";
/// `limit` on `list-workspaces`: the first N workspaces in sidebar order and
/// `total`, so a client draws its first screen before it reads the rest.
pub const LIST_WORKSPACES_LIMIT_CAPABILITY: &str = "list-workspaces-limit-v1";

/// The `list-workspaces` reply: the tree plus the registry identity it
/// belongs to. The launch snapshot stores the same value.
pub(super) fn list_workspaces_reply(mux: &Mux) -> anyhow::Result<Value> {
    // Concurrent readers share one build that starts after each arrived.
    mux.tree_reply_flight.read(|| list_workspaces_tree(mux))
}

/// [`list_workspaces_reply`] as the tree's text, which the concurrent
/// readers of its build share (tree_reply_text.rs).
pub(super) fn list_workspaces_reply_text(
    mux: &Mux,
    render: &RenderService,
) -> anyhow::Result<Arc<tree_reply_text::TreeText>> {
    mux.tree_reply_flight.read_text(
        || list_workspaces_tree(mux),
        |tree| {
            let lap = crate::measure_probe::now();
            let text = render.serialize_tree(tree);
            crate::measure_probe::since("lw.text", lap);
            text
        },
    )
}

pub(super) fn list_workspaces_tree(mux: &Mux) -> anyhow::Result<Value> {
    let notifications = mux.tree_decorations();
    let lap = crate::measure_probe::now();
    let mut workspaces = mux.with_state(|state| workspaces_json(state, &notifications));
    crate::measure_probe::since("lw.nodes (state lock)", lap);
    let lap = crate::measure_probe::now();
    let (registry_id, generation) = mux.registry_identity();
    workspaces.set("registry_id", json!(registry_id));
    workspaces.set("generation", json!(generation));
    workspaces.set("terminal_revision", json!(mux.terminal_registry_revision()?));
    crate::measure_probe::since("lw.registry_fields", lap);
    let lap = crate::measure_probe::now();
    drop(notifications);
    crate::measure_probe::since("lw.drop_decorations", lap);
    Ok(workspaces)
}

/// `list-workspaces` for a client that holds a tree (`known`): an O(1)
/// `{"unchanged": true, "workspaces": []}` with the identity and revisions when nothing it
/// shows changed, else the whole reply with its `tree_revision`. The tree
/// revision is read first, so a change that lands while the tree is read
/// makes the next request read it again.
pub(super) fn list_workspaces_reply_since(
    mux: &Mux,
    known: &cmd_workspaces::KnownTree,
    limit: Option<usize>,
    remote_view: Option<&incognito_remote::Hidden>,
) -> anyhow::Result<Value> {
    if let Some(hidden) = remote_view {
        return list_workspaces_reply_seen(mux, known, limit, hidden);
    }
    let tree_revision = mux.tree_revision();
    let (registry_id, generation) = mux.registry_identity();
    let (workspace_revision, pane_revision) =
        mux.with_state(|state| (state.workspace_revision, state.pane_revision));
    let current = cmd_workspaces::KnownTree {
        registry_id: Some(registry_id),
        generation: Some(generation),
        workspace_revision: Some(workspace_revision),
        pane_revision: Some(pane_revision),
        terminal_revision: Some(mux.terminal_registry_revision()?),
        tree_revision: Some(tree_revision.clone()),
    };
    // The fields of `current` are read one after another; the revision read again after
    // them says no change landed between those reads.
    if *known == current && mux.tree_revision() == tree_revision {
        // `workspaces` stays (empty), so a typed SDK decodes this as the `Tree` it
        // declares; `unchanged` says to keep the tree the client holds.
        return Ok(json!({
            "unchanged": true,
            "workspaces": [],
            "registry_id": current.registry_id,
            "generation": current.generation,
            "workspace_revision": workspace_revision,
            "pane_revision": pane_revision,
            "terminal_revision": current.terminal_revision,
            "tree_revision": tree_revision,
        }));
    }
    if let Some(limit) = limit {
        let (mut reply, whole) = list_workspaces_reply_first(mux, limit, None)?;
        // A part of the tree is not a tree to hold: only a whole one gets the revision
        // a later `known` sends back.
        if whole {
            reply.set("tree_revision", json!(tree_revision));
        }
        return Ok(reply);
    }
    let mut reply = list_workspaces_reply(mux)?;
    reply.set("tree_revision", json!(tree_revision));
    Ok(reply)
}

/// `list-workspaces` with `limit` (`list-workspaces-limit-v1`): the first `limit`
/// workspaces in sidebar order (the sidebar document's order, else the personal order, then
/// the workspaces neither places, as `workspace.list {order: "personal"}` sorts them), with
/// `total`, the number of workspaces. Only those rows are serialized. True with it when the
/// reply holds every workspace. With `hidden` (a remote device, #31210), the workspaces it
/// must not see are left out before the first `limit` are taken and before `total` counts.
pub(super) fn list_workspaces_reply_first(
    mux: &Mux,
    limit: usize,
    hidden: Option<&incognito_remote::Hidden>,
) -> anyhow::Result<(Value, bool)> {
    let order = SidebarOrder::read(mux)?;
    let notifications = mux.tree_decorations();
    let (mut reply, whole) = mux.with_state(|state| {
        let (first, total) = order.first(state, limit, hidden);
        (tree_json::workspaces_json_at(state, &notifications, &first, total), first.len() == total)
    });
    let (registry_id, generation) = mux.registry_identity();
    reply.set("registry_id", json!(registry_id));
    reply.set("generation", json!(generation));
    reply.set("terminal_revision", json!(mux.terminal_registry_revision()?));
    Ok((reply, whole))
}

/// The sidebar order `limit` reads (`list_workspaces_reply_first`).
enum SidebarOrder {
    Document(crate::state::sidebar_doc_order::DocumentOrder),
    Personal(Vec<String>),
}

impl SidebarOrder {
    /// The committed sidebar order: the sidebar document's, else the personal order.
    fn read(mux: &Mux) -> anyhow::Result<Self> {
        crate::resource_api::read_committed_registry(mux, |connection, _| {
            Ok(match crate::state::sidebar_doc_order::document_order(connection)? {
                Some(order) => Self::Document(order),
                None => {
                    Self::Personal(crate::state::sidebar_doc_legacy::workspace_order(connection)?)
                }
            })
        })
    }

    /// The indices in `state.workspaces` of the first `limit` workspaces in this order that
    /// `hidden` keeps, and how many it keeps.
    fn first(
        &self,
        state: &State,
        limit: usize,
        hidden: Option<&incognito_remote::Hidden>,
    ) -> (Vec<usize>, usize) {
        let mut rows = state
            .workspaces
            .iter()
            .enumerate()
            .filter(|(_, workspace)| {
                hidden.is_none_or(|hidden| !hidden.hides_workspace(workspace.public_id.as_str()))
            })
            .map(|(index, workspace)| {
                json!({"id": workspace.public_id, "active": index == state.active_workspace,
                       "index": index})
            })
            .collect::<Vec<_>>();
        match self {
            Self::Document(order) => crate::state::sidebar_doc_order::sort_workspaces(
                &mut rows,
                "id",
                order,
                crate::user_settings::NewWorkspacePlacement::current(),
            ),
            Self::Personal(order) => {
                let rank = order
                    .iter()
                    .enumerate()
                    .map(|(rank, id)| (id.as_str(), rank))
                    .collect::<HashMap<_, _>>();
                rows.sort_by_key(|row| {
                    row.get("id")
                        .and_then(Value::as_str)
                        .and_then(|id| rank.get(id).copied())
                        .unwrap_or(usize::MAX)
                });
            }
        }
        let first = rows
            .iter()
            .take(limit)
            .filter_map(|row| row.get("index").and_then(Value::as_u64))
            .map(|i| i as usize)
            .collect();
        (first, rows.len())
    }
}

/// `list-workspaces` with `known` for a remote device that must not see
/// some workspaces (incognito_remote.rs `list_view`): its tree revision is a
/// digest of the rows it is answered and of their sidebar order (the order a
/// `limit` page takes), so an incognito workspace's changes, which the
/// daemon's revision counts, never move it. Its `unchanged` answer carries
/// back the counters the device holds, never the daemon's, which an
/// incognito edit alone moves. It costs the whole tree's rows, as the reply
/// without `known` does; only the line it sends is small. A change that lands
/// while the digest is read (the daemon's revision moved) answers the whole
/// reply, never `unchanged`, and with `limit` the page read after the digest
/// carries no revision to hold, so the next request reads again.
fn list_workspaces_reply_seen(
    mux: &Mux,
    known: &cmd_workspaces::KnownTree,
    limit: Option<usize>,
    hidden: &incognito_remote::Hidden,
) -> anyhow::Result<Value> {
    use std::hash::{Hash, Hasher};
    let daemon_revision = mux.tree_revision();
    let order = SidebarOrder::read(mux)?;
    let mut reply = list_workspaces_reply(mux)?;
    hidden.prune_reply(&mut reply);
    let sidebar_ids = mux.with_state(|state| {
        let (seen, _) = order.first(state, usize::MAX, Some(hidden));
        seen.iter()
            .filter_map(|index| state.workspaces.get(*index))
            .map(|workspace| workspace.public_id.to_string())
            .collect::<Vec<_>>()
    });
    let mut digest = std::collections::hash_map::DefaultHasher::new();
    let field = |key: &str| reply.get(key).unwrap_or(&Value::Null);
    field("workspaces").to_string().hash(&mut digest);
    field("groups").to_string().hash(&mut digest);
    sidebar_ids.hash(&mut digest);
    let boot = daemon_revision.split_once('.').map_or(daemon_revision.as_str(), |(boot, _)| boot);
    let tree_revision = format!("{boot}.v{:016x}", digest.finish());
    let settled = mux.tree_revision() == daemon_revision;
    if settled
        && known.registry_id.as_deref() == field("registry_id").as_str()
        && known.tree_revision.as_deref() == Some(tree_revision.as_str())
    {
        let mut reply = json!({
            "unchanged": true,
            "workspaces": [],
            "registry_id": field("registry_id"),
            "generation": field("generation"),
            "tree_revision": tree_revision,
        });
        // The counters the device holds; one it did not send is left out,
        // never null (`Tree` declares them optional, not nullable).
        for (key, value) in [
            ("workspace_revision", known.workspace_revision),
            ("pane_revision", known.pane_revision),
            ("terminal_revision", known.terminal_revision),
        ] {
            if let Some(value) = value {
                reply.set(key, json!(value));
            }
        }
        return Ok(reply);
    }
    if let Some(limit) = limit {
        let (mut page, whole) = list_workspaces_reply_first(mux, limit, Some(hidden))?;
        if whole && mux.tree_revision() == daemon_revision {
            page.set("tree_revision", json!(tree_revision));
        }
        return Ok(page);
    }
    if settled {
        reply.set("tree_revision", json!(tree_revision));
    }
    Ok(reply)
}

impl Command {
    /// `list-workspaces` with `known` or `limit` prunes its reply with the view
    /// its `total` and revision were read with (`incognito_remote::list_with_one_view`),
    /// so the dispatcher leaves it as it is.
    pub(super) fn prunes_its_own_reply(&self) -> bool {
        matches!(self, Self::ListWorkspaces { known, limit } if known.is_some() || limit.is_some())
    }
}

#[cfg(test)]
#[path = "list_workspaces_known_tests.rs"]
mod list_workspaces_known_tests;

#[cfg(test)]
#[path = "list_workspaces_limit_tests.rs"]
mod list_workspaces_limit_tests;

#[cfg(test)]
#[path = "list_workspaces_bench_tests.rs"]
mod list_workspaces_bench_tests;
