//! `private-tabs-v1`: a private (incognito) tab can sit in any workspace,
//! mixed with normal tabs, like an incognito tab in a normal Chrome window
//! (Leo, 2026-11-18: "drop the 9/30 rule and allow private tabs anywhere").
//! Before it, privacy belonged to a whole workspace (`workspace_state.ephemeral`,
//! an incognito window's) and nothing moved between such a workspace and a
//! normal one (the 2026-09-30 rule, `ephemeral_moves`).
//!
//! A tab is private when its row is here or its workspace is ephemeral. The
//! row is keyed by the tab's public id (never reused), so it follows the tab
//! through every move. It is written when the tab is created private
//! (`new-frontend-browser-tab {private: true}`) and when a tab leaves an
//! ephemeral workspace for a normal one (`ephemeral_moves`), so a tab of an
//! incognito window stays private wherever it goes.
//!
//! What a private tab never leaves behind: a closed-history record
//! (`closed_history_store::tab_record`), and the tab itself after the daemon
//! stops: the next start closes every private tab an earlier run left
//! ([`Mux::close_private_tabs`]), as it closes ephemeral workspaces. The
//! workspace that held one stays; Home, which never closes, reopens as it
//! was, without the private tab.

use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::json;

use crate::Actor;
use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::state::values::fresh_upserts;

/// Advertised by `identify` once `new-frontend-browser-tab` takes `private`
/// and a tab's `extra.private` names a private tab.
pub(crate) const PRIVATE_TABS_CAPABILITY: &str = "private-tabs-v1";

pub(crate) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS private_tabs (
           tab_id TEXT PRIMARY KEY NOT NULL
         );",
    )?;
    Ok(())
}

/// Mark tab `tab_id` (a public id) private. Returns whether it was not yet.
pub(crate) fn mark_private(transaction: &Transaction<'_>, tab_id: &str) -> anyhow::Result<bool> {
    Ok(transaction.execute("INSERT OR IGNORE INTO private_tabs(tab_id) VALUES(?1)", [tab_id])? > 0)
}

/// Whether tab `tab_id` carries its own private mark (not its workspace's).
/// False before the table exists.
pub(crate) fn is_marked(connection: &Connection, tab_id: &str) -> anyhow::Result<bool> {
    if !table_ready(connection)? {
        return Ok(false);
    }
    Ok(crate::state::values::query_row_cached(
        connection,
        "SELECT 1 FROM private_tabs WHERE tab_id = ?1",
        [tab_id],
        |_| Ok(()),
    )
    .optional()?
    .is_some())
}

