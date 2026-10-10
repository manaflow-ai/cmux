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
