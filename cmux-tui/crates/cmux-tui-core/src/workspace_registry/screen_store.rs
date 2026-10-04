//! Durable screen presentation: each screen's color, icon, and pin, the
//! Screen groups of every workspace, and saved screen groups.
//!
//! The same rules as `presentation_store` apply: every table is additive with
//! no foreign key, so an older binary ignores them and no schema version bump
//! is needed. Screen rows are keyed by the public screen id (`screen_...`);
//! rows that name a tombstoned screen are inert because snapshots join
//! against live screens. Each write appends one advisory `state` journal
//! record; the tables are authoritative for restoration.

use std::collections::{BTreeMap, HashSet};

use anyhow::Context;
use rusqlite::{Connection, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

use super::presentation_store::{
    append_presentation_record, validate_presentation_color, validate_presentation_icon,
    validate_tab_group_color, validate_tab_group_name, validate_workspace_group_id,
};
use super::{JournalSubject, WorkspaceRegistry, new_uuid_v4};

pub(crate) fn create_screen_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    // A registry written by the state-resources daemon before the two
    // screen storages were merged keeps screen rows in `screen_state` and
    // groups keyed by the public workspace id. Move them here once.
    let legacy_groups = table_has_column(transaction, "screen_groups", "workspace_id")?;
    if legacy_groups {
        transaction.execute_batch("ALTER TABLE screen_groups RENAME TO screen_groups_state_v1;")?;
    }
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS screen_presentation (
           screen_id TEXT PRIMARY KEY NOT NULL,
           color TEXT,
           icon TEXT,
           pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1))
         );
         CREATE TABLE IF NOT EXISTS screen_groups (
           group_id TEXT PRIMARY KEY NOT NULL,
           workspace_key TEXT NOT NULL,
           name TEXT NOT NULL DEFAULT '',
           color TEXT NOT NULL,
           collapsed INTEGER NOT NULL DEFAULT 0 CHECK(collapsed IN (0,1)),
           saved_id TEXT
         );
         CREATE TABLE IF NOT EXISTS screen_group_members (
           screen_id TEXT PRIMARY KEY NOT NULL,
           group_id TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS saved_screen_groups (
           saved_id TEXT PRIMARY KEY NOT NULL,
           name TEXT NOT NULL DEFAULT '',
           color TEXT NOT NULL,
           profile_id TEXT,
           members_json TEXT NOT NULL,
           position INTEGER NOT NULL CHECK(position >= 0),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
         );",
    )?;
    if legacy_groups {
        transaction.execute_batch(
            "INSERT OR IGNORE INTO screen_groups(group_id, workspace_key, name, color, collapsed)
             SELECT g.group_id, w.workspace_key, g.name, g.color, g.collapsed
             FROM screen_groups_state_v1 AS g
             JOIN resource_workspaces AS w ON w.public_id = g.workspace_id;
             DROP TABLE screen_groups_state_v1;
             DELETE FROM screen_group_members
             WHERE group_id NOT IN (SELECT group_id FROM screen_groups);",
        )?;
    }
    if table_exists(transaction, "screen_state")? {
        transaction.execute_batch(
            "INSERT OR IGNORE INTO screen_presentation(screen_id, color, icon, pinned)
             SELECT screen_id, color, icon, pinned FROM screen_state;
             DROP TABLE screen_state;",
        )?;
    }
    Ok(())
}

fn table_exists(connection: &Connection, table: &str) -> anyhow::Result<bool> {
    Ok(connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
        [table],
        |row| row.get::<_, bool>(0),
    )?)
}

fn table_has_column(connection: &Connection, table: &str, column: &str) -> anyhow::Result<bool> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns =
        statement.query_map([], |row| row.get::<_, String>(1))?.collect::<Result<Vec<_>, _>>()?;
    Ok(columns.iter().any(|name| name == column))
}

/// Color, icon, and pin of one screen. A record with no field set is not
/// stored.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenPresentationRecord {
    pub color: Option<String>,
    pub icon: Option<String>,
    pub pinned: bool,
}

impl ScreenPresentationRecord {
    pub fn is_empty(&self) -> bool {
        self.color.is_none() && self.icon.is_none() && !self.pinned
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        if let Some(color) = &self.color {
            validate_presentation_color(color)?;
        }
        if let Some(icon) = &self.icon {
            validate_presentation_icon(icon)?;
        }
        Ok(())
    }
}

