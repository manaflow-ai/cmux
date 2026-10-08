//! Browser profile records of the home session (capability
//! `browser-profiles-v1`, plans/cmux-next/data-model.md section 5): name,
//! color, icon, order and an optional import origin. Each browser engine of
//! the app keys its own storage by the id (`default` or a lowercase UUID);
//! the daemon keeps only the records. Workspace and room defaults stay in
//! `personal_workspaces.browser_profile_id` and `profiles.browser_profile_id`;
//! deleting a profile clears them in the same transaction.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::{Value, json};

use super::personal_store::{
    DEFAULT_PROFILE_ID, commit_personal, insertion_final_index, subject, validate_appearance,
    validate_browser_profile_ref, validate_name, validate_personal_json, write_order,
};
use super::{WorkspaceRegistry, new_uuid_v4};

/// The table and its `default` row. Additive and idempotent: it runs at
/// every open, so a registry migrated before this capability gains it.
pub(super) fn create_browser_profile_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS browser_profiles (
           browser_profile_id TEXT PRIMARY KEY NOT NULL,
           name TEXT NOT NULL,
           color TEXT,
           icon TEXT,
           position INTEGER NOT NULL CHECK(position >= 0),
           source_json TEXT
         );",
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO browser_profiles(browser_profile_id, name, position)
         SELECT ?1, 'Default', COALESCE(MAX(position) + 1, 0) FROM browser_profiles",
        [DEFAULT_PROFILE_ID],
    )?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalBrowserProfile {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub index: usize,
    /// Import origin (`browser`, `profile_dir`, `display_name`), or null.
    pub source: Option<Value>,
}

/// Fields of `create-browser-profile`.
#[derive(Debug, Clone, Default)]
pub struct BrowserProfileInput {
    pub id: Option<String>,
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub index: Option<usize>,
    pub source: Option<Value>,
}

/// Fields of `update-browser-profile`: `None` unchanged, `Some(None)` clears.
#[derive(Debug, Clone, Default)]
pub struct BrowserProfileUpdate {
    pub name: Option<String>,
    pub color: Option<Option<String>>,
    pub icon: Option<Option<String>>,
}

/// Result of `delete-browser-profile`: the defaults it cleared and the
/// bookmarks it deleted (`bookmarks-v1`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrowserProfileDeletion {
    pub cleared_workspaces: Vec<(String, String)>,
    pub cleared_rooms: Vec<String>,
    pub deleted_bookmarks: usize,
    /// The new `bookmarks_revision` when bookmarks were deleted.
    pub bookmarks_revision: Option<u64>,
}

pub(super) fn read_browser_profiles(
    connection: &Connection,
) -> anyhow::Result<Vec<PersonalBrowserProfile>> {
    let exists = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'browser_profiles'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !exists {
        return Ok(Vec::new());
    }
    let mut statement = connection.prepare(
        "SELECT browser_profile_id, name, color, icon, source_json FROM browser_profiles
         ORDER BY position ASC, browser_profile_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(4)?,
        ))
    })?;
    let mut profiles = Vec::new();
    for (index, row) in rows.enumerate() {
        let (id, name, color, icon, source) = row?;
        let source = source.map(|text| serde_json::from_str::<Value>(&text)).transpose().map_err(
            |error| anyhow::anyhow!("stored browser profile source is invalid: {error}"),
        )?;
        profiles.push(PersonalBrowserProfile { id, name, color, icon, index, source });
    }
    Ok(profiles)
}

fn read_browser_profile(
    connection: &Connection,
    id: &str,
) -> anyhow::Result<Option<PersonalBrowserProfile>> {
    Ok(read_browser_profiles(connection)?.into_iter().find(|profile| profile.id == id))
}

fn order(connection: &Connection) -> anyhow::Result<Vec<String>> {
    Ok(read_browser_profiles(connection)?.into_iter().map(|profile| profile.id).collect())
}

impl WorkspaceRegistry {
    /// Create a browser profile at `index` (default last). An existing id
    /// returns the stored record with `false`, so a retried import finds
    /// the profile it made.
    pub fn create_browser_profile(
        &mut self,
        input: BrowserProfileInput,
    ) -> anyhow::Result<(PersonalBrowserProfile, bool)> {
        let id = input.id.clone().unwrap_or_else(new_uuid_v4);
        validate_browser_profile_ref(&id)?;
        validate_name("browser profile name", &input.name)?;
        validate_appearance(input.color.as_deref(), input.icon.as_deref())?;
        let source = input
            .source
            .as_ref()
            .map(|source| validate_personal_json("source", source, true))
            .transpose()?;
        let tx = self.connection.transaction()?;
        if let Some(existing) = read_browser_profile(&tx, &id)? {
            return Ok((existing, false));
        }
        let mut ids = order(&tx)?;
        let index = input.index.unwrap_or(ids.len()).min(ids.len());
        tx.execute(
            "INSERT INTO browser_profiles(browser_profile_id, name, color, icon, position, source_json)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, input.name, input.color, input.icon, i64::try_from(ids.len())?, source],
        )?;
        ids.insert(index, id.clone());
        write_order(&tx, "browser_profiles", "browser_profile_id", &ids)?;
        let profile = read_browser_profile(&tx, &id)?
            .ok_or_else(|| anyhow::anyhow!("browser profile {id} vanished"))?;
        commit_personal(
            &tx,
            "personal.browser_profile.created",
            vec![subject("browser_profile", &id)],
            &json!({"browser_profile": profile}),
        )?;
        tx.commit()?;
        Ok((profile, true))
    }

