//! The checks that an open of the registry runs on the stored resource
//! topology: each row agrees with its identity, positions have no gap, and
//! each parent selects a child of its own.

use super::*;

/// The open checks the foreign keys of the state tables before it calls this
/// (`first_state_foreign_key_violation`), with foreign keys on from that check
/// to this call. These checks do not check the keys again.
pub(crate) fn validate_resource_invariants(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    validate_concrete_identity_lifecycles(transaction)?;
    validate_contiguous_positions(
        transaction,
        "SELECT '' AS parent, position FROM workspaces
         WHERE tombstoned = 0 ORDER BY position ASC",
        "workspace",
    )?;
    validate_contiguous_positions(
        transaction,
        "SELECT workspace_id, position FROM resource_screens
         WHERE deleted_revision IS NULL ORDER BY workspace_id ASC, position ASC",
        "screen",
    )?;
    validate_contiguous_positions(
        transaction,
        "SELECT pane_id, position FROM resource_tabs
         WHERE deleted_revision IS NULL ORDER BY pane_id ASC, position ASC",
        "tab",
    )?;

    let unmapped_workspace = transaction
        .query_row(
            "SELECT w.workspace_key
             FROM workspaces w
             LEFT JOIN resource_workspaces rw
               ON rw.workspace_key = w.workspace_key AND rw.deleted_revision IS NULL
             WHERE w.tombstoned = 0 AND rw.public_id IS NULL
               AND w.workspace_key NOT IN (
                 -- One list, read once: a correlated NOT EXISTS reread every
                 -- receipt per live workspace (876 x 3,723: 2 s at each open
                 -- of a nightly registry, Lawrence 2026-10-29).
                 SELECT json_extract(
                          creation.intent_json,
                          '$.workspace_reservation.workspace_key'
                        )
                 FROM resource_creation_receipts creation
                 WHERE creation.execution_kind = 'effect'
                   AND creation.state = 'executing'
                   AND json_extract(
                         creation.intent_json,
                         '$.workspace_reservation.workspace_key'
                       ) IS NOT NULL
               )
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(workspace_key) = unmapped_workspace {
        anyhow::bail!("live workspace {workspace_key} has no live public identity");
    }
    let closed_workspace = transaction
        .query_row(
            "SELECT rw.public_id
             FROM resource_workspaces rw
             LEFT JOIN workspaces w
               ON w.workspace_key = rw.workspace_key AND w.tombstoned = 0
             WHERE rw.deleted_revision IS NULL AND w.workspace_key IS NULL
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(workspace_id) = closed_workspace {
        anyhow::bail!("resource workspace {workspace_id} has no live workspace row");
    }

    let live_workspace_count: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM resource_workspaces WHERE deleted_revision IS NULL",
        [],
        |row| row.get(0),
    )?;
    match meta_value(transaction, "active_workspace_id")? {
        Some(active_workspace) => {
            let live = transaction
                .query_row(
                    "SELECT 1 FROM resource_workspaces
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                    [&active_workspace],
                    |_| Ok(()),
                )
                .optional()?;
            if live.is_none() {
                anyhow::bail!("active workspace {active_workspace} is not live");
            }
        }
        None if live_workspace_count != 0 => {
            anyhow::bail!("live session has workspaces but no active workspace");
        }
        None => {}
    }

    let active_screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id, active_screen_id FROM resource_workspaces
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id, workspace_id, layout_json, active_pane_id, zoomed_pane_id,
                    viewport_json
             FROM resource_screens WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    // Each loop below asked SQLite about the parent and the children of each
    // row: 11 statements, each compiled at its call, for one workspace with
    // one screen, pane, tab and terminal. The rows that answer those questions
    // are the rows of the loops themselves, so each list is read in front of
    // the first loop that needs it and the loops look in memory.
    let live_workspaces = active_screens
        .iter()
        .map(|(workspace_id, _)| workspace_id.as_str())
        .collect::<HashSet<_>>();
    let mut screen_owners = HashMap::<&str, &str>::new();
    let mut workspaces_with_screens = HashSet::<&str>::new();
    for (screen_id, workspace_id, ..) in &screens {
        screen_owners.insert(screen_id.as_str(), workspace_id.as_str());
        workspaces_with_screens.insert(workspace_id.as_str());
    }
    for (workspace_id, screen_id) in &active_screens {
        match screen_id {
            Some(screen_id) => {
                let owner = screen_owners.get(screen_id.as_str()).copied();
                if owner != Some(workspace_id.as_str()) {
                    anyhow::bail!(
                        "workspace {workspace_id} selects screen {screen_id} owned by {owner:?}"
                    );
                }
            }
            None if workspaces_with_screens.contains(workspace_id.as_str()) => {
                anyhow::bail!("workspace {workspace_id} has screens but no active screen");
            }
            None => {}
        }
    }

    let panes = {
        let mut statement = transaction.prepare(
            "SELECT public_id, screen_id, active_tab_id FROM resource_panes
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut panes_by_screen = HashMap::<&str, HashSet<String>>::new();
    for (pane_id, screen_id, _) in &panes {
        panes_by_screen.entry(screen_id.as_str()).or_default().insert(pane_id.clone());
    }
    let no_panes = HashSet::<String>::new();
    let mut expected_splits = HashSet::new();
    for (screen_id, workspace_id, layout_json, active_pane, zoomed_pane, viewport_json) in &screens
    {
        if !live_workspaces.contains(workspace_id.as_str()) {
            anyhow::bail!("screen {screen_id} has closed workspace {workspace_id}");
        }
        let layout: RegistryLayoutNode = serde_json::from_str(layout_json)?;
        let viewport: RegistryViewport = serde_json::from_str(viewport_json)?;
        let mut layout_panes = HashSet::new();
        let mut layout_splits = HashSet::new();
        validate_layout_node(&layout, &mut layout_panes, &mut layout_splits)?;
        validate_registry_viewport(&viewport, &layout, &layout_panes, &layout_splits)?;
        let layout_panes =
            layout_panes.into_iter().map(ToString::to_string).collect::<HashSet<_>>();
        let stored_panes = panes_by_screen.get(screen_id.as_str()).unwrap_or(&no_panes);
        if layout_panes != *stored_panes {
            anyhow::bail!("screen {screen_id} layout does not match its live pane rows");
        }
        if !stored_panes.contains(active_pane)
            || zoomed_pane.as_ref().is_some_and(|pane| !stored_panes.contains(pane))
        {
            anyhow::bail!("screen {screen_id} selects a pane outside its layout");
        }
        let mut screen_splits = Vec::new();
        collect_screen_split_public_ids(&layout, &viewport, &mut screen_splits);
        expected_splits.extend(screen_splits);
    }
    let live_splits = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_identities
             WHERE kind = 'split' AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    if live_splits != expected_splits {
        anyhow::bail!("live split identities do not match persisted screen layouts");
    }

    let tabs = {
        let mut statement = transaction.prepare(
            "SELECT public_id, pane_id, content_kind, content_id
             FROM resource_tabs WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut tab_owners = HashMap::<&str, &str>::new();
    let mut panes_with_tabs = HashSet::<&str>::new();
    for (tab_id, pane_id, ..) in &tabs {
        tab_owners.insert(tab_id.as_str(), pane_id.as_str());
        panes_with_tabs.insert(pane_id.as_str());
    }
    for (pane_id, screen_id, active_tab) in &panes {
        if !screen_owners.contains_key(screen_id.as_str()) {
            anyhow::bail!("pane {pane_id} has closed screen {screen_id}");
        }
        match active_tab {
            Some(active_tab) => {
                let owner = tab_owners.get(active_tab.as_str()).copied();
                if owner != Some(pane_id.as_str()) {
                    anyhow::bail!("pane {pane_id} selects tab {active_tab} owned by {owner:?}");
                }
            }
            None if panes_with_tabs.contains(pane_id.as_str()) => {
                anyhow::bail!("pane {pane_id} has tabs but no active tab");
            }
            None => {}
        }
    }

    let terminals = {
        let mut statement = transaction.prepare(
            "SELECT public_id, terminal_id, lifecycle FROM resource_terminals
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let live_browsers = {
        let mut statement = transaction
            .prepare("SELECT public_id FROM resource_browsers WHERE deleted_revision IS NULL")?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    // The live identity of the content of each live tab, by the content id as
    // the tab row holds it. From the live tabs, not from all live identities:
    // the open must not read the identities that no tab shows.
    let content_identity_kinds = {
        let mut statement = transaction.prepare(
            "SELECT t.content_id, i.kind
             FROM resource_tabs t
             JOIN resource_identities i ON i.public_id = t.content_id
             WHERE t.deleted_revision IS NULL AND i.deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<HashMap<_, _>, _>>()?
    };
    let live_panes = panes.iter().map(|(pane_id, ..)| pane_id.as_str()).collect::<HashSet<_>>();
    let live_terminals =
        terminals.iter().map(|(public_id, ..)| public_id.as_str()).collect::<HashSet<_>>();
    for (tab_id, pane_id, content_kind, content_id) in &tabs {
        if !live_panes.contains(pane_id.as_str()) {
            anyhow::bail!("tab {tab_id} has closed pane {pane_id}");
        }
        let live_content = match content_kind.as_str() {
            "terminal" => live_terminals.contains(content_id.as_str()),
            "browser" => live_browsers.contains(content_id.as_str()),
            other => anyhow::bail!("tab {tab_id} has invalid content kind {other:?}"),
        };
        if !live_content {
            anyhow::bail!("tab {tab_id} references closed {content_kind} {content_id}");
        }
        let identity_kind = content_identity_kinds.get(content_id.as_str()).map(String::as_str);
        if identity_kind != Some(content_kind.as_str()) {
            anyhow::bail!("tab {tab_id} content {content_id} has identity kind {identity_kind:?}");
        }
    }

    // The host row of each live terminal, by the host id as the terminal row
    // holds it. `terminal_from_stored` stays in the loop, so a host row that
    // does not parse is said at its terminal, as before.
    let hosts = {
        let mut statement = transaction.prepare(
            "SELECT r.terminal_id, h.terminal_id, h.workspace_key, h.incarnation, h.lifecycle,
                    h.launch_spec_json, h.exit_json, h.on_exit
             FROM resource_terminals r
             JOIN terminal_hosts h ON h.terminal_id = r.terminal_id
             WHERE r.deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                let stored: StoredTerminal = (
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                );
                Ok((row.get::<_, String>(0)?, stored))
            })?
            .collect::<Result<HashMap<_, _>, _>>()?
    };
    for (public_id, terminal_id, lifecycle) in &terminals {
        if lifecycle != "active" {
            anyhow::bail!("live terminal {public_id} has lifecycle {lifecycle}");
        }
        let placement =
            hosts.get(terminal_id.as_str()).cloned().map(terminal_from_stored).transpose()?;
        if placement
            .as_ref()
            .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned)
        {
            anyhow::bail!("terminal resource {public_id} has no live placement");
        }
    }
    let browsers = {
        let mut statement = transaction.prepare(
            "SELECT public_id, url, metadata_json, lifecycle
             FROM resource_browsers WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (browser_id, url, metadata, lifecycle) in browsers {
        if lifecycle != "running" {
            anyhow::bail!("live browser {browser_id} is not running");
        }
        let metadata =
            metadata.ok_or_else(|| anyhow::anyhow!("browser {browser_id} has no metadata"))?;
        let browser: RegistryBrowser = serde_json::from_str(&metadata)
            .with_context(|| format!("invalid metadata for browser {browser_id}"))?;
        validate_registry_browser(&browser)?;
        if browser.public_id.as_str() != browser_id || browser.url != url {
            anyhow::bail!("browser {browser_id} metadata does not match its indexed fields");
        }
    }
    Ok(())
}

fn validate_concrete_identity_lifecycles(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    for (table, kind) in [
        ("resource_workspaces", "workspace"),
        ("resource_screens", "screen"),
        ("resource_panes", "pane"),
        ("resource_tabs", "tab"),
        ("resource_terminals", "terminal"),
        ("resource_browsers", "browser"),
    ] {
        let query = format!(
            "SELECT r.public_id
             FROM {table} r
             LEFT JOIN resource_identities i ON i.public_id = r.public_id
             WHERE i.public_id IS NULL OR i.kind != ?1
                OR ((r.deleted_revision IS NULL) != (i.deleted_revision IS NULL))
             LIMIT 1"
        );
        let mismatch =
            transaction.query_row(&query, [kind], |row| row.get::<_, String>(0)).optional()?;
        if let Some(public_id) = mismatch {
            anyhow::bail!("{kind} row {public_id} disagrees with its identity ledger");
        }
    }
    Ok(())
}

pub(super) fn validate_contiguous_positions(
    transaction: &Transaction<'_>,
    query: &str,
    kind: &str,
) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(query)?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut next_by_parent = HashMap::<String, i64>::new();
    for (parent, position) in rows {
        let expected = next_by_parent.entry(parent.clone()).or_default();
        if position != *expected {
            anyhow::bail!(
                "{kind} positions under {parent:?} are not contiguous: expected {}, found {position}",
                *expected
            );
        }
        *expected += 1;
    }
    Ok(())
}