/// The live tabs marked private, by public id: what the daemon closes at start.
pub(crate) fn live_private_tabs(connection: &Connection) -> anyhow::Result<Vec<String>> {
    if !table_ready(connection)? {
        return Ok(Vec::new());
    }
    let mut statement = connection.prepare(
        "SELECT p.tab_id FROM private_tabs AS p
         JOIN resource_tabs AS t ON t.public_id = p.tab_id
         WHERE t.deleted_revision IS NULL",
    )?;
    Ok(statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
}

/// Every tab marked private, live or closed (a list's `extra` joins the live ones itself).
pub(crate) fn marked_tabs(
    connection: &Connection,
) -> anyhow::Result<std::collections::HashSet<String>> {
    if !table_ready(connection)? {
        return Ok(Default::default());
    }
    let mut statement = connection.prepare("SELECT tab_id FROM private_tabs")?;
    Ok(statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<_, _>>()?)
}

/// Whether screen `screen_id` (a public id) holds live tabs and every one is
/// private: closed history records no such screen, nor a workspace of only
/// such screens (an empty container would reopen in their place).
pub(crate) fn screen_holds_only_private_tabs(
    connection: &Connection,
    screen_id: &str,
) -> anyhow::Result<bool> {
    if !table_ready(connection)? {
        return Ok(false);
    }
    let (tabs, private): (i64, i64) = connection.query_row(
        "SELECT COUNT(*), COUNT(p.tab_id) FROM resource_tabs AS t
         JOIN resource_panes AS pane ON pane.public_id = t.pane_id
         LEFT JOIN private_tabs AS p ON p.tab_id = t.public_id
         WHERE pane.screen_id = ?1 AND pane.deleted_revision IS NULL
           AND t.deleted_revision IS NULL",
        [screen_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok(tabs > 0 && tabs == private)
}

fn table_ready(connection: &Connection) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'private_tabs'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

impl Mux {
    /// Mark the tab that `surface` shows private, in its own state commit; the
    /// tab's `tab-changed` then carries `extra.private`. The tab's record holds
    /// only what the app wrote for it (a private page's address stays in the
    /// app), so a crash before this commit leaves a blank, normal tab.
    pub(crate) fn mark_tab_private(self: &Arc<Self>, surface: SurfaceId) -> anyhow::Result<()> {
        let tab = self
            .with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())
            .context("the private tab has no public id")?
            .to_string();
        let fingerprint = json!({"operation": "tab.mark_private", "tab": tab});
        self.commit_state(
            &WorkspaceMutation::daemon_local("cmux-tui-private-tab"),
            "tab.mark_private",
            &fingerprint,
            None,
            StateEffects::NOTES,
            |transaction, _| {
                if !mark_private(transaction, &tab)? {
                    return Ok(StateChanges::unchanged(json!({"tab": tab})));
                }
                // The tab's upsert carries `extra.private`: `session.events`
                // followers (the app's state mirror) learn the mark from it.
                let changes = fresh_upserts(transaction, &[], &[], std::slice::from_ref(&tab))?;
                Ok(StateChanges::new(json!({"tab": tab}), changes))
            },
        )?;
        self.emit_tab_changed(surface);
        Ok(())
    }

    /// Close every private tab an earlier run left (a quit or a crash), in
    /// whatever workspace holds it. Runs once at daemon start, after the
    /// ephemeral workspaces closed (their tabs went with them).
    pub(crate) fn close_private_tabs(self: &Arc<Self>) -> anyhow::Result<()> {
        let private = self.read_registry_state(live_private_tabs)?;
        if !private.is_empty() {
            self.close_tabs_left_private(&private);
        }
        self.forget_closed_private_tabs()
    }

    /// Drop the marks of tabs that are gone: closed history judged them at
    /// their close, so the table holds only live tabs after each start and
    /// never grows with every private tab ever opened.
    fn forget_closed_private_tabs(self: &Arc<Self>) -> anyhow::Result<()> {
        let stale: i64 = self.read_registry_state(|connection| {
            if !table_ready(connection)? {
                return Ok(0);
            }
            Ok(connection.query_row(
                "SELECT COUNT(*) FROM private_tabs WHERE tab_id NOT IN
                   (SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL)",
                [],
                |row| row.get(0),
            )?)
        })?;
        if stale == 0 {
            return Ok(());
        }
        self.commit_state(
            &WorkspaceMutation::daemon_local("cmux-tui-private-tab"),
            "tab.forget_closed_private",
            &json!({"operation": "tab.forget_closed_private", "rows": stale}),
            None,
            StateEffects::NOTES,
            |transaction, _| {
                transaction.execute(
                    "DELETE FROM private_tabs WHERE tab_id NOT IN
                       (SELECT public_id FROM resource_tabs WHERE deleted_revision IS NULL)",
                    [],
                )?;
                Ok(StateChanges::new(json!({"rows": stale}), Vec::new()))
            },
        )?;
        Ok(())
    }

    fn close_tabs_left_private(self: &Arc<Self>, private: &[String]) {
        let private = private.iter().map(String::as_str).collect::<std::collections::HashSet<_>>();
        let surfaces = self.with_state(|state| {
            state
                .resource_indexes
                .tab_ids
                .iter()
                .filter(|(_, tab)| private.contains(tab.as_str()))
                .map(|(surface, _)| *surface)
                .collect::<Vec<_>>()
        });
        for surface in surfaces {
            if let Err(error) = self.close_surface_as(&Actor::Daemon, surface) {
                eprintln!(
                    "cmux-tui: could not close a private tab left by an earlier run: {error:#}"
                );
            }
        }
    }
}