/// One screen group of one workspace. Members are the screens mapped to it
/// in [`ScreenPresentationState::members`]; commands keep them contiguous.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScreenGroupRecord {
    pub id: String,
    /// Stable key of the workspace whose screens the group holds.
    pub workspace_key: String,
    pub name: String,
    /// One of the nine tab group colors.
    pub color: String,
    pub collapsed: bool,
    /// The saved screen group this live group syncs with.
    pub saved_id: Option<String>,
}

/// Every screen's presentation plus all screen groups and their members.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct ScreenPresentationState {
    /// Public screen id to its presentation.
    pub screens: BTreeMap<String, ScreenPresentationRecord>,
    pub groups: BTreeMap<String, ScreenGroupRecord>,
    /// Public screen id to group id.
    pub members: BTreeMap<String, String>,
}

impl ScreenPresentationState {
    pub fn screen(&self, screen_id: &str) -> Option<&ScreenPresentationRecord> {
        self.screens.get(screen_id)
    }

    pub fn is_pinned(&self, screen_id: &str) -> bool {
        self.screens.get(screen_id).is_some_and(|record| record.pinned)
    }

    /// Edit one screen's record in place, dropping it when it becomes empty.
    pub fn edit(&mut self, screen_id: &str, edit: impl FnOnce(&mut ScreenPresentationRecord)) {
        let mut record = self.screens.remove(screen_id).unwrap_or_default();
        edit(&mut record);
        if !record.is_empty() {
            self.screens.insert(screen_id.to_string(), record);
        }
    }
}

/// What a saved screen group remembers about one member screen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SavedScreenMember {
    pub name: Option<String>,
    pub color: Option<String>,
    pub icon: Option<String>,
    /// Directory of the screen's active terminal when it was saved.
    pub cwd: Option<String>,
}

/// A saved screen group: a session-wide record that outlives its screens.
/// `profile_id` names the room it belongs to (nil = `default`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SavedScreenGroupRecord {
    pub id: String,
    pub name: String,
    pub color: String,
    pub profile_id: Option<String>,
    pub members: Vec<SavedScreenMember>,
    pub updated_at_ms: u64,
}

pub fn new_screen_group_id() -> String {
    format!("sgrp_{}", new_uuid_v4().replace('-', ""))
}

pub fn new_saved_screen_group_id() -> String {
    format!("ssaved_{}", new_uuid_v4().replace('-', ""))
}

fn validate_screen_group(group: &ScreenGroupRecord) -> anyhow::Result<()> {
    validate_workspace_group_id(&group.id)?;
    validate_tab_group_name(&group.name)?;
    validate_tab_group_color(&group.color)
}

/// Replace every screen presentation, group, and membership row in the
/// caller's transaction.
pub(crate) fn write_screen_state(
    transaction: &Transaction<'_>,
    state: &ScreenPresentationState,
) -> anyhow::Result<()> {
    for record in state.screens.values() {
        record.validate()?;
    }
    for group in state.groups.values() {
        validate_screen_group(group)?;
    }
    require_new_screen_icons(transaction, state)?;
    transaction.execute("DELETE FROM screen_presentation", [])?;
    transaction.execute("DELETE FROM screen_groups", [])?;
    transaction.execute("DELETE FROM screen_group_members", [])?;
    for (screen, record) in &state.screens {
        if record.is_empty() {
            continue;
        }
        transaction.execute(
            "INSERT INTO screen_presentation(screen_id, color, icon, pinned) VALUES(?1, ?2, ?3, ?4)",
            params![screen, record.color, record.icon, i64::from(record.pinned)],
        )?;
    }
    for group in state.groups.values() {
        transaction.execute(
            "INSERT INTO screen_groups(group_id, workspace_key, name, color, collapsed, saved_id)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                group.id,
                group.workspace_key,
                group.name,
                group.color,
                i64::from(group.collapsed),
                group.saved_id
            ],
        )?;
    }
    for (screen, group) in &state.members {
        anyhow::ensure!(
            state.groups.contains_key(group),
            "screen {screen} names unknown group {group}"
        );
        transaction.execute(
            "INSERT INTO screen_group_members(screen_id, group_id) VALUES(?1, ?2)",
            params![screen, group],
        )?;
    }
    append_presentation_record(
        transaction,
        "screen.presentation.updated",
        state
            .groups
            .keys()
            .map(|id| JournalSubject { kind: "screen_group".into(), id: id.clone() })
            .collect(),
        &json!({"screens": state}),
    )
}

