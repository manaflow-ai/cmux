//! Personal state of the home session (plans/cmux-next/data-model.md
//! sections 1-3, capability `profiles-v1`): the session registry, rooms
//! (wire name `profile`) with their follows and pins, personal workspace
//! groups, and the personal order and overrides of every qualified
//! workspace `{session_id, workspace_key}`.
//!
//! Every daemon serves these tables, but only the app's home session is
//! written. The tables are additive and carry no foreign keys, so an older
//! binary that opens the registry ignores them. Each mutation bumps the
//! `personal_revision` meta counter and appends one advisory `state` journal
//! record in the same transaction.

use std::collections::{BTreeMap, HashMap};

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::{Value, json};

use super::JournalSubject;
use super::presentation_store::{
    append_presentation_record, validate_presentation_color, validate_presentation_icon,
    validate_presentation_text, validate_workspace_group_id,
};

/// The built-in room. It always exists and cannot be deleted.
pub const DEFAULT_PROFILE_ID: &str = "default";
const MIGRATED_META_KEY: &str = "personal_migrated_v1";
const REVISION_META_KEY: &str = "personal_revision";
/// Longest accepted transport or capabilities JSON, in bytes.
pub const MAX_PERSONAL_JSON_BYTES: usize = 4096;
/// Longest accepted theme spec, in characters.
pub const MAX_THEME_CHARS: usize = 256;

pub(super) fn create_personal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS profiles (
           profile_id TEXT PRIMARY KEY NOT NULL,
           name TEXT NOT NULL,
           color TEXT,
           icon TEXT,
           theme TEXT,
           position INTEGER NOT NULL CHECK(position >= 0),
           browser_profile_id TEXT,
           default_session_id TEXT,
           defaults_json TEXT
         );
         CREATE TABLE IF NOT EXISTS profile_follows (
           profile_id TEXT NOT NULL,
           session_id TEXT NOT NULL,
           PRIMARY KEY(profile_id, session_id)
         );
         CREATE TABLE IF NOT EXISTS profile_pins (
           session_id TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           profile_id TEXT NOT NULL,
           PRIMARY KEY(session_id, workspace_key)
         );
         CREATE TABLE IF NOT EXISTS sessions (
           session_id TEXT PRIMARY KEY NOT NULL,
           machine_name TEXT,
           session_name TEXT,
           transport_json TEXT NOT NULL,
           last_seen_ms INTEGER,
           capabilities_json TEXT,
           migrated INTEGER NOT NULL DEFAULT 0 CHECK(migrated IN (0,1))
         );
         CREATE TABLE IF NOT EXISTS personal_groups (
           group_id TEXT PRIMARY KEY NOT NULL,
           profile_id TEXT NOT NULL,
           name TEXT NOT NULL,
           color TEXT,
           collapsed INTEGER NOT NULL DEFAULT 0 CHECK(collapsed IN (0,1)),
           position INTEGER NOT NULL CHECK(position >= 0)
         );
         CREATE TABLE IF NOT EXISTS personal_workspaces (
           session_id TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           position INTEGER NOT NULL CHECK(position >= 0),
           group_id TEXT,
           browser_profile_id TEXT,
           theme TEXT,
           PRIMARY KEY(session_id, workspace_key)
         );
         CREATE TABLE IF NOT EXISTS personal_terminals (
           session_id TEXT NOT NULL,
           terminal_key TEXT NOT NULL,
           theme TEXT NOT NULL,
           PRIMARY KEY(session_id, terminal_key)
         );",
    )?;
    Ok(())
}

