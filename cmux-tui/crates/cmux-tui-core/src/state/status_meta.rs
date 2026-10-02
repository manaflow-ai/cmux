//! Loading-indicator fields of a workspace status entry and who owns it
//! (plans/cmux-next/status-indicators.md section 5). Stored beside
//! `workspace_status_entries` in an additive table, so an entry written by an
//! older client (text, icon, color only) keeps working and an older binary
//! ignores the new table.
//!
//! An owned entry is removed by the daemon, never by a client: when its TTL
//! passes, its owner terminal exits, or its owner process exits
//! (`state::status_owners`). A process owner is recorded with the machine id
//! of the daemon that accepted it and is honored only there.

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::resource::TerminalPublicId;

pub(crate) const STATES: [&str; 5] = ["busy", "success", "error", "waiting", "info"];
pub(crate) const STYLES: [&str; 4] = ["arc", "native", "dot", "none"];
/// The longest TTL an entry may ask for (seven days).
pub(crate) const MAX_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1000;

fn bad_request(message: impl Into<String>) -> anyhow::Error {
    anyhow::anyhow!("bad request: {}", message.into())
}

/// The optional fields `workspace_status.set` accepts beyond text, icon and
/// color. All absent is a plain status line.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub(crate) struct StatusMeta {
    pub(crate) state: Option<String>,
    pub(crate) progress: Option<f64>,
    pub(crate) style: Option<String>,
    pub(crate) ttl_ms: Option<u64>,
    pub(crate) owner_pid: Option<u32>,
    pub(crate) owner_terminal: Option<String>,
    pub(crate) owner_agent_session: Option<String>,
    pub(crate) target_terminal: Option<String>,
    pub(crate) exit_code: Option<i32>,
    pub(crate) duration_ms: Option<u64>,
}

impl StatusMeta {
    /// Read the fields of a `workspace_status.set` request.
    pub(crate) fn from_fields(fields: &Map<String, Value>) -> anyhow::Result<Self> {
        let string = |value: Option<&Value>| value.and_then(Value::as_str).map(str::to_owned);
        let owner = fields.get("owner").and_then(Value::as_object);
        let owner_pid = match owner.and_then(|owner| owner.get("pid")) {
            None | Some(Value::Null) => None,
            Some(value) => Some(
                value
                    .as_u64()
                    .and_then(|pid| u32::try_from(pid).ok())
                    .filter(|pid| *pid > 1)
                    .ok_or_else(|| bad_request("owner.pid must be a process id above 1"))?,
            ),
        };
        let exit_code = match fields.get("exit_code") {
            None | Some(Value::Null) => None,
            Some(value) => Some(
                value
                    .as_i64()
                    .and_then(|code| i32::try_from(code).ok())
                    .ok_or_else(|| bad_request("exit_code must be an integer"))?,
            ),
        };
        Ok(Self {
            state: string(fields.get("state")),
            progress: fields.get("progress").and_then(Value::as_f64),
            style: string(fields.get("style")),
            ttl_ms: fields.get("ttl_ms").and_then(Value::as_u64),
            owner_pid,
            owner_terminal: string(owner.and_then(|owner| owner.get("terminal"))),
            owner_agent_session: string(owner.and_then(|owner| owner.get("agent_session"))),
            target_terminal: string(fields.get("target_terminal")),
            exit_code,
            duration_ms: fields.get("duration_ms").and_then(Value::as_u64),
        })
    }

    /// True when nothing beyond a plain status line was asked for.
    pub(crate) fn is_plain(&self) -> bool {
        self == &Self::default() || self == &Self { state: Some("info".into()), ..Self::default() }
    }