/// Every screen icon this write adds must name a stored asset. Icons the
/// table already holds are not checked again: the whole table is rewritten.
fn require_new_screen_icons(
    transaction: &Transaction<'_>,
    state: &ScreenPresentationState,
) -> anyhow::Result<()> {
    let stored = {
        let mut statement = transaction
            .prepare("SELECT DISTINCT icon FROM screen_presentation WHERE icon IS NOT NULL")?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    for icon in state.screens.values().filter_map(|record| record.icon.as_ref()) {
        if !stored.contains(icon) {
            super::personal_store::require_icon_asset(transaction, icon)?;
        }
    }
    Ok(())
}

pub(crate) fn read_screen_state(
    connection: &Connection,
) -> anyhow::Result<ScreenPresentationState> {
    let mut state = ScreenPresentationState::default();
    let mut statement = connection.prepare(
        "SELECT p.screen_id, p.color, p.icon, p.pinned FROM screen_presentation AS p
         JOIN resource_screens AS s ON s.public_id = p.screen_id
         WHERE s.deleted_revision IS NULL",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            ScreenPresentationRecord {
                color: row.get(1)?,
                icon: row.get(2)?,
                pinned: row.get::<_, i64>(3)? != 0,
            },
        ))
    })?;
    for row in rows {
        let (screen, record) = row?;
        if !record.is_empty() {
            state.screens.insert(screen, record);
        }
    }
    let mut statement = connection.prepare(
        "SELECT group_id, workspace_key, name, color, collapsed, saved_id FROM screen_groups",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(ScreenGroupRecord {
            id: row.get(0)?,
            workspace_key: row.get(1)?,
            name: row.get(2)?,
            color: row.get(3)?,
            collapsed: row.get::<_, i64>(4)? != 0,
            saved_id: row.get(5)?,
        })
    })?;
    for row in rows {
        let group = row?;
        state.groups.insert(group.id.clone(), group);
    }
    let mut statement = connection.prepare(
        "SELECT m.screen_id, m.group_id FROM screen_group_members AS m
         JOIN resource_screens AS s ON s.public_id = m.screen_id
         WHERE s.deleted_revision IS NULL",
    )?;
    let rows =
        statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
    for row in rows {
        let (screen, group) = row?;
        if state.groups.contains_key(&group) {
            state.members.insert(screen, group);
        }
    }
    // A group left without a live member (its screens closed while the
    // daemon was down) is gone.
    let live: HashSet<&String> = state.members.values().collect();
    let empty =
        state.groups.keys().filter(|id| !live.contains(id)).cloned().collect::<Vec<String>>();
    for id in empty {
        state.groups.remove(&id);
    }
    Ok(state)
}

pub(crate) fn read_saved_screen_groups(
    connection: &Connection,
) -> anyhow::Result<Vec<SavedScreenGroupRecord>> {
    let mut statement = connection.prepare(
        "SELECT saved_id, name, color, profile_id, members_json, updated_at_ms
         FROM saved_screen_groups ORDER BY position ASC, saved_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, i64>(5)?,
        ))
    })?;
    let mut saved = Vec::new();
    for row in rows {
        let (id, name, color, profile_id, members, updated_at_ms) = row?;
        saved.push(SavedScreenGroupRecord {
            id,
            name,
            color,
            profile_id,
            members: serde_json::from_str(&members)
                .context("saved screen group members are invalid")?,
            updated_at_ms: u64::try_from(updated_at_ms)?,
        });
    }
    Ok(saved)
}