/// One-time local migration at open: the `default` room, this daemon's own
/// session (followed by `default`), and its shared groups, membership and
/// order copied into personal rows. Idempotent: a flag in `meta` records it,
/// and every insert ignores existing rows.
pub(super) fn migrate_personal_v1(
    connection: &Connection,
    registry_id: &str,
    session_name: &str,
) -> anyhow::Result<()> {
    let tx = connection.unchecked_transaction()?;
    create_personal_schema(&tx)?;
    super::personal_browser_profiles::create_browser_profile_schema(&tx)?;
    super::personal_bookmarks::create_bookmark_schema(&tx)?;
    tx.execute("INSERT OR IGNORE INTO meta(key, value) VALUES(?1, '0')", [REVISION_META_KEY])?;
    let migrated = tx
        .query_row("SELECT 1 FROM meta WHERE key = ?1", [MIGRATED_META_KEY], |_| Ok(()))
        .optional()?
        .is_some();
    if migrated {
        tx.commit()?;
        return Ok(());
    }
    tx.execute(
        "INSERT OR IGNORE INTO profiles(profile_id, name, position) VALUES(?1, 'Default', 0)",
        [DEFAULT_PROFILE_ID],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO sessions(session_id, machine_name, session_name, transport_json, migrated)
         VALUES(?1, ?2, ?3, '{\"kind\":\"local\"}', 1)",
        params![registry_id, crate::machine_name::machine_name(), session_name],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO profile_follows(profile_id, session_id) VALUES(?1, ?2)",
        params![DEFAULT_PROFILE_ID, registry_id],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO personal_groups(group_id, profile_id, name, color, collapsed, position)
         SELECT group_id, ?1, name, color, collapsed, position FROM workspace_groups",
        [DEFAULT_PROFILE_ID],
    )?;
    let workspaces = {
        let mut statement = tx.prepare(
            "SELECT w.workspace_key, g.group_id
             FROM workspaces AS w
             LEFT JOIN workspace_presentation AS p ON p.workspace_key = w.workspace_key
             LEFT JOIN workspace_groups AS g ON g.group_id = p.group_id
             WHERE w.tombstoned = 0
             ORDER BY w.position ASC",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut position = next_workspace_position(&tx)?;
    for (key, group) in workspaces {
        position += tx.execute(
            "INSERT OR IGNORE INTO personal_workspaces(session_id, workspace_key, position, group_id)
             VALUES(?1, ?2, ?3, ?4)",
            params![registry_id, key, position, group],
        )? as i64;
    }
    tx.execute("INSERT INTO meta(key, value) VALUES(?1, '1')", [MIGRATED_META_KEY])?;
    tx.commit()?;
    Ok(())
}

// MARK: Records

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalSession {
    pub session_id: String,
    pub machine_name: Option<String>,
    pub session_name: Option<String>,
    pub transport: Value,
    pub last_seen_ms: Option<u64>,
    pub capabilities: Option<Value>,
    pub migrated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalProfile {
    pub id: String,
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub theme: Option<String>,
    pub index: usize,
    pub browser_profile_id: Option<String>,
    pub default_session_id: Option<String>,
    pub defaults: Option<Value>,
    pub follows: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalPin {
    pub session_id: String,
    pub workspace_key: String,
    pub profile: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalGroup {
    pub id: String,
    pub profile: String,
    pub name: String,
    pub color: Option<String>,
    pub collapsed: bool,
    pub index: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalWorkspace {
    pub session_id: String,
    pub workspace_key: String,
    pub index: usize,
    pub group: Option<String>,
    pub browser_profile_id: Option<String>,
    pub theme: Option<String>,
}

/// The own theme of one session-qualified terminal
/// (`personal-terminals-v1`). A terminal without a row has none.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PersonalTerminal {
    pub session_id: String,
    pub terminal_key: String,
    pub theme: String,
}

/// Everything `list-personal` returns, in order.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct PersonalSnapshot {
    pub personal_revision: u64,
    pub sessions: Vec<PersonalSession>,
    pub profiles: Vec<PersonalProfile>,
    pub pins: Vec<PersonalPin>,
    pub groups: Vec<PersonalGroup>,
    pub workspaces: Vec<PersonalWorkspace>,
    pub terminals: Vec<PersonalTerminal>,
    /// Browser profile records (`browser-profiles-v1`), `default` included.
    pub browser_profiles: Vec<super::personal_browser_profiles::PersonalBrowserProfile>,
}

// MARK: Validation

/// `default` or 1-64 of `[A-Za-z0-9_.:-]` (the group id rule).
pub fn validate_profile_id(value: &str) -> anyhow::Result<()> {
    validate_workspace_group_id(value).map_err(|_| {
        anyhow::anyhow!(
            "bad request: profile id must be 1-64 ASCII letters, digits, '_', '-', '.', or ':'"
        )
    })
}

/// A session id: the daemon's registry id (a UUID) or another 1-128 of
/// `[A-Za-z0-9_.:-]`.
pub fn validate_session_id(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric()
                    || matches!(byte, b'_' | b'-' | b'.' | b':')),
        "bad request: session id must be 1-128 ASCII letters, digits, '_', '-', '.', or ':'"
    );
    Ok(())
}

/// A workspace key of any session. Remote keys cannot be checked against a
/// registry, so only the shape is validated.
pub fn validate_personal_workspace_key(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value.bytes().all(|byte| byte.is_ascii_graphic()),
        "bad request: workspace key must be 1-128 printable ASCII characters"
    );
    Ok(())
}

pub fn validate_theme(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(!value.trim().is_empty(), "bad request: theme cannot be empty");
    anyhow::ensure!(
        value.chars().count() <= MAX_THEME_CHARS,
        "bad request: theme exceeds {MAX_THEME_CHARS} characters"
    );
    anyhow::ensure!(
        !value.chars().any(char::is_control),
        "bad request: theme contains a control character"
    );
    Ok(())
}

/// A browser profile id: `default` or a lowercase UUID.
pub fn validate_browser_profile_ref(value: &str) -> anyhow::Result<()> {
    let uuid = value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte),
        });
    anyhow::ensure!(
        value == DEFAULT_PROFILE_ID || uuid,
        "bad request: browser_profile_id must be \"default\" or a lowercase UUID"
    );
    Ok(())
}