    /// Validate every field that needs no daemon state. `known_terminal`
    /// answers whether a terminal id names a terminal this session host runs.
    pub(crate) fn validate(&self, known_terminal: impl Fn(&TerminalPublicId) -> bool) -> anyhow::Result<()> {
        let state = self.state.as_deref().unwrap_or("info");
        if !STATES.contains(&state) {
            return Err(bad_request(format!("state must be one of {}", STATES.join(", "))));
        }
        if let Some(progress) = self.progress {
            if state != "busy" {
                return Err(bad_request("progress needs state busy"));
            }
            if !(progress.is_finite() && (0.0..=1.0).contains(&progress)) {
                return Err(bad_request("progress must be between 0 and 1"));
            }
        }
        if let Some(style) = self.style.as_deref()
            && !STYLES.contains(&style)
        {
            return Err(bad_request(format!("style must be one of {}", STYLES.join(", "))));
        }
        if let Some(ttl) = self.ttl_ms
            && !(1..=MAX_TTL_MS).contains(&ttl)
        {
            return Err(bad_request(format!("ttl_ms must be between 1 and {MAX_TTL_MS}")));
        }
        if (self.exit_code.is_some() || self.duration_ms.is_some()) && !matches!(state, "success" | "error") {
            return Err(bad_request("exit_code and duration_ms need state success or error"));
        }
        for (label, terminal) in
            [("owner.terminal", &self.owner_terminal), ("target_terminal", &self.target_terminal)]
        {
            let Some(terminal) = terminal else { continue };
            let id = TerminalPublicId::parse(terminal.clone())
                .map_err(|_| bad_request(format!("{label} must be a term_ id")))?;
            if !known_terminal(&id) {
                return Err(bad_request(format!("{label} {terminal} is not a terminal of this session")));
            }
        }
        if let Some(session) = self.owner_agent_session.as_deref()
            && (session.is_empty() || session.len() > 128 || session.chars().any(char::is_control))
        {
            return Err(bad_request("owner.agent_session must be 1-128 printable characters"));
        }
        Ok(())
    }
}

pub(crate) fn create_status_meta_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_status_meta (
           workspace_id TEXT NOT NULL,
           status_key TEXT NOT NULL,
           state TEXT NOT NULL,
           progress REAL,
           style TEXT,
           expires_at_ms INTEGER,
           owner_pid INTEGER,
           owner_machine TEXT,
           owner_terminal TEXT,
           owner_agent_session TEXT,
           target_terminal TEXT,
           exit_code INTEGER,
           duration_ms INTEGER,
           PRIMARY KEY(workspace_id, status_key)
         );",
    )?;
    Ok(())
}

/// Store (or drop, for a plain line) the meta of one entry the caller just
/// wrote. `machine` is the accepting daemon's machine id.
pub(crate) fn write_meta(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    key: &str,
    meta: &StatusMeta,
    machine: &str,
    now_ms: u64,
) -> anyhow::Result<()> {
    if meta.is_plain() {
        delete_meta(transaction, workspace_id, Some(key))?;
        return Ok(());
    }
    let expires = meta.ttl_ms.map(|ttl| now_ms.saturating_add(ttl));
    let to_i64 = |value: Option<u64>| value.map(i64::try_from).transpose();
    transaction.execute(
        "INSERT OR REPLACE INTO workspace_status_meta(
           workspace_id, status_key, state, progress, style, expires_at_ms, owner_pid,
           owner_machine, owner_terminal, owner_agent_session, target_terminal, exit_code,
           duration_ms
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
        params![
            workspace_id,
            key,
            meta.state.as_deref().unwrap_or("info"),
            meta.progress,
            meta.style,
            to_i64(expires)?,
            meta.owner_pid,
            meta.owner_pid.map(|_| machine),
            meta.owner_terminal,
            meta.owner_agent_session,
            meta.target_terminal,
            meta.exit_code,
            to_i64(meta.duration_ms)?,
        ],
    )?;
    Ok(())
}

/// Remove the meta of one entry, or of every entry of the workspace.
pub(crate) fn delete_meta(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    key: Option<&str>,
) -> anyhow::Result<()> {
    match key {
        Some(key) => transaction.execute(
            "DELETE FROM workspace_status_meta WHERE workspace_id = ?1 AND status_key = ?2",
            params![workspace_id, key],
        )?,
        None => transaction
            .execute("DELETE FROM workspace_status_meta WHERE workspace_id = ?1", [workspace_id])?,
    };
    Ok(())
}