impl WorkspaceRegistry {
    /// Public ids of a workspace's live screens in stored order (tests).
    #[cfg(test)]
    pub(crate) fn live_screen_order(
        &self,
        workspace_public_id: &str,
    ) -> anyhow::Result<Vec<String>> {
        let mut statement = self.connection.prepare(
            "SELECT public_id FROM resource_screens
             WHERE workspace_id = ?1 AND deleted_revision IS NULL ORDER BY position ASC",
        )?;
        let rows = statement.query_map([workspace_public_id], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Replace every screen presentation row (metadata-only changes that
    /// leave screen order alone).
    pub fn replace_screen_state(&mut self, state: &ScreenPresentationState) -> anyhow::Result<()> {
        let tx = self.connection.transaction()?;
        write_screen_state(&tx, state)?;
        tx.commit()?;
        Ok(())
    }

    /// Create or replace a saved screen group, keeping its position (new
    /// records go last).
    pub fn put_saved_screen_group(
        &mut self,
        record: &SavedScreenGroupRecord,
    ) -> anyhow::Result<()> {
        validate_workspace_group_id(&record.id)?;
        validate_tab_group_name(&record.name)?;
        validate_tab_group_color(&record.color)?;
        let tx = self.connection.transaction()?;
        let position: i64 = tx.query_row(
            "SELECT COALESCE(
               (SELECT position FROM saved_screen_groups WHERE saved_id = ?1),
               (SELECT COALESCE(MAX(position) + 1, 0) FROM saved_screen_groups))",
            [&record.id],
            |row| row.get(0),
        )?;
        tx.execute(
            "INSERT INTO saved_screen_groups(saved_id, name, color, profile_id, members_json, position, updated_at_ms)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(saved_id) DO UPDATE SET
               name = excluded.name,
               color = excluded.color,
               profile_id = excluded.profile_id,
               members_json = excluded.members_json,
               updated_at_ms = excluded.updated_at_ms",
            params![
                record.id,
                record.name,
                record.color,
                record.profile_id,
                serde_json::to_string(&record.members)?,
                position,
                i64::try_from(record.updated_at_ms)?
            ],
        )?;
        append_presentation_record(
            &tx,
            "screen.saved_group.updated",
            vec![JournalSubject { kind: "saved_screen_group".into(), id: record.id.clone() }],
            &json!({"saved_group": record}),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Delete a saved screen group and unlink its live group. Returns
    /// whether it existed.
    pub fn delete_saved_screen_group(&mut self, saved_id: &str) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let removed =
            tx.execute("DELETE FROM saved_screen_groups WHERE saved_id = ?1", [saved_id])? > 0;
        if removed {
            tx.execute("UPDATE screen_groups SET saved_id = NULL WHERE saved_id = ?1", [saved_id])?;
            append_presentation_record(
                &tx,
                "screen.saved_group.deleted",
                vec![JournalSubject {
                    kind: "saved_screen_group".into(),
                    id: saved_id.to_string(),
                }],
                &json!({"saved_id": saved_id}),
            )?;
        }
        tx.commit()?;
        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A registry the state-resources daemon wrote (screen rows in
    /// `screen_state`, groups keyed by the public workspace id) opens with
    /// its screens and groups in this storage, and opening it again changes
    /// nothing.
    #[test]
    fn state_resource_screen_rows_move_into_screen_storage_once() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE resource_workspaces (
                   public_id TEXT PRIMARY KEY NOT NULL,
                   workspace_key TEXT UNIQUE NOT NULL,
                   deleted_revision INTEGER
                 );
                 INSERT INTO resource_workspaces(public_id, workspace_key) VALUES('ws_a', 'key-a');
                 CREATE TABLE screen_state (
                   screen_id TEXT PRIMARY KEY NOT NULL,
                   pinned INTEGER NOT NULL DEFAULT 0,
                   color TEXT,
                   icon TEXT
                 );
                 INSERT INTO screen_state VALUES('screen_1', 1, 'red', NULL);
                 CREATE TABLE screen_groups (
                   group_id TEXT PRIMARY KEY NOT NULL,
                   workspace_id TEXT NOT NULL,
                   name TEXT NOT NULL DEFAULT '',
                   color TEXT NOT NULL,
                   collapsed INTEGER NOT NULL DEFAULT 0
                 );
                 INSERT INTO screen_groups VALUES('sgrp_1', 'ws_a', 'Agents', 'blue', 1);
                 INSERT INTO screen_groups VALUES('sgrp_gone', 'ws_gone', 'Gone', 'red', 0);
                 CREATE TABLE screen_group_members (
                   screen_id TEXT PRIMARY KEY NOT NULL,
                   group_id TEXT NOT NULL
                 );
                 INSERT INTO screen_group_members VALUES('screen_2', 'sgrp_1');
                 INSERT INTO screen_group_members VALUES('screen_3', 'sgrp_gone');",
            )
            .unwrap();
        for _ in 0..2 {
            let tx = connection.transaction().unwrap();
            create_screen_schema(&tx).unwrap();
            tx.commit().unwrap();
        }
        let groups = connection
            .prepare("SELECT group_id, workspace_key, name, color, collapsed, saved_id FROM screen_groups")
            .unwrap()
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<String>>(5)?,
                ))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(
            groups,
            vec![("sgrp_1".into(), "key-a".into(), "Agents".into(), "blue".into(), 1, None)]
        );
        let members = connection
            .prepare("SELECT screen_id, group_id FROM screen_group_members")
            .unwrap()
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(members, vec![("screen_2".to_string(), "sgrp_1".to_string())]);
        let presentation = connection
            .query_row("SELECT screen_id, color, pinned FROM screen_presentation", [], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })
            .unwrap();
        assert_eq!(presentation, ("screen_1".to_string(), Some("red".to_string()), 1));
        assert!(!table_exists(&connection, "screen_state").unwrap());
        assert!(!table_exists(&connection, "screen_groups_state_v1").unwrap());
    }
}
