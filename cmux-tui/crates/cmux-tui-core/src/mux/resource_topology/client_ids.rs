//! Caller-minted public ids of a pane creation (`split-client-keys-v1`,
//! plans/cmux-next/remote-state-ownership.md S1): validated and checked
//! against every live and deleted resource when the creation is prepared.

use super::*;

/// Whether `public_id` names a live or deleted resource: a client-minted id
/// is never reused (`split-client-keys-v1`).
fn resource_public_id_known(registry: &WorkspaceRegistry, public_id: &str) -> anyhow::Result<bool> {
    use rusqlite::OptionalExtension;
    Ok(registry
        .connection
        .get()
        .query_row(
            "SELECT 1 FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// The caller-minted pane id of a pane creation, validated and unused.
pub(super) fn requested_client_pane_id(
    fields: &Map<String, Value>,
    state: &State,
    registry: &WorkspaceRegistry,
) -> anyhow::Result<Option<PanePublicId>> {
    let Some(requested) = fields.get(CLIENT_PANE_ID_FIELD) else { return Ok(None) };
    let requested = requested.as_str().context("bad request: pane_id must be a string")?;
    let pane_id = PanePublicId::parse(requested.to_string())
        .map_err(|_| anyhow::anyhow!("bad request: pane_id {requested:?} is not a pane id"))?;
    anyhow::ensure!(
        !state.resource_indexes.panes.contains_key(&pane_id)
            && !resource_public_id_known(registry, requested)?,
        "pane_id_exists: {requested}"
    );
    Ok(Some(pane_id))
}

/// The caller-minted tab id of a terminal creation, validated and unused.
pub(super) fn requested_client_tab_id(
    fields: &Map<String, Value>,
    state: &State,
    registry: &WorkspaceRegistry,
) -> anyhow::Result<Option<TabPublicId>> {
    let Some(requested) = fields.get(CLIENT_TAB_ID_FIELD) else { return Ok(None) };
    let requested = requested.as_str().context("bad request: tab_id must be a string")?;
    let tab_id = TabPublicId::parse(requested.to_string())
        .map_err(|_| anyhow::anyhow!("bad request: tab_id {requested:?} is not a tab id"))?;
    anyhow::ensure!(
        !state.resource_indexes.tabs.contains_key(&tab_id)
            && !resource_public_id_known(registry, requested)?,
        "tab_id_exists: {requested}"
    );
    Ok(Some(tab_id))
}

/// The caller-minted id of the split a `split` makes
/// (`split-client-split-id-v1`), validated and unused.
pub(super) fn requested_client_split_id(
    fields: &Map<String, Value>,
    state: &State,
    registry: &WorkspaceRegistry,
) -> anyhow::Result<Option<SplitPublicId>> {
    let Some(requested) = fields.get(CLIENT_SPLIT_ID_FIELD) else { return Ok(None) };
    let requested = requested.as_str().context("bad request: split_id must be a string")?;
    let split_id = SplitPublicId::parse(requested.to_string())
        .map_err(|_| anyhow::anyhow!("bad request: split_id {requested:?} is not a split id"))?;
    anyhow::ensure!(
        !state.resource_indexes.splits.contains_key(&split_id)
            && !resource_public_id_known(registry, requested)?,
        "split_id_exists: {requested}"
    );
    Ok(Some(split_id))
}

/// The retired tab id a Reopen Closed creation takes again
/// (`tab_strip::reopen_identity`, plans/cmux-next/durable-links-DESIGN.md):
/// it must name a closed tab, never a live or unknown one, so a retired id
/// only comes back for the same tab.
pub(super) fn requested_reopen_tab_id(
    fields: &Map<String, Value>,
    state: &State,
    registry: &WorkspaceRegistry,
) -> anyhow::Result<Option<TabPublicId>> {
    use crate::mux::tab_strip::reopen_identity;
    let Some(requested) = fields.get(reopen_identity::FIELD) else { return Ok(None) };
    let requested = requested.as_str().context("reopen_tab_id must be a string")?;
    let tab_id = TabPublicId::parse(requested.to_string())
        .map_err(|_| anyhow::anyhow!("reopen_tab_id {requested:?} is not a tab id"))?;
    if state.resource_indexes.tabs.contains_key(&tab_id)
        || !reopen_identity::is_retired_tab(&registry.connection.get(), requested)?
    {
        // Open again already (another reopen won), or never closed: a new id.
        return Ok(None);
    }
    Ok(Some(tab_id))
}
