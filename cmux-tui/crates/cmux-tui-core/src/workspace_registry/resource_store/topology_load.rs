//! Loading the stored resource topology: all of it, or the subtrees of a set
//! of workspaces.

use super::*;

impl WorkspaceRegistry {
    /// The stored subtrees of `workspaces` only; see
    /// [`load_resource_topology_scoped`].
    pub(crate) fn resource_topology_scoped(
        &self,
        workspaces: &[WorkspacePublicId],
    ) -> anyhow::Result<ResourceTopologySnapshot> {
        load_resource_topology_scoped(
            &self.connection,
            self.session_id.clone(),
            self.generation.clone(),
            workspaces,
        )
    }

    /// One terminal's durable record unless it is tombstoned, as
    /// [`Self::terminal_snapshot`] lists it.
    pub(crate) fn live_terminal_record(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<RegistryTerminal>> {
        Ok(self
            .terminal_record(terminal_id)?
            .filter(|terminal| terminal.lifecycle != TerminalLifecycle::Tombstoned))
    }

    /// The host of every active stored terminal row that a live tab of
    /// `panes` shows, keyed by terminal public id.
    pub(crate) fn active_terminal_hosts_of_panes(
        &self,
        panes: &[PanePublicId],
    ) -> anyhow::Result<HashMap<TerminalPublicId, String>> {
        let mut statement = self.connection.prepare(
            "SELECT rt.public_id, rt.terminal_id
             FROM resource_tabs t
             JOIN resource_terminals rt ON rt.public_id = t.content_id
             WHERE t.pane_id = ?1 AND t.deleted_revision IS NULL
               AND rt.deleted_revision IS NULL AND rt.lifecycle = 'active'",
        )?;
        let mut hosts = HashMap::new();
        for pane in panes {
            let rows = statement.query_map([pane.as_str()], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?;
            for row in rows {
                let (terminal, host) = row?;
                hosts.insert(TerminalPublicId::parse(terminal)?, host);
            }
        }
        Ok(hosts)
    }

    /// The live tab rows that show `content_id`, in no particular order.
    pub(crate) fn resource_tabs_of_content(
        &self,
        content_id: &str,
    ) -> anyhow::Result<Vec<RegistryTab>> {
        load_tabs(&self.connection, " AND t.content_id = ?1", &[&content_id])
    }

    /// Whether a live `resource` row ("screen", "pane" or "tab") has this
    /// public id.
    pub(crate) fn resource_is_live(&self, resource: &str, public_id: &str) -> anyhow::Result<bool> {
        let table = match resource {
            "screen" => "resource_screens",
            "pane" => "resource_panes",
            "tab" => "resource_tabs",
            _ => anyhow::bail!("no stored liveness for resource {resource:?}"),
        };
        Ok(self
            .connection
            .prepare(&format!(
                "SELECT 1 FROM {table} WHERE public_id = ?1 AND deleted_revision IS NULL"
            ))?
            .query_row([public_id], |_| Ok(()))
            .optional()?
            .is_some())
    }
}

/// Load the live resource topology from `connection`. The registry's
/// snapshot and the startup repair (which runs inside the open transaction,
/// before this open's generation exists) share it.
pub(crate) fn load_resource_topology(
    connection: &Connection,
    session_id: SessionPublicId,
    generation: String,
) -> anyhow::Result<ResourceTopologySnapshot> {
    let mut topology = load_topology_frame(connection, session_id, generation)?;
    topology.screens =
        screen_rows::with_side_tables(connection, load_screens(connection, "", &[])?)?;
    topology.panes = load_panes(connection, "", &[])?;
    topology.tabs = load_tabs(connection, "", &[])?;
    topology.browsers = load_browsers(connection, "", &[])?;
    Ok(topology)
}

/// The stored subtrees (screens, panes, tabs and their browsers) of
/// `workspaces` only, with the complete workspace list, active workspace and
/// revision. A scoped projection diffs against this, so its read cost follows
/// the size of the workspaces it changes, not the size of the session.
pub(crate) fn load_resource_topology_scoped(
    connection: &Connection,
    session_id: SessionPublicId,
    generation: String,
    workspaces: &[WorkspacePublicId],
) -> anyhow::Result<ResourceTopologySnapshot> {
    let mut topology = load_topology_frame(connection, session_id, generation)?;
    let mut screens = Vec::new();
    for workspace in workspaces {
        screens.extend(load_screens(connection, " AND workspace_id = ?1", &[&workspace.as_str()])?);
    }
    topology.screens = screen_rows::with_side_tables(connection, screens)?;
    for screen in &topology.screens {
        let panes = load_panes(connection, " AND screen_id = ?1", &[&screen.public_id.as_str()])?;
        topology.panes.extend(panes);
    }
    for pane in &topology.panes {
        topology.tabs.extend(load_tabs(
            connection,
            " AND t.pane_id = ?1",
            &[&pane.public_id.as_str()],
        )?);
    }
    for tab in &topology.tabs {
        if let ContentPublicId::Browser(browser) = &tab.content_id {
            topology.browsers.extend(load_browsers(
                connection,
                " AND public_id = ?1",
                &[&browser.as_str()],
            )?);
        }
    }
    Ok(topology)
}

/// Revision, active workspace and every live workspace's active screen.
fn load_topology_frame(
    connection: &Connection,
    session_id: SessionPublicId,
    generation: String,
) -> anyhow::Result<ResourceTopologySnapshot> {
    let revision = current_resource_revision(connection)?;
    let active_workspace =
        meta_value(connection, "active_workspace_id")?.map(WorkspacePublicId::parse).transpose()?;
    let active_screens = {
        let mut statement = connection.prepare(
            "SELECT public_id, active_screen_id
             FROM resource_workspaces
             WHERE deleted_revision IS NULL
             ORDER BY created_revision ASC, public_id ASC",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)))?
            .map(|row| {
                let (workspace, screen) = row?;
                Ok((
                    WorkspacePublicId::parse(workspace)?,
                    screen.map(ScreenPublicId::parse).transpose()?,
                ))
            })
            .collect::<anyhow::Result<Vec<_>>>()?
    };
    Ok(ResourceTopologySnapshot {
        session_id,
        generation,
        revision,
        active_workspace,
        active_screens,
        screens: Vec::new(),
        panes: Vec::new(),
        tabs: Vec::new(),
        browsers: Vec::new(),
    })
}

fn load_screens(
    connection: &Connection,
    filter: &str,
    params: &[&dyn rusqlite::ToSql],
) -> anyhow::Result<Vec<RegistryScreen>> {
    let mut statement = connection.prepare(&format!(
        "SELECT public_id, workspace_id, position, name, layout_json,
                active_pane_id, zoomed_pane_id, auto_layout_json, viewport_json
         FROM resource_screens
         WHERE deleted_revision IS NULL{filter}
         ORDER BY workspace_id ASC, position ASC",
    ))?;
    statement
        .query_map(params, |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, String>(8)?,
            ))
        })?
        .map(|row| {
            let (
                public_id,
                workspace_id,
                position,
                name,
                layout,
                active_pane,
                zoomed_pane,
                auto_layout,
                viewport,
            ) = row?;
            Ok(RegistryScreen {
                public_id: ScreenPublicId::parse(public_id)?,
                workspace_id: WorkspacePublicId::parse(workspace_id)?,
                position: usize::try_from(position)
                    .context("stored screen position is negative")?,
                name,
                layout: serde_json::from_str(&layout)?,
                active_pane: PanePublicId::parse(active_pane)?,
                zoomed_pane: zoomed_pane.map(PanePublicId::parse).transpose()?,
                auto_layout: auto_layout.map(|value| serde_json::from_str(&value)).transpose()?,
                viewport: serde_json::from_str(&viewport)?,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()
}

fn load_panes(
    connection: &Connection,
    filter: &str,
    params: &[&dyn rusqlite::ToSql],
) -> anyhow::Result<Vec<RegistryPane>> {
    let mut statement = connection.prepare(&format!(
        "SELECT public_id, screen_id, name, active_tab_id, creation_ordinal
         FROM resource_panes
         WHERE deleted_revision IS NULL{filter}
         ORDER BY screen_id ASC, creation_ordinal ASC, public_id ASC",
    ))?;
    statement
        .query_map(params, |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })?
        .map(|row| {
            let (public_id, screen_id, name, active_tab, creation_ordinal) = row?;
            Ok(RegistryPane {
                public_id: PanePublicId::parse(public_id)?,
                screen_id: ScreenPublicId::parse(screen_id)?,
                name,
                active_tab: active_tab.map(TabPublicId::parse).transpose()?,
                creation_ordinal: u64::try_from(creation_ordinal)
                    .context("stored pane creation ordinal is negative")?,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()
}

pub(super) fn load_tabs(
    connection: &Connection,
    filter: &str,
    params: &[&dyn rusqlite::ToSql],
) -> anyhow::Result<Vec<RegistryTab>> {
    let mut statement = connection.prepare(&format!(
        "SELECT t.public_id, t.pane_id, t.position, t.content_kind,
                t.content_id, t.name, b.url, rt.terminal_id, t.name_source, t.name_revision
         FROM resource_tabs t
         LEFT JOIN resource_browsers b ON b.public_id = t.content_id
         LEFT JOIN resource_terminals rt ON rt.public_id = t.content_id
         WHERE t.deleted_revision IS NULL{filter}
         ORDER BY t.pane_id ASC, t.position ASC",
    ))?;
    statement
        .query_map(params, |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, Option<String>>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, String>(8)?,
                row.get::<_, i64>(9)?,
            ))
        })?
        .map(|row| {
            let (
                public_id,
                pane_id,
                position,
                kind,
                content_id,
                name,
                browser_url,
                terminal_id,
                name_source,
                name_revision,
            ) = row?;
            let content_id = match kind.as_str() {
                "terminal" => ContentPublicId::Terminal(TerminalPublicId::parse(content_id)?),
                "browser" => ContentPublicId::Browser(BrowserPublicId::parse(content_id)?),
                _ => anyhow::bail!("stored tab has invalid content kind {kind:?}"),
            };
            Ok(RegistryTab {
                public_id: TabPublicId::parse(public_id)?,
                pane_id: PanePublicId::parse(pane_id)?,
                position: usize::try_from(position).context("stored tab position is negative")?,
                content_id,
                name,
                name_source: serde_json::from_value(json!(name_source))?,
                name_revision: u64::try_from(name_revision).context("negative name revision")?,
                browser_url,
                terminal_id,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()
}

fn load_browsers(
    connection: &Connection,
    filter: &str,
    params: &[&dyn rusqlite::ToSql],
) -> anyhow::Result<Vec<RegistryBrowser>> {
    let mut statement = connection.prepare(&format!(
        "SELECT public_id, url, metadata_json
         FROM resource_browsers
         WHERE deleted_revision IS NULL{filter}
         ORDER BY public_id ASC",
    ))?;
    statement
        .query_map(params, |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })?
        .map(|row| {
            let (public_id, url, metadata) = row?;
            let browser: RegistryBrowser = serde_json::from_str(&metadata)
                .with_context(|| format!("invalid metadata for browser {public_id}"))?;
            validate_registry_browser(&browser)?;
            if browser.public_id.as_str() != public_id || browser.url != url {
                anyhow::bail!("browser {public_id} metadata does not match its indexed fields");
            }
            Ok(browser)
        })
        .collect::<anyhow::Result<Vec<_>>>()
}