/// A JSON value stored in a personal row, bounded in size.
pub fn validate_personal_json(
    label: &str,
    value: &Value,
    object_only: bool,
) -> anyhow::Result<String> {
    anyhow::ensure!(
        !object_only || value.is_object(),
        "bad request: {label} must be a JSON object"
    );
    let text = serde_json::to_string(value)?;
    anyhow::ensure!(
        text.len() <= MAX_PERSONAL_JSON_BYTES,
        "bad request: {label} exceeds {MAX_PERSONAL_JSON_BYTES} bytes"
    );
    Ok(text)
}

/// Room terminal defaults `{cwd?, env?}`; env follows the per-terminal env
/// rules.
pub fn validate_profile_defaults(value: &Value) -> anyhow::Result<String> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("bad request: defaults must be a JSON object"))?;
    for key in object.keys() {
        anyhow::ensure!(
            matches!(key.as_str(), "cwd" | "env"),
            "bad request: defaults accepts only cwd and env"
        );
    }
    if let Some(cwd) = object.get("cwd").filter(|cwd| !cwd.is_null()) {
        let cwd = cwd
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("bad request: defaults.cwd must be a string"))?;
        anyhow::ensure!(
            !cwd.is_empty() && !cwd.contains('\0') && cwd.len() <= 4096,
            "bad request: defaults.cwd must be 1-4096 bytes without NUL"
        );
    }
    if let Some(env) = object.get("env").filter(|env| !env.is_null()) {
        let env: BTreeMap<String, String> = serde_json::from_value(env.clone()).map_err(|_| {
            anyhow::anyhow!("bad request: defaults.env must be an object of strings")
        })?;
        crate::mux::validate_terminal_env(&env)?;
    }
    let text = serde_json::to_string(value)?;
    anyhow::ensure!(text.len() <= 256 * 1024 + 8192, "bad request: defaults is too large");
    Ok(text)
}

pub(super) fn validate_appearance(color: Option<&str>, icon: Option<&str>) -> anyhow::Result<()> {
    if let Some(color) = color {
        validate_presentation_color(color)?;
    }
    if let Some(icon) = icon {
        validate_presentation_icon(icon)?;
    }
    Ok(())
}

pub(super) fn validate_name(label: &str, value: &str) -> anyhow::Result<()> {
    validate_presentation_text(label, value)
}

// MARK: Reads

fn parse_json(text: Option<String>) -> anyhow::Result<Option<Value>> {
    text.map(|text| serde_json::from_str(&text).context("stored personal JSON is invalid"))
        .transpose()
}

