//! Mutations of the personal state (`personal_store.rs`). Each returns the
//! final record and whether durable state changed; a change bumps
//! `personal_revision` and appends one journal record in the same
//! transaction. Rooms are called `profile` on the wire.

use std::collections::HashSet;

use rusqlite::{OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::personal_store::{
    DEFAULT_PROFILE_ID, PersonalGroup, PersonalProfile, PersonalSession, PersonalSnapshot,
    PersonalWorkspace, commit_personal, insertion_final_index, next_workspace_position, read_group,
    read_groups, read_profile, read_profiles, read_session, read_snapshot, read_workspaces,
    require_icon_asset, subject, validate_appearance, validate_browser_profile_ref, validate_name,
    validate_personal_json, validate_personal_workspace_key, validate_profile_defaults,
    validate_profile_id, validate_session_id, validate_theme, write_order,
};
use super::presentation_store::validate_workspace_group_id;
use super::{WorkspaceRegistry, new_uuid_v4, unix_epoch_ms};
mod inputs;
pub use inputs::{PersonalWorkspaceUpdate, ProfileDeletion, ProfileInput, ProfileUpdate};

pub fn new_profile_id() -> String {
    format!("prof_{}", new_uuid_v4().replace('-', ""))
}

fn qualified(session_id: &str, workspace_key: &str) -> String {
    format!("{session_id}/{workspace_key}")
}

fn optional_text(
    label: &str,
    value: Option<&str>,
    check: fn(&str) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    if let Some(value) = value {
        check(value).map_err(|error| anyhow::anyhow!("{label}: {error}"))?;
    }
    Ok(())
}

impl WorkspaceRegistry {
    pub fn personal_snapshot(&self) -> anyhow::Result<PersonalSnapshot> {
        read_snapshot(&self.connection)
    }

    pub fn personal_revision(&self) -> anyhow::Result<u64> {
        super::personal_store::personal_revision(&self.connection)
    }

    /// Create a room at `index` (default last). The same id and name again
    /// is an idempotent retry that returns the stored room with `false`.
    pub(crate) fn create_profile_in(
        tx: &Transaction<'_>,
        input: ProfileInput,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let id = input.id.clone().unwrap_or_else(new_profile_id);
        validate_profile_id(&id)?;
        validate_name("room name", &input.name)?;
        validate_appearance(input.color.as_deref(), input.icon.as_deref())?;
        optional_text("theme", input.theme.as_deref(), validate_theme)?;
        optional_text(
            "browser_profile_id",
            input.browser_profile_id.as_deref(),
            validate_browser_profile_ref,
        )?;
        optional_text(
            "default_session_id",
            input.default_session_id.as_deref(),
            validate_session_id,
        )?;
        let defaults = input.defaults.as_ref().map(validate_profile_defaults).transpose()?;
        for session in input.follows.iter().flatten() {
            validate_session_id(session)?;
        }
        if let Some(existing) = read_profile(tx, &id)? {
            anyhow::ensure!(
                existing.name == input.name,
                "room {id} already exists with a different name"
            );
            return Ok((existing, false));
        }
        input.icon.as_deref().map_or(Ok(()), |icon| require_icon_asset(tx, icon))?;
        let mut order =
            read_profiles(tx)?.into_iter().map(|profile| profile.id).collect::<Vec<_>>();
        let index = input.index.unwrap_or(order.len()).min(order.len());
        tx.execute(
            "INSERT INTO profiles(profile_id, name, color, icon, theme, position, browser_profile_id,
                                  default_session_id, defaults_json)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                id,
                input.name,
                input.color,
                input.icon,
                input.theme,
                i64::try_from(order.len())?,
                input.browser_profile_id,
                input.default_session_id,
                defaults
            ],
        )?;
        for session in input.follows.iter().flatten() {
            tx.execute(
                "INSERT OR IGNORE INTO profile_follows(profile_id, session_id) VALUES(?1, ?2)",
                params![id, session],
            )?;
        }
        order.insert(index, id.clone());
        write_order(tx, "profiles", "profile_id", &order)?;
        let profile =
            read_profile(tx, &id)?.ok_or_else(|| anyhow::anyhow!("room {id} vanished"))?;
        commit_personal(
            tx,
            "personal.profile.created",
            vec![subject("profile", &id)],
            &json!({"profile": profile}),
        )?;
        Ok((profile, true))
    }

    pub(crate) fn update_profile_in(
        tx: &Transaction<'_>,
        id: &str,
        update: ProfileUpdate,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        validate_profile_id(id)?;
        if let Some(name) = &update.name {
            validate_name("room name", name)?;
        }
        validate_appearance(
            update.color.as_ref().and_then(Option::as_deref),
            update.icon.as_ref().and_then(Option::as_deref),
        )?;
        update.icon.clone().flatten().map_or(Ok(()), |icon| require_icon_asset(tx, &icon))?;
        optional_text("theme", update.theme.as_ref().and_then(Option::as_deref), validate_theme)?;
        optional_text(
            "browser_profile_id",
            update.browser_profile_id.as_ref().and_then(Option::as_deref),
            validate_browser_profile_ref,
        )?;
        optional_text(
            "default_session_id",
            update.default_session_id.as_ref().and_then(Option::as_deref),
            validate_session_id,
        )?;
        let defaults = match &update.defaults {
            Some(Some(value)) => Some(Some(validate_profile_defaults(value)?)),
            Some(None) => Some(None),
            None => None,
        };
        let before = read_profile(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown room {id}"))?;
        let mut sets: Vec<(&str, Option<String>)> = Vec::new();
        if let Some(name) = update.name {
            sets.push(("name", Some(name)));
        }
        if let Some(color) = update.color {
            sets.push(("color", color));
        }
        if let Some(icon) = update.icon {
            sets.push(("icon", icon));
        }
        if let Some(theme) = update.theme {
            sets.push(("theme", theme));
        }
        if let Some(browser) = update.browser_profile_id {
            sets.push(("browser_profile_id", browser));
        }
        if let Some(session) = update.default_session_id {
            sets.push(("default_session_id", session));
        }
        if let Some(defaults) = defaults {
            sets.push(("defaults_json", defaults));
        }
        for (column, value) in sets {
            tx.execute(
                &format!("UPDATE profiles SET {column} = ?2 WHERE profile_id = ?1"),
                params![id, value],
            )?;
        }
        let after = read_profile(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown room {id}"))?;
        let changed = after != before;
        if changed {
            commit_personal(
                tx,
                "personal.profile.updated",
                vec![subject("profile", id)],
                &json!({"profile": after}),
            )?;
        }
        Ok((after, changed))
    }

    pub(crate) fn move_profile_in(
        tx: &Transaction<'_>,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        validate_profile_id(id)?;
        let mut order =
            read_profiles(tx)?.into_iter().map(|profile| profile.id).collect::<Vec<_>>();
        let old = order
            .iter()
            .position(|candidate| candidate == id)
            .ok_or_else(|| anyhow::anyhow!("unknown room {id}"))?;
        let new = insertion_final_index(old, index, order.len());
        let changed = new != old;
        if changed {
            let moved = order.remove(old);
            order.insert(new, moved);
            write_order(tx, "profiles", "profile_id", &order)?;
            commit_personal(
                tx,
                "personal.profile.moved",
                vec![subject("profile", id)],
                &json!({"profile_id": id, "index": new}),
            )?;
        }
        let profile = read_profile(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown room {id}"))?;
        Ok((profile, changed))
    }

    /// Delete a room. Its pins and groups move to `move_to`, or the pins are
    /// removed and the groups deleted (members ungrouped). Follows go with
    /// the room. `default` is refused.
    pub(crate) fn delete_profile_in(
        tx: &Transaction<'_>,
        id: &str,
        move_to: Option<&str>,
    ) -> anyhow::Result<ProfileDeletion> {
        validate_profile_id(id)?;
        anyhow::ensure!(id != DEFAULT_PROFILE_ID, "the default room cannot be deleted");
        anyhow::ensure!(move_to != Some(id), "a room cannot move to itself");
        anyhow::ensure!(read_profile(tx, id)?.is_some(), "unknown room {id}");
        if let Some(target) = move_to {
            anyhow::ensure!(read_profile(tx, target)?.is_some(), "unknown room {target}");
        }
        let pins = {
            let mut statement = tx.prepare(
                "SELECT session_id, workspace_key FROM profile_pins WHERE profile_id = ?1
                 ORDER BY session_id, workspace_key",
            )?;
            statement
                .query_map([id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        let unpinned = match move_to {
            Some(target) => {
                tx.execute(
                    "UPDATE profile_pins SET profile_id = ?2 WHERE profile_id = ?1",
                    params![id, target],
                )?;
                tx.execute(
                    "UPDATE personal_groups SET profile_id = ?2 WHERE profile_id = ?1",
                    params![id, target],
                )?;
                Vec::new()
            }
            None => {
                tx.execute("DELETE FROM profile_pins WHERE profile_id = ?1", [id])?;
                tx.execute(
                    "UPDATE personal_workspaces SET group_id = NULL WHERE group_id IN (
                       SELECT group_id FROM personal_groups WHERE profile_id = ?1)",
                    [id],
                )?;
                tx.execute("DELETE FROM personal_groups WHERE profile_id = ?1", [id])?;
                pins
            }
        };
        tx.execute("DELETE FROM profile_follows WHERE profile_id = ?1", [id])?;
        tx.execute("DELETE FROM profiles WHERE profile_id = ?1", [id])?;
        let order = read_profiles(tx)?.into_iter().map(|profile| profile.id).collect::<Vec<_>>();
        write_order(tx, "profiles", "profile_id", &order)?;
        let groups = read_groups(tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        write_order(tx, "personal_groups", "group_id", &groups)?;
        commit_personal(
            tx,
            "personal.profile.deleted",
            vec![subject("profile", id)],
            &json!({"profile_id": id, "moved_to": move_to, "unpinned": unpinned}),
        )?;
        Ok(ProfileDeletion { moved_to: move_to.map(str::to_string), unpinned })
    }

    pub(crate) fn set_profile_follows_in(
        tx: &Transaction<'_>,
        id: &str,
        sessions: &[String],
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        validate_profile_id(id)?;
        for session in sessions {
            validate_session_id(session)?;
        }
        let before = read_profile(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown room {id}"))?;
        tx.execute("DELETE FROM profile_follows WHERE profile_id = ?1", [id])?;
        for session in sessions {
            tx.execute(
                "INSERT OR IGNORE INTO profile_follows(profile_id, session_id) VALUES(?1, ?2)",
                params![id, session],
            )?;
        }
        let after = read_profile(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown room {id}"))?;
        let changed = after != before;
        if changed {
            commit_personal(
                tx,
                "personal.profile.follows",
                vec![subject("profile", id)],
                &json!({"profile_id": id, "follows": after.follows}),
            )?;
        }
        Ok((after, changed))
    }

    /// Pin a qualified workspace to a room (exclusive; replaces any pin).
    /// The key need not exist yet. A personal group in another room is
    /// cleared from the workspace.
    pub(crate) fn pin_workspace_in(
        tx: &Transaction<'_>,
        session: &str,
        key: &str,
        profile: &str,
    ) -> anyhow::Result<bool> {
        validate_session_id(session)?;
        validate_personal_workspace_key(key)?;
        validate_profile_id(profile)?;
        anyhow::ensure!(read_profile(tx, profile)?.is_some(), "unknown room {profile}");
        let current = tx
            .query_row(
                "SELECT profile_id FROM profile_pins WHERE session_id = ?1 AND workspace_key = ?2",
                params![session, key],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let regrouped = tx.execute(
            "UPDATE personal_workspaces SET group_id = NULL
             WHERE session_id = ?1 AND workspace_key = ?2 AND group_id IS NOT NULL
               AND group_id NOT IN (SELECT group_id FROM personal_groups WHERE profile_id = ?3)",
            params![session, key, profile],
        )?;
        let changed = current.as_deref() != Some(profile) || regrouped > 0;
        if changed {
            tx.execute(
                "INSERT INTO profile_pins(session_id, workspace_key, profile_id) VALUES(?1, ?2, ?3)
                 ON CONFLICT(session_id, workspace_key) DO UPDATE SET profile_id = excluded.profile_id",
                params![session, key, profile],
            )?;
            commit_personal(
                tx,
                "personal.workspace.pinned",
                vec![subject("workspace", &qualified(session, key)), subject("profile", profile)],
                &json!({"session_id": session, "workspace_key": key, "profile": profile}),
            )?;
        }
        Ok(changed)
    }

    pub(crate) fn unpin_workspace_in(
        tx: &Transaction<'_>,
        session: &str,
        key: &str,
    ) -> anyhow::Result<bool> {
        validate_session_id(session)?;
        validate_personal_workspace_key(key)?;
        let changed = tx.execute(
            "DELETE FROM profile_pins WHERE session_id = ?1 AND workspace_key = ?2",
            params![session, key],
        )? > 0;
        if changed {
            commit_personal(
                tx,
                "personal.workspace.unpinned",
                vec![subject("workspace", &qualified(session, key))],
                &json!({"session_id": session, "workspace_key": key}),
            )?;
        }
        Ok(changed)
    }

    /// Record or refresh a session in the registry. A new session is
    /// followed by `default` and by `follow_with` when given.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn put_session_in(
        tx: &Transaction<'_>,
        session: &str,
        machine_name: Option<&str>,
        session_name: Option<&str>,
        transport: &Value,
        capabilities: Option<&Value>,
        follow_with: Option<&str>,
    ) -> anyhow::Result<(PersonalSession, bool)> {
        validate_session_id(session)?;
        for (label, value) in [("machine_name", machine_name), ("session_name", session_name)] {
            if let Some(value) = value {
                validate_name(label, value)?;
            }
        }
        let transport = validate_personal_json("transport", transport, true)?;
        let capabilities = capabilities
            .map(|value| validate_personal_json("capabilities", value, false))
            .transpose()?;
        if let Some(room) = follow_with {
            validate_profile_id(room)?;
        }
        let created = read_session(tx, session)?.is_none();
        if let Some(room) = follow_with {
            anyhow::ensure!(read_profile(tx, room)?.is_some(), "unknown room {room}");
        }
        let now = i64::try_from(unix_epoch_ms()?)?;
        tx.execute(
            "INSERT INTO sessions(session_id, machine_name, session_name, transport_json, last_seen_ms, capabilities_json)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(session_id) DO UPDATE SET
               machine_name = COALESCE(excluded.machine_name, sessions.machine_name),
               session_name = COALESCE(excluded.session_name, sessions.session_name),
               transport_json = excluded.transport_json,
               last_seen_ms = excluded.last_seen_ms,
               capabilities_json = COALESCE(excluded.capabilities_json, sessions.capabilities_json)",
            params![session, machine_name, session_name, transport, now, capabilities],
        )?;
        if created {
            for room in [Some(DEFAULT_PROFILE_ID), follow_with].into_iter().flatten() {
                tx.execute(
                    "INSERT OR IGNORE INTO profile_follows(profile_id, session_id) VALUES(?1, ?2)",
                    params![room, session],
                )?;
            }
        }
        let record = read_session(tx, session)?
            .ok_or_else(|| anyhow::anyhow!("session {session} vanished"))?;
        commit_personal(
            tx,
            "personal.session.put",
            vec![subject("session", session)],
            &json!({"session": record, "created": created}),
        )?;
        Ok((record, created))
    }

    /// Forget a session: its row, follows, and personal workspace and
    /// terminal rows.
    /// Refused while a room pins one of its workspaces unless `force`, which
    /// also removes those pins.
    pub(crate) fn forget_session_in(
        tx: &Transaction<'_>,
        session: &str,
        force: bool,
    ) -> anyhow::Result<bool> {
        validate_session_id(session)?;
        let pins: i64 = tx.query_row(
            "SELECT COUNT(*) FROM profile_pins WHERE session_id = ?1",
            [session],
            |row| row.get(0),
        )?;
        anyhow::ensure!(
            pins == 0 || force,
            "session {session} has pinned workspaces; pass force to forget it"
        );
        let mut removed = 0;
        for sql in [
            "DELETE FROM profile_pins WHERE session_id = ?1",
            "DELETE FROM personal_workspaces WHERE session_id = ?1",
            "DELETE FROM personal_terminals WHERE session_id = ?1",
            "DELETE FROM profile_follows WHERE session_id = ?1",
            "DELETE FROM sessions WHERE session_id = ?1",
        ] {
            removed += tx.execute(sql, [session])?;
        }
        let changed = removed > 0;
        if changed {
            commit_personal(
                tx,
                "personal.session.forgotten",
                vec![subject("session", session)],
                &json!({"session_id": session, "force": force}),
            )?;
        }
        Ok(changed)
    }

    /// The app's one-time copy of a remote daemon's shared groups and order.
    /// A no-op returning false once the session is marked migrated.
    pub(crate) fn import_session_organization_in(
        tx: &Transaction<'_>,
        session: &str,
        groups: &[(String, String, Option<String>, bool)],
        workspaces: &[(String, Option<String>)],
    ) -> anyhow::Result<bool> {
        validate_session_id(session)?;
        for (id, name, color, _) in groups {
            validate_workspace_group_id(id)?;
            validate_name("group name", name)?;
            validate_appearance(color.as_deref(), None)?;
        }
        for (key, _) in workspaces {
            validate_personal_workspace_key(key)?;
        }
        let record = read_session(tx, session)?
            .ok_or_else(|| anyhow::anyhow!("unknown session {session}"))?;
        if record.migrated {
            return Ok(false);
        }
        let mut taken = read_groups(tx)?.into_iter().map(|group| group.id).collect::<HashSet<_>>();
        let first_position = i64::try_from(taken.len())?;
        let mut mapped = std::collections::HashMap::new();
        for (position, (id, name, color, collapsed)) in (first_position..).zip(groups.iter()) {
            let mut local = id.clone();
            let mut attempt = 1;
            while taken.contains(&local) {
                let prefix: String =
                    session.chars().filter(char::is_ascii_alphanumeric).take(8).collect();
                let base = format!("{prefix}:{id}");
                local = if attempt == 1 { base } else { format!("{base}-{attempt}") };
                local.truncate(64);
                attempt += 1;
            }
            taken.insert(local.clone());
            tx.execute(
                "INSERT INTO personal_groups(group_id, profile_id, name, color, collapsed, position)
                 VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
                params![local, DEFAULT_PROFILE_ID, name, color, i64::from(*collapsed), position],
            )?;
            mapped.insert(id.clone(), local);
        }
        let mut next = next_workspace_position(tx)?;
        for (key, group) in workspaces {
            let group = group.as_ref().and_then(|group| mapped.get(group));
            next += tx.execute(
                "INSERT OR IGNORE INTO personal_workspaces(session_id, workspace_key, position, group_id)
                 VALUES(?1, ?2, ?3, ?4)",
                params![session, key, next, group],
            )? as i64;
        }
        tx.execute("UPDATE sessions SET migrated = 1 WHERE session_id = ?1", [session])?;
        commit_personal(
            tx,
            "personal.session.imported",
            vec![subject("session", session)],
            &json!({"session_id": session, "groups": mapped.len(), "workspaces": workspaces.len()}),
        )?;
        Ok(true)
    }

    /// Create a personal group in a room (default `default`) at `index`
    /// among all personal groups. The same id and name is a no-op retry.
    pub(crate) fn create_personal_group_in(
        tx: &Transaction<'_>,
        id: Option<String>,
        profile: Option<&str>,
        name: &str,
        color: Option<&str>,
        collapsed: bool,
        index: Option<usize>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let id = id.unwrap_or_else(super::new_workspace_group_id);
        validate_workspace_group_id(&id)?;
        validate_name("group name", name)?;
        validate_appearance(color, None)?;
        let profile = profile.unwrap_or(DEFAULT_PROFILE_ID);
        validate_profile_id(profile)?;
        if let Some(existing) = read_group(tx, &id)? {
            anyhow::ensure!(
                existing.name == name,
                "group {id} already exists with a different name"
            );
            return Ok((existing, false));
        }
        anyhow::ensure!(read_profile(tx, profile)?.is_some(), "unknown room {profile}");
        let mut order = read_groups(tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        let index = index.unwrap_or(order.len()).min(order.len());
        tx.execute(
            "INSERT INTO personal_groups(group_id, profile_id, name, color, collapsed, position)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, profile, name, color, i64::from(collapsed), i64::try_from(order.len())?],
        )?;
        order.insert(index, id.clone());
        write_order(tx, "personal_groups", "group_id", &order)?;
        let group = read_group(tx, &id)?.ok_or_else(|| anyhow::anyhow!("group {id} vanished"))?;
        commit_personal(
            tx,
            "personal.group.created",
            vec![subject("personal_group", &id)],
            &json!({"group": group}),
        )?;
        Ok((group, true))
    }

    /// Rename, recolor, collapse, or move a group to another room. Moving it
    /// pins every member workspace to that room in the same transaction.
    pub(crate) fn update_personal_group_in(
        tx: &Transaction<'_>,
        id: &str,
        name: Option<&str>,
        color: Option<Option<&str>>,
        collapsed: Option<bool>,
        profile: Option<&str>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        if let Some(name) = name {
            validate_name("group name", name)?;
        }
        validate_appearance(color.flatten(), None)?;
        if let Some(profile) = profile {
            validate_profile_id(profile)?;
        }
        let before =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        if let Some(name) = name {
            tx.execute(
                "UPDATE personal_groups SET name = ?2 WHERE group_id = ?1",
                params![id, name],
            )?;
        }
        if let Some(color) = color {
            tx.execute(
                "UPDATE personal_groups SET color = ?2 WHERE group_id = ?1",
                params![id, color],
            )?;
        }
        if let Some(collapsed) = collapsed {
            tx.execute(
                "UPDATE personal_groups SET collapsed = ?2 WHERE group_id = ?1",
                params![id, i64::from(collapsed)],
            )?;
        }
        let mut pinned = 0;
        if let Some(profile) = profile.filter(|profile| *profile != before.profile) {
            anyhow::ensure!(read_profile(tx, profile)?.is_some(), "unknown room {profile}");
            tx.execute(
                "UPDATE personal_groups SET profile_id = ?2 WHERE group_id = ?1",
                params![id, profile],
            )?;
            pinned = tx.execute(
                "INSERT INTO profile_pins(session_id, workspace_key, profile_id)
                 SELECT session_id, workspace_key, ?2 FROM personal_workspaces WHERE group_id = ?1
                 ON CONFLICT(session_id, workspace_key) DO UPDATE SET profile_id = excluded.profile_id",
                params![id, profile],
            )?;
        }
        let after =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        let changed = after != before || pinned > 0;
        if changed {
            commit_personal(
                tx,
                "personal.group.updated",
                vec![subject("personal_group", id)],
                &json!({"group": after, "pinned_members": pinned}),
            )?;
        }
        Ok((after, changed))
    }

    /// Delete a group; its workspaces become ungrouped. Returns them.
    pub(crate) fn delete_personal_group_in(
        tx: &Transaction<'_>,
        id: &str,
    ) -> anyhow::Result<Vec<(String, String)>> {
        validate_workspace_group_id(id)?;
        anyhow::ensure!(read_group(tx, id)?.is_some(), "unknown personal group {id}");
        let members = {
            let mut statement = tx.prepare(
                "SELECT session_id, workspace_key FROM personal_workspaces WHERE group_id = ?1
                 ORDER BY position ASC",
            )?;
            statement
                .query_map([id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        tx.execute("UPDATE personal_workspaces SET group_id = NULL WHERE group_id = ?1", [id])?;
        tx.execute("DELETE FROM personal_groups WHERE group_id = ?1", [id])?;
        let order = read_groups(tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        write_order(tx, "personal_groups", "group_id", &order)?;
        commit_personal(
            tx,
            "personal.group.deleted",
            vec![subject("personal_group", id)],
            &json!({"group_id": id, "ungrouped": members}),
        )?;
        Ok(members)
    }

    pub(crate) fn move_personal_group_in(
        tx: &Transaction<'_>,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        let mut order = read_groups(tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        let old = order
            .iter()
            .position(|candidate| candidate == id)
            .ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        let new = insertion_final_index(old, index, order.len());
        let changed = new != old;
        if changed {
            let moved = order.remove(old);
            order.insert(new, moved);
            write_order(tx, "personal_groups", "group_id", &order)?;
            commit_personal(
                tx,
                "personal.group.moved",
                vec![subject("personal_group", id)],
                &json!({"group_id": id, "index": new}),
            )?;
        }
        let group =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        Ok((group, changed))
    }

    /// Create or update the personal row of a qualified workspace. `index`
    /// is its final position in the personal order (absent on create:
    /// last). The daemon does not check that a group belongs to the room
    /// showing the workspace; the app evaluates membership.
    pub(crate) fn set_personal_workspace_in(
        tx: &Transaction<'_>,
        session: &str,
        key: &str,
        update: PersonalWorkspaceUpdate,
    ) -> anyhow::Result<(PersonalWorkspace, bool)> {
        validate_session_id(session)?;
        validate_personal_workspace_key(key)?;
        if let Some(Some(group)) = &update.group {
            validate_workspace_group_id(group)?;
        }
        optional_text(
            "browser_profile_id",
            update.browser_profile_id.as_ref().and_then(Option::as_deref),
            validate_browser_profile_ref,
        )?;
        optional_text("theme", update.theme.as_ref().and_then(Option::as_deref), validate_theme)?;
        if let Some(Some(group)) = &update.group {
            anyhow::ensure!(read_group(tx, group)?.is_some(), "unknown personal group {group}");
        }
        let find = |rows: &[PersonalWorkspace]| {
            rows.iter().find(|row| row.session_id == session && row.workspace_key == key).cloned()
        };
        let before = find(&read_workspaces(tx)?);
        if before.is_none() {
            tx.execute(
                "INSERT INTO personal_workspaces(session_id, workspace_key, position) VALUES(?1, ?2, ?3)",
                params![session, key, next_workspace_position(tx)?],
            )?;
        }
        if let Some(group) = &update.group {
            tx.execute(
                "UPDATE personal_workspaces SET group_id = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
                params![session, key, group],
            )?;
        }
        if let Some(browser) = &update.browser_profile_id {
            tx.execute(
                "UPDATE personal_workspaces SET browser_profile_id = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
                params![session, key, browser],
            )?;
        }
        if let Some(theme) = &update.theme {
            tx.execute(
                "UPDATE personal_workspaces SET theme = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
                params![session, key, theme],
            )?;
        }
        if let Some(index) = update.index {
            let rows = read_workspaces(tx)?;
            let mut order = rows
                .iter()
                .map(|row| (row.session_id.clone(), row.workspace_key.clone()))
                .collect::<Vec<_>>();
            let old =
                order.iter().position(|(s, k)| s == session && k == key).unwrap_or(order.len() - 1);
            let moved = order.remove(old);
            order.insert(index.min(order.len()), moved);
            for (position, (s, k)) in order.iter().enumerate() {
                tx.execute(
                    "UPDATE personal_workspaces SET position = ?3 WHERE session_id = ?1 AND workspace_key = ?2",
                    params![s, k, i64::try_from(position)?],
                )?;
            }
        }
        crate::state::home_store::require_home_first(tx)?;
        let after = find(&read_workspaces(tx)?)
            .ok_or_else(|| anyhow::anyhow!("personal workspace vanished"))?;
        let changed = before.as_ref() != Some(&after);
        if changed {
            commit_personal(
                tx,
                "personal.workspace.updated",
                vec![subject("workspace", &qualified(session, key))],
                &json!({"workspace": after}),
            )?;
        }
        Ok((after, changed))
    }

    // Transaction-owning entry points of the raw `profiles-v1` commands.

    pub fn create_profile(
        &mut self,
        input: ProfileInput,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::create_profile_in(&tx, input)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn update_profile(
        &mut self,
        id: &str,
        update: ProfileUpdate,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::update_profile_in(&tx, id, update)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn move_profile(
        &mut self,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::move_profile_in(&tx, id, index)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn delete_profile(
        &mut self,
        id: &str,
        move_to: Option<&str>,
    ) -> anyhow::Result<ProfileDeletion> {
        let tx = self.connection.transaction()?;
        let output = Self::delete_profile_in(&tx, id, move_to)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn set_profile_follows(
        &mut self,
        id: &str,
        sessions: &[String],
    ) -> anyhow::Result<(PersonalProfile, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::set_profile_follows_in(&tx, id, sessions)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn pin_workspace(
        &mut self,
        session: &str,
        key: &str,
        profile: &str,
    ) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::pin_workspace_in(&tx, session, key, profile)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn unpin_workspace(&mut self, session: &str, key: &str) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::unpin_workspace_in(&tx, session, key)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn put_session(
        &mut self,
        session: &str,
        machine_name: Option<&str>,
        session_name: Option<&str>,
        transport: &Value,
        capabilities: Option<&Value>,
        follow_with: Option<&str>,
    ) -> anyhow::Result<(PersonalSession, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::put_session_in(
            &tx,
            session,
            machine_name,
            session_name,
            transport,
            capabilities,
            follow_with,
        )?;
        tx.commit()?;
        Ok(output)
    }

    pub fn forget_session(&mut self, session: &str, force: bool) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::forget_session_in(&tx, session, force)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn create_personal_group(
        &mut self,
        id: Option<String>,
        profile: Option<&str>,
        name: &str,
        color: Option<&str>,
        collapsed: bool,
        index: Option<usize>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let tx = self.connection.transaction()?;
        let output =
            Self::create_personal_group_in(&tx, id, profile, name, color, collapsed, index)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn update_personal_group(
        &mut self,
        id: &str,
        name: Option<&str>,
        color: Option<Option<&str>>,
        collapsed: Option<bool>,
        profile: Option<&str>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::update_personal_group_in(&tx, id, name, color, collapsed, profile)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn delete_personal_group(&mut self, id: &str) -> anyhow::Result<Vec<(String, String)>> {
        let tx = self.connection.transaction()?;
        let output = Self::delete_personal_group_in(&tx, id)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn move_personal_group(
        &mut self,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::move_personal_group_in(&tx, id, index)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn set_personal_workspace(
        &mut self,
        session: &str,
        key: &str,
        update: PersonalWorkspaceUpdate,
    ) -> anyhow::Result<(PersonalWorkspace, bool)> {
        let tx = self.connection.transaction()?;
        let output = Self::set_personal_workspace_in(&tx, session, key, update)?;
        tx.commit()?;
        Ok(output)
    }

    pub fn import_session_organization(
        &mut self,
        session: &str,
        groups: &[(String, String, Option<String>, bool)],
        workspaces: &[(String, Option<String>)],
    ) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let output = Self::import_session_organization_in(&tx, session, groups, workspaces)?;
        tx.commit()?;
        Ok(output)
    }
}