    /// Rename, recolor or change the icon of a browser profile.
    pub fn update_browser_profile(
        &mut self,
        id: &str,
        update: BrowserProfileUpdate,
    ) -> anyhow::Result<(PersonalBrowserProfile, bool)> {
        validate_browser_profile_ref(id)?;
        if let Some(name) = &update.name {
            validate_name("browser profile name", name)?;
        }
        validate_appearance(
            update.color.as_ref().and_then(Option::as_deref),
            update.icon.as_ref().and_then(Option::as_deref),
        )?;
        let tx = self.connection.transaction()?;
        let before = read_browser_profile(&tx, id)?
            .ok_or_else(|| anyhow::anyhow!("unknown browser profile {id}"))?;
        if let Some(name) = &update.name {
            tx.execute(
                "UPDATE browser_profiles SET name = ?2 WHERE browser_profile_id = ?1",
                params![id, name],
            )?;
        }
        if let Some(color) = &update.color {
            tx.execute(
                "UPDATE browser_profiles SET color = ?2 WHERE browser_profile_id = ?1",
                params![id, color],
            )?;
        }
        if let Some(icon) = &update.icon {
            tx.execute(
                "UPDATE browser_profiles SET icon = ?2 WHERE browser_profile_id = ?1",
                params![id, icon],
            )?;
        }
        let after = read_browser_profile(&tx, id)?
            .ok_or_else(|| anyhow::anyhow!("unknown browser profile {id}"))?;
        let changed = after != before;
        if changed {
            commit_personal(
                &tx,
                "personal.browser_profile.updated",
                vec![subject("browser_profile", id)],
                &json!({"browser_profile": after}),
            )?;
        }
        tx.commit()?;
        Ok((after, changed))
    }

    /// Move a browser profile to an insertion index among browser profiles.
    pub fn move_browser_profile(
        &mut self,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalBrowserProfile, bool)> {
        validate_browser_profile_ref(id)?;
        let tx = self.connection.transaction()?;
        let mut ids = order(&tx)?;
        let old = ids
            .iter()
            .position(|candidate| candidate == id)
            .ok_or_else(|| anyhow::anyhow!("unknown browser profile {id}"))?;
        let new = insertion_final_index(old, index, ids.len());
        let changed = new != old;
        if changed {
            let moved = ids.remove(old);
            ids.insert(new, moved);
            write_order(&tx, "browser_profiles", "browser_profile_id", &ids)?;
            commit_personal(
                &tx,
                "personal.browser_profile.moved",
                vec![subject("browser_profile", id)],
                &json!({"browser_profile_id": id, "index": new}),
            )?;
        }
        let profile = read_browser_profile(&tx, id)?
            .ok_or_else(|| anyhow::anyhow!("unknown browser profile {id}"))?;
        tx.commit()?;
        Ok((profile, changed))
    }

    /// Delete a browser profile (never `default`), clear every workspace
    /// and room default that names it, and delete its bookmarks. The app
    /// removes the engine data.
    pub fn delete_browser_profile(&mut self, id: &str) -> anyhow::Result<BrowserProfileDeletion> {
        validate_browser_profile_ref(id)?;
        anyhow::ensure!(
            id != DEFAULT_PROFILE_ID,
            "bad request: the default browser profile cannot be deleted"
        );
        let tx = self.connection.transaction()?;
        anyhow::ensure!(read_browser_profile(&tx, id)?.is_some(), "unknown browser profile {id}");
        let cleared_workspaces = {
            let mut statement = tx.prepare(
                "SELECT session_id, workspace_key FROM personal_workspaces WHERE browser_profile_id = ?1
                 ORDER BY position ASC",
            )?;
            statement
                .query_map([id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let cleared_rooms = {
            let mut statement = tx.prepare(
                "SELECT profile_id FROM profiles WHERE browser_profile_id = ?1 ORDER BY position ASC",
            )?;
            statement
                .query_map([id], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?
        };
        tx.execute(
            "UPDATE personal_workspaces SET browser_profile_id = NULL WHERE browser_profile_id = ?1",
            [id],
        )?;
        tx.execute(
            "UPDATE profiles SET browser_profile_id = NULL WHERE browser_profile_id = ?1",
            [id],
        )?;
        tx.execute("DELETE FROM browser_profiles WHERE browser_profile_id = ?1", [id])?;
        let (deleted_bookmarks, bookmarks_revision) =
            super::personal_bookmarks::delete_profile_bookmarks(&tx, id)?;
        let ids = order(&tx)?;
        write_order(&tx, "browser_profiles", "browser_profile_id", &ids)?;
        commit_personal(
            &tx,
            "personal.browser_profile.deleted",
            vec![subject("browser_profile", id)],
            &json!({"browser_profile_id": id, "cleared_workspaces": cleared_workspaces,
                    "cleared_rooms": cleared_rooms, "deleted_bookmarks": deleted_bookmarks}),
        )?;
        tx.commit()?;
        Ok(BrowserProfileDeletion {
            cleared_workspaces,
            cleared_rooms,
            deleted_bookmarks,
            bookmarks_revision,
        })
    }
}