pub(super) fn personal_revision(connection: &Connection) -> anyhow::Result<u64> {
    let value = connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [REVISION_META_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    Ok(value.map(|value| value.parse()).transpose()?.unwrap_or(0))
}

pub(super) fn read_sessions(connection: &Connection) -> anyhow::Result<Vec<PersonalSession>> {
    let mut statement = connection.prepare(
        "SELECT session_id, machine_name, session_name, transport_json, last_seen_ms,
                capabilities_json, migrated
         FROM sessions ORDER BY session_id",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<String>>(5)?,
            row.get::<_, i64>(6)?,
        ))
    })?;
    let mut sessions = Vec::new();
    for row in rows {
        let (session_id, machine_name, session_name, transport, last_seen, capabilities, migrated) =
            row?;
        sessions.push(PersonalSession {
            session_id,
            machine_name,
            session_name,
            transport: serde_json::from_str(&transport)
                .context("stored session transport is invalid")?,
            last_seen_ms: last_seen.map(u64::try_from).transpose()?,
            capabilities: parse_json(capabilities)?,
            migrated: migrated != 0,
        });
    }
    Ok(sessions)
}

pub(super) fn read_session(
    connection: &Connection,
    id: &str,
) -> anyhow::Result<Option<PersonalSession>> {
    Ok(read_sessions(connection)?.into_iter().find(|session| session.session_id == id))
}

fn read_follows(connection: &Connection) -> anyhow::Result<HashMap<String, Vec<String>>> {
    let mut statement = connection.prepare(
        "SELECT profile_id, session_id FROM profile_follows ORDER BY profile_id, session_id",
    )?;
    let rows =
        statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
    let mut follows: HashMap<String, Vec<String>> = HashMap::new();
    for row in rows {
        let (profile, session) = row?;
        follows.entry(profile).or_default().push(session);
    }
    Ok(follows)
}

pub(super) fn read_profiles(connection: &Connection) -> anyhow::Result<Vec<PersonalProfile>> {
    let mut follows = read_follows(connection)?;
    let mut statement = connection.prepare(
        "SELECT profile_id, name, color, icon, theme, browser_profile_id, default_session_id, defaults_json
         FROM profiles ORDER BY position ASC, profile_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, Option<String>>(4)?,
            row.get::<_, Option<String>>(5)?,
            row.get::<_, Option<String>>(6)?,
            row.get::<_, Option<String>>(7)?,
        ))
    })?;
    let mut profiles = Vec::new();
    for (index, row) in rows.enumerate() {
        let (id, name, color, icon, theme, browser_profile_id, default_session_id, defaults) = row?;
        profiles.push(PersonalProfile {
            follows: follows.remove(&id).unwrap_or_default(),
            id,
            name,
            color,
            icon,
            theme,
            index,
            browser_profile_id,
            default_session_id,
            defaults: parse_json(defaults)?,
        });
    }
    Ok(profiles)
}

pub(super) fn read_profile(
    connection: &Connection,
    id: &str,
) -> anyhow::Result<Option<PersonalProfile>> {
    Ok(read_profiles(connection)?.into_iter().find(|profile| profile.id == id))
}