/// Add the meta fields to each entry of a `WorkspaceStatusSnapshot`.
pub(crate) fn decorate_entries(
    connection: &Connection,
    workspace_id: &str,
    entries: &mut [Value],
) -> anyhow::Result<()> {
    let mut statement = connection.prepare(
        "SELECT state, progress, style, expires_at_ms, owner_pid, owner_machine, owner_terminal,
                owner_agent_session, target_terminal, exit_code, duration_ms
         FROM workspace_status_meta WHERE workspace_id = ?1 AND status_key = ?2",
    )?;
    for entry in entries.iter_mut() {
        let Some(key) = entry["key"].as_str().map(str::to_owned) else { continue };
        let meta = statement
            .query_row(params![workspace_id, key], |row| {
                let ms = |index: usize| -> rusqlite::Result<Option<String>> {
                    Ok(row.get::<_, Option<i64>>(index)?.map(|value| value.to_string()))
                };
                let mut owner = Map::new();
                if let Some(pid) = row.get::<_, Option<i64>>(4)? {
                    owner.insert("pid".into(), json!(pid));
                    owner.insert("machine".into(), json!(row.get::<_, Option<String>>(5)?));
                }
                if let Some(terminal) = row.get::<_, Option<String>>(6)? {
                    owner.insert("terminal".into(), json!(terminal));
                }
                if let Some(session) = row.get::<_, Option<String>>(7)? {
                    owner.insert("agent_session".into(), json!(session));
                }
                Ok(json!({
                    "state": row.get::<_, String>(0)?,
                    "progress": row.get::<_, Option<f64>>(1)?,
                    "style": row.get::<_, Option<String>>(2)?,
                    "expires_at_ms": ms(3)?,
                    "owner": if owner.is_empty() { Value::Null } else { Value::Object(owner) },
                    "target_terminal": row.get::<_, Option<String>>(8)?,
                    "exit_code": row.get::<_, Option<i64>>(9)?,
                    "duration_ms": ms(10)?,
                }))
            })
            .optional()?;
        let (Some(object), Some(Value::Object(meta))) = (entry.as_object_mut(), meta) else { continue };
        object.extend(meta);
    }
    Ok(())
}

/// What ended an owner, for `owned_entries`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "end", rename_all = "snake_case")]
pub(crate) enum OwnerEnd {
    Terminal { terminal: String },
    Process { pid: u32, machine: String },
    Expired { now_ms: u64 },
}

/// `(workspace_id, status_key)` of every entry `end` removes, ordered.
pub(crate) fn owned_entries(connection: &Connection, end: &OwnerEnd) -> anyhow::Result<Vec<(String, String)>> {
    const SELECT: &str = "SELECT workspace_id, status_key FROM workspace_status_meta WHERE ";
    let map = |row: &rusqlite::Row<'_>| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?));
    let rows = match end {
        OwnerEnd::Terminal { terminal } => connection
            .prepare(&format!("{SELECT}owner_terminal = ?1 ORDER BY 1, 2"))?
            .query_map(params![terminal], map)?
            .collect::<Result<Vec<_>, _>>()?,
        OwnerEnd::Process { pid, machine } => connection
            .prepare(&format!("{SELECT}owner_pid = ?1 AND owner_machine = ?2 ORDER BY 1, 2"))?
            .query_map(params![pid, machine], map)?
            .collect::<Result<Vec<_>, _>>()?,
        OwnerEnd::Expired { now_ms } => connection
            .prepare(&format!("{SELECT}expires_at_ms IS NOT NULL AND expires_at_ms <= ?1 ORDER BY 1, 2"))?
            .query_map(params![i64::try_from(*now_ms)?], map)?
            .collect::<Result<Vec<_>, _>>()?,
    };
    Ok(rows)
}

/// Remove the listed entries and their meta; returns the workspaces touched.
pub(crate) fn remove_entries(
    transaction: &Transaction<'_>,
    entries: &[(String, String)],
) -> anyhow::Result<Vec<String>> {
    let mut workspaces: Vec<String> = Vec::new();
    for (workspace, key) in entries {
        transaction.execute(
            "DELETE FROM workspace_status_entries WHERE workspace_id = ?1 AND status_key = ?2",
            params![workspace, key],
        )?;
        delete_meta(transaction, workspace, Some(key))?;
        if !workspaces.contains(workspace) {
            workspaces.push(workspace.clone());
        }
    }
    Ok(workspaces)
}

/// The earliest TTL deadline, if any entry has one.
pub(crate) fn next_expiry_ms(connection: &Connection) -> anyhow::Result<Option<u64>> {
    let next: Option<i64> =
        connection.query_row("SELECT MIN(expires_at_ms) FROM workspace_status_meta", [], |row| row.get(0))?;
    Ok(next.and_then(|value| u64::try_from(value).ok()))
}

/// Owners to watch after a daemon start: terminals, and processes of `machine`.
pub(crate) fn live_owners(connection: &Connection, machine: &str) -> anyhow::Result<(Vec<String>, Vec<u32>)> {
    let terminals = connection
        .prepare("SELECT DISTINCT owner_terminal FROM workspace_status_meta WHERE owner_terminal IS NOT NULL")?
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    let pids = connection
        .prepare("SELECT DISTINCT owner_pid FROM workspace_status_meta WHERE owner_pid IS NOT NULL AND owner_machine = ?1")?
        .query_map([machine], |row| row.get::<_, u32>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok((terminals, pids))
}

#[cfg(test)]
#[path = "status_meta_tests.rs"]
mod tests;