pub(super) fn read_pins(connection: &Connection) -> anyhow::Result<Vec<PersonalPin>> {
    let mut statement = connection.prepare(
        "SELECT session_id, workspace_key, profile_id FROM profile_pins ORDER BY session_id, workspace_key",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(PersonalPin {
            session_id: row.get(0)?,
            workspace_key: row.get(1)?,
            profile: row.get(2)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

pub(super) fn read_groups(connection: &Connection) -> anyhow::Result<Vec<PersonalGroup>> {
    let mut statement = connection.prepare(
        "SELECT group_id, profile_id, name, color, collapsed FROM personal_groups
         ORDER BY position ASC, group_id ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Option<String>>(3)?,
            row.get::<_, i64>(4)?,
        ))
    })?;
    let mut groups = Vec::new();
    for (index, row) in rows.enumerate() {
        let (id, profile, name, color, collapsed) = row?;
        groups.push(PersonalGroup { id, profile, name, color, collapsed: collapsed != 0, index });
    }
    Ok(groups)
}

pub(super) fn read_group(
    connection: &Connection,
    id: &str,
) -> anyhow::Result<Option<PersonalGroup>> {
    Ok(read_groups(connection)?.into_iter().find(|group| group.id == id))
}

pub(super) fn read_workspaces(connection: &Connection) -> anyhow::Result<Vec<PersonalWorkspace>> {
    let mut statement = connection.prepare(
        "SELECT session_id, workspace_key, group_id, browser_profile_id, theme FROM personal_workspaces
         ORDER BY position ASC, session_id ASC, workspace_key ASC",
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
    let mut workspaces = Vec::new();
    for (index, row) in rows.enumerate() {
        let (session_id, workspace_key, group, browser_profile_id, theme) = row?;
        workspaces.push(PersonalWorkspace {
            session_id,
            workspace_key,
            index,
            group,
            browser_profile_id,
            theme,
        });
    }
    Ok(workspaces)
}

pub(super) fn read_snapshot(connection: &Connection) -> anyhow::Result<PersonalSnapshot> {
    Ok(PersonalSnapshot {
        personal_revision: personal_revision(connection)?,
        sessions: read_sessions(connection)?,
        profiles: read_profiles(connection)?,
        pins: read_pins(connection)?,
        groups: read_groups(connection)?,
        workspaces: read_workspaces(connection)?,
        terminals: read_terminals(connection)?,
        browser_profiles: super::personal_browser_profiles::read_browser_profiles(connection)?,
    })
}

pub(super) fn read_terminals(connection: &Connection) -> anyhow::Result<Vec<PersonalTerminal>> {
    let mut statement = connection.prepare(
        "SELECT session_id, terminal_key, theme FROM personal_terminals
         ORDER BY session_id ASC, terminal_key ASC",
    )?;
    let rows = statement.query_map([], |row| {
        Ok(PersonalTerminal {
            session_id: row.get(0)?,
            terminal_key: row.get(1)?,
            theme: row.get(2)?,
        })
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

pub(super) fn next_workspace_position(connection: &Connection) -> anyhow::Result<i64> {
    Ok(connection.query_row(
        "SELECT COALESCE(MAX(position) + 1, 0) FROM personal_workspaces",
        [],
        |row| row.get::<_, i64>(0),
    )?)
}

// MARK: Commit

/// Bump `personal_revision` and append the journal fact of one personal
/// mutation, in the caller's transaction. Returns the new revision.
pub(super) fn commit_personal(
    transaction: &Transaction<'_>,
    kind: &str,
    subjects: Vec<JournalSubject>,
    payload: &Value,
) -> anyhow::Result<u64> {
    let revision = personal_revision(transaction)?.saturating_add(1);
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![REVISION_META_KEY, revision.to_string()],
    )?;
    let mut payload = payload.clone();
    if let Some(object) = payload.as_object_mut() {
        object.insert("personal_revision".into(), json!(revision));
    }
    append_presentation_record(transaction, kind, subjects, &payload)?;
    Ok(revision)
}

pub(super) fn subject(kind: &str, id: &str) -> JournalSubject {
    JournalSubject { kind: kind.into(), id: id.to_string() }
}

/// Rewrite `position` of the rows of `table` keyed by `column` to follow
/// `order`.
pub(super) fn write_order(
    transaction: &Connection,
    table: &str,
    column: &str,
    order: &[String],
) -> anyhow::Result<()> {
    let sql = format!("UPDATE {table} SET position = ?2 WHERE {column} = ?1");
    for (position, id) in order.iter().enumerate() {
        transaction.execute(&sql, params![id, i64::try_from(position)?])?;
    }
    Ok(())
}

/// Insertion-point semantics of `move-workspace`: `index` is a slot in the
/// list before removal. Returns the final index.
pub(super) fn insertion_final_index(old_index: usize, index: usize, count: usize) -> usize {
    if index > old_index { index.saturating_sub(1) } else { index }.min(count.saturating_sub(1))
}
