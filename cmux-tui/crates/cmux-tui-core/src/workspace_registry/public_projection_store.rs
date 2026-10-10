//! Durable public resources whose canonical state is already present in the
//! mutation journals.
//!
//! Reopening a session reconstructs notifications from successful effect
//! receipts, agents from their bounded current-state projection, terminal
//! defaults from the latest retained mutation result, and frontend projections
//! from the table that already owns those values.

use std::collections::{HashMap, HashSet};

use anyhow::Context;
use rusqlite::params;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::*;

use crate::resource::{
    AgentPublicId, FrontendProjectionPublicId, NotificationPublicId, WireDecimal,
};
use crate::{CursorShape, DefaultColors, Rgb};

const NOTIFICATION_LEDGER_CAPACITY: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryNotificationProjection {
    pub id: NotificationPublicId,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: String,
    pub level: String,
    pub terminal_id: Option<TerminalPublicId>,
    pub created_at_ms: u64,
    pub unread: bool,
    /// Client ids that acknowledged this notification, sorted and unique.
    pub read_by: Vec<String>,
    /// `extra.source`, or derived from the idempotency key for receipts
    /// written before sources existed.
    pub source: crate::NotificationSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryAgentProjection {
    pub id: AgentPublicId,
    pub terminal_id: TerminalPublicId,
    pub state: String,
    pub source: String,
    pub updated_at_ms: u64,
    pub source_session: Option<String>,
    pub agent: Option<String>,
    /// The agent's native hook session id (`extra.agent_session_id`).
    pub agent_session_id: Option<String>,
}

/// The agent value's `extra` object. `agent_session_id` is present only when
/// a hook reported the agent's own session id.
pub(crate) fn agent_projection_extra(agent: Option<&str>, agent_session_id: Option<&str>) -> Value {
    let mut extra = json!({"agent": agent});
    if let Some(agent_session_id) = agent_session_id {
        extra["agent_session_id"] = json!(agent_session_id);
    }
    extra
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RegistryAgentHookState {
    pub terminal_id: TerminalPublicId,
    pub agent_session_id: String,
    pub applied_sequence: u64,
    pub ended: bool,
    pub ended_at_ms: Option<u64>,
}

impl RegistryAgentProjection {
    /// The public `AgentSnapshot` value for this projection, including
    /// `extra.agent_session_id` when a hook reported one.
    pub(crate) fn into_public_snapshot(self, session_id: &SessionPublicId) -> Value {
        let extra = agent_projection_extra(self.agent.as_deref(), self.agent_session_id.as_deref());
        json!({
            "id": self.id,
            "session_id": session_id,
            "terminal_id": self.terminal_id,
            "state": self.state,
            "source": self.source,
            "updated_at_ms": self.updated_at_ms.to_string(),
            "source_session": self.source_session,
            "extra": extra,
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegistryPublicProjections {
    /// Oldest first, matching the in-memory notification ledger.
    pub notifications: Vec<RegistryNotificationProjection>,
    pub agents: Vec<RegistryAgentProjection>,
    pub(crate) agent_hook_states: Vec<RegistryAgentHookState>,
    pub terminal_defaults: Option<DefaultColors>,
    pub frontend_projections: Vec<FrontendProjection>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredNotification {
    id: NotificationPublicId,
    session_id: SessionPublicId,
    title: String,
    #[serde(default)]
    subtitle: Option<String>,
    body: String,
    level: StoredNotificationLevel,
    terminal_id: Option<TerminalPublicId>,
    created_at_ms: WireDecimal,
    unread: bool,
    /// Read marks at commit time are always empty; the durable truth is the
    /// `resource_notification_reads` table, so this field is decoded and ignored.
    #[serde(default)]
    read_by: Vec<String>,
    #[serde(default)]
    extra: Option<HashMap<String, Value>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum StoredNotificationLevel {
    Info,
    Warning,
    Error,
}

impl StoredNotificationLevel {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredAgent {
    id: AgentPublicId,
    session_id: SessionPublicId,
    terminal_id: TerminalPublicId,
    state: StoredAgentState,
    source: StoredAgentSource,
    updated_at_ms: WireDecimal,
    source_session: Option<String>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    extra: Option<HashMap<String, Value>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum StoredAgentState {
    Working,
    Blocked,
    Idle,
    Done,
    Unknown,
}

impl StoredAgentState {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Blocked => "blocked",
            Self::Idle => "idle",
            Self::Done => "done",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum StoredAgentSource {
    Hook,
    Socket,
    Detected,
    Plugin,
}

impl StoredAgentSource {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Hook => "hook",
            Self::Socket => "socket",
            Self::Detected => "detected",
            Self::Plugin => "plugin",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredTerminalDefaults {
    foreground: Option<String>,
    background: Option<String>,
    cursor: Option<String>,
    selection_background: Option<String>,
    selection_foreground: Option<String>,
    cursor_style: Option<StoredCursorStyle>,
    cursor_blink: Option<bool>,
    palette: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum StoredCursorStyle {
    Block,
    Bar,
    Underline,
}

impl WorkspaceRegistry {
    /// Reconstruct public auxiliary state while the registry is the sole
    /// writer. Missing or tombstoned terminals remove notification links, while
    /// agent reports remain durable historical projections keyed by terminal.
    pub fn public_projections(&self) -> anyhow::Result<RegistryPublicProjections> {
        let live_terminals = self.live_terminal_public_ids()?;
        let notifications = self.durable_notifications(&live_terminals)?;
        let agents = self.durable_agents(None, None)?;
        let agent_hook_states = self.durable_agent_hook_states()?;
        let terminal_defaults = self.durable_terminal_defaults()?;
        let frontend_projections = self.public_frontend_projections()?;
        Ok(RegistryPublicProjections {
            notifications,
            agents,
            agent_hook_states,
            terminal_defaults,
            frontend_projections,
        })
    }

    /// Current agent projections, optionally filtered by terminal and state, decoded from
    /// their stored results (adapter and hook session id included).
    pub(crate) fn public_agent_projections(
        &self,
        terminal: Option<&TerminalPublicId>,
        state: Option<&str>,
    ) -> anyhow::Result<Vec<RegistryAgentProjection>> {
        let mut agents = self.durable_agents(terminal, state)?;
        agents.retain(|agent| {
            (agent.source != "hook" || agent.state != "done")
                && !agent
                    .source_session
                    .as_deref()
                    .is_some_and(|value| value.starts_with("cmux-hook-ended:"))
        });
        for agent in &mut agents {
            if agent.source_session.as_deref().is_some_and(|value| {
                value.starts_with("cmux-hook-sequence:") || value.starts_with("cmux-hook-ended:")
            }) {
                agent.source_session = None;
            }
        }
        Ok(agents)
    }

    pub(super) fn live_terminal_public_ids(&self) -> anyhow::Result<HashSet<TerminalPublicId>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT public_id
             FROM resource_terminals
             WHERE deleted_revision IS NULL
             ORDER BY public_id ASC",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .map(|row| Ok(TerminalPublicId::parse(row?)?))
            .collect()
    }

    pub(super) fn durable_notifications(
        &self,
        live_terminals: &HashSet<TerminalPublicId>,
    ) -> anyhow::Result<Vec<RegistryNotificationProjection>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT outcome_json, idempotency_key
             FROM resource_effect_receipts
             WHERE operation = 'notification.create'
               AND state = 'committed'
               AND json_extract(outcome_json, '$.kind') = 'success'
               AND json_extract(outcome_json, '$.value.id') NOT IN (
                 SELECT notification_id FROM resource_notification_clears
               )
             ORDER BY committed_revision DESC, idempotency_key DESC
             LIMIT ?1",
        )?;
        let rows = statement
            .query_map([i64::try_from(NOTIFICATION_LEDGER_CAPACITY)?], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut reads = self.durable_notification_reads()?;
        {
            // Marks for notifications outside the retained window are dead
            // weight after a restart (the in-memory prune queue did not
            // survive). Drop them here so the table stays bounded.
            let retained_ids = rows
                .iter()
                .filter_map(|(outcome_json, _)| {
                    serde_json::from_str::<Value>(outcome_json)
                        .ok()
                        .and_then(|value| value["value"]["id"].as_str().map(str::to_string))
                })
                .collect::<HashSet<String>>();
            let stale =
                reads.keys().filter(|id| !retained_ids.contains(*id)).cloned().collect::<Vec<_>>();
            for id in &stale {
                self.connection.get().execute(
                    "DELETE FROM resource_notification_reads WHERE notification_id = ?1",
                    [id.as_str()],
                )?;
                reads.remove(id);
            }
        }
        let acked = self.acked_notification_ids()?;
        let mut notifications = Vec::with_capacity(rows.len());
        for (outcome_json, idempotency_key) in rows {
            let outcome: ResourceEffectOutcome = serde_json::from_str(&outcome_json)
                .with_context(|| {
                    format!(
                        "invalid committed notification outcome for idempotency key {idempotency_key:?}"
                    )
                })?;
            let ResourceEffectOutcome::Success(value) = outcome else {
                anyhow::bail!(
                    "notification outcome selected as success decoded as a failure for idempotency key {idempotency_key:?}"
                );
            };
            let stored: StoredNotification = serde_json::from_value(value).with_context(|| {
                format!(
                    "invalid committed notification result for idempotency key {idempotency_key:?}"
                )
            })?;
            anyhow::ensure!(
                stored.session_id == self.session_id,
                "notification {} belongs to session {}, expected {}",
                stored.id,
                stored.session_id,
                self.session_id
            );
            let source = stored
                .extra
                .as_ref()
                .and_then(|extra| extra.get("source"))
                .and_then(Value::as_str)
                .and_then(crate::NotificationSource::parse)
                .unwrap_or_else(|| crate::NotificationSource::from_legacy_key(&idempotency_key));
            let _ = stored.read_by;
            let read_by = reads.remove(stored.id.as_str()).unwrap_or_default();
            // A closed terminal's notification has no ring to restore.
            let live = stored.terminal_id.as_ref().is_none_or(|id| live_terminals.contains(id));
            let unread = stored.unread && live && !acked.contains(stored.id.as_str());
            notifications.push(RegistryNotificationProjection {
                id: stored.id,
                title: stored.title,
                subtitle: stored.subtitle,
                body: stored.body,
                level: stored.level.as_str().to_string(),
                terminal_id: stored
                    .terminal_id
                    .filter(|terminal_id| live_terminals.contains(terminal_id)),
                created_at_ms: stored.created_at_ms.get(),
                unread,
                read_by,
                source,
            });
        }
        notifications.reverse();
        Ok(notifications)
    }

    /// Read marks stored for one notification, for tests that verify pruning.
    #[cfg(test)]
    pub(crate) fn durable_notification_read_clients(
        &self,
        notification_id: &str,
    ) -> anyhow::Result<Vec<String>> {
        Ok(self.durable_notification_reads()?.remove(notification_id).unwrap_or_default())
    }

    /// Per-client read marks keyed by notification id, each list sorted and
    /// unique. Rows for notifications the ledger evicted are pruned at the
    /// next acknowledgement, so this stays bounded.
    fn durable_notification_reads(&self) -> anyhow::Result<HashMap<String, Vec<String>>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT notification_id, client_id
             FROM resource_notification_reads
             ORDER BY notification_id ASC, client_id ASC",
        )?;
        let rows = statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut reads: HashMap<String, Vec<String>> = HashMap::new();
        for (notification_id, client_id) in rows {
            reads.entry(notification_id).or_default().push(client_id);
        }
        Ok(reads)
    }

    fn durable_agents(
        &self,
        terminal: Option<&TerminalPublicId>,
        state: Option<&str>,
    ) -> anyhow::Result<Vec<RegistryAgentProjection>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "WITH selected AS MATERIALIZED (
               SELECT projection.terminal_id,
                      projection.result_json,
                      projection.committed_revision
               FROM resource_agent_projections projection
               WHERE (?1 IS NULL OR projection.terminal_id = ?1)
             )
             SELECT terminal_id, result_json, committed_revision
             FROM selected
             WHERE (?2 IS NULL OR json_extract(result_json, '$.state') = ?2)
             ORDER BY json_extract(result_json, '$.id') ASC, terminal_id ASC",
        )?;
        let rows = statement
            .query_map(params![terminal.map(TerminalPublicId::as_str), state], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        let mut agents = Vec::with_capacity(rows.len());
        for (projected_terminal_id, result_json, committed_revision) in rows {
            let stored: StoredAgent = serde_json::from_str(&result_json).with_context(|| {
                format!(
                    "invalid agent projection for terminal {projected_terminal_id:?} at revision {committed_revision}"
                )
            })?;
            anyhow::ensure!(
                stored.terminal_id.as_str() == projected_terminal_id,
                "agent {} projection key {} does not match terminal {}",
                stored.id,
                projected_terminal_id,
                stored.terminal_id
            );
            anyhow::ensure!(
                stored.session_id == self.session_id,
                "agent {} belongs to session {}, expected {}",
                stored.id,
                stored.session_id,
                self.session_id
            );
            anyhow::ensure!(
                stored.id == agent_id(&stored.terminal_id)?,
                "agent {} does not match terminal {}",
                stored.id,
                stored.terminal_id
            );
            let agent_session_id = stored
                .extra
                .as_ref()
                .and_then(|extra| extra.get("agent_session_id"))
                .and_then(Value::as_str)
                .map(str::to_string);
            agents.push(RegistryAgentProjection {
                id: stored.id,
                terminal_id: stored.terminal_id,
                state: stored.state.as_str().to_string(),
                source: stored.source.as_str().to_string(),
                updated_at_ms: stored.updated_at_ms.get(),
                source_session: stored.source_session,
                agent: stored
                    .extra
                    .as_ref()
                    .and_then(|extra| extra.get("agent"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .or(stored.agent),
                agent_session_id,
            });
        }
        agents.reverse();
        Ok(agents)
    }

    fn durable_agent_hook_states(&self) -> anyhow::Result<Vec<RegistryAgentHookState>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT terminal_id, agent_session_id, applied_sequence, ended, ended_at_ms
             FROM resource_agent_hook_state
             ORDER BY terminal_id ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, bool>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                ))
            })?
            .map(|row| {
                let (terminal_id, agent_session_id, applied_sequence, ended, ended_at_ms) = row?;
                Ok(RegistryAgentHookState {
                    terminal_id: TerminalPublicId::parse(terminal_id)?,
                    agent_session_id,
                    applied_sequence: u64::try_from(applied_sequence)
                        .context("agent hook sequence is negative")?,
                    ended,
                    ended_at_ms: ended_at_ms
                        .map(u64::try_from)
                        .transpose()
                        .context("agent hook end time is negative")?,
                })
            })
            .collect()
    }

    fn durable_terminal_defaults(&self) -> anyhow::Result<Option<DefaultColors>> {
        let stored = self
            .connection
            .get()
            .query_row(
                "SELECT result_json, idempotency_key
                 FROM resource_mutations
                 WHERE operation = 'session.terminal_defaults.update'
                 ORDER BY committed_revision DESC, idempotency_key DESC
                 LIMIT 1",
                [],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        stored
            .map(|(result_json, idempotency_key)| {
                let value: Value = serde_json::from_str(&result_json).with_context(|| {
                    format!(
                        "invalid committed terminal defaults for idempotency key {idempotency_key:?}"
                    )
                })?;
                let object = value.as_object().with_context(|| {
                    format!(
                        "committed terminal defaults for idempotency key {idempotency_key:?} are not an object"
                    )
                })?;
                for field in [
                    "foreground",
                    "background",
                    "cursor",
                    "selection_background",
                    "selection_foreground",
                    "cursor_style",
                    "cursor_blink",
                    "palette",
                ] {
                    anyhow::ensure!(
                        object.contains_key(field),
                        "committed terminal defaults for idempotency key {idempotency_key:?} omitted {field}"
                    );
                }
                let stored: StoredTerminalDefaults = serde_json::from_str(&result_json)
                    .with_context(|| {
                        format!(
                            "invalid committed terminal defaults for idempotency key {idempotency_key:?}"
                        )
                    })?;
                decode_terminal_defaults(stored)
            })
            .transpose()
    }

    /// Every native frontend's projections (the resource API's own rows
    /// excluded), for the launch snapshot (`launch-snapshot-v1`).
    pub(crate) fn native_frontend_projections(&self) -> anyhow::Result<Vec<FrontendProjection>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT frontend, scope, subject_key, schema_version,
                    projection_revision, payload
             FROM frontend_projections
             WHERE frontend <> 'resource-api'
             ORDER BY frontend ASC, scope ASC, subject_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })?
            .map(|row| {
                let (frontend, scope, subject_key, schema_version, projection_revision, payload) =
                    row?;
                Ok(FrontendProjection {
                    frontend,
                    scope,
                    subject_key,
                    schema_version: u32::try_from(schema_version)
                        .context("projection schema version is invalid")?,
                    projection_revision: u64::try_from(projection_revision)
                        .context("projection revision is negative")?,
                    projection: serde_json::from_str(&payload)
                        .context("frontend projection contains invalid JSON")?,
                })
            })
            .collect()
    }

    pub fn public_frontend_projections(&self) -> anyhow::Result<Vec<FrontendProjection>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT frontend, scope, subject_key, schema_version,
                    projection_revision, payload
             FROM frontend_projections
             WHERE frontend = 'resource-api' AND scope = 'session'
             ORDER BY subject_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })?
            .map(|row| {
                let (
                    frontend,
                    scope,
                    subject_key,
                    schema_version,
                    projection_revision,
                    payload,
                ) = row?;
                validate_identifier("frontend", &frontend)?;
                validate_identifier("projection scope", &scope)?;
                FrontendProjectionPublicId::parse(subject_key.as_str())?;
                anyhow::ensure!(
                    schema_version
                        == i64::from(RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION),
                    "frontend projection {subject_key} has unsupported schema version {schema_version}"
                );
                anyhow::ensure!(
                    projection_revision > 0,
                    "frontend projection {subject_key} has invalid revision {projection_revision}"
                );
                anyhow::ensure!(
                    payload.len() <= MAX_PROJECTION_BYTES,
                    "frontend projection {subject_key} exceeds {MAX_PROJECTION_BYTES} bytes"
                );
                let projection = serde_json::from_str(&payload).with_context(|| {
                    format!("frontend projection {subject_key} contains invalid JSON")
                })?;
                Ok(FrontendProjection {
                    frontend,
                    scope,
                    subject_key,
                    schema_version: u32::try_from(schema_version)
                        .context("projection schema version is invalid")?,
                    projection_revision: u64::try_from(projection_revision)
                        .context("projection revision is negative")?,
                    projection,
                })
            })
            .collect()
    }

    #[cfg(test)]
    pub(crate) fn insert_corrupt_terminal_defaults_for_test(&self) {
        self.connection
            .get()
            .execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(
                   'corrupt-terminal-defaults', 'test',
                   'session.terminal_defaults.update', '{}',
                   '{\"foreground\":\"red\"}', 9223372036854775807
                 )",
                [],
            )
            .unwrap();
    }

    #[cfg(test)]
    pub(crate) fn corrupt_agent_projection_for_test(&self, terminal_id: &TerminalPublicId) {
        self.connection
            .get()
            .execute(
                "UPDATE resource_agent_projections
                 SET result_json = json_set(result_json, '$.state', 'corrupt')
                 WHERE terminal_id = ?1",
                [terminal_id.as_str()],
            )
            .unwrap();
    }
}

fn agent_id(terminal_id: &TerminalPublicId) -> anyhow::Result<AgentPublicId> {
    let digest = Sha256::digest(format!("cmux.protocol/2/agent/{terminal_id}").as_bytes());
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    AgentPublicId::parse(format!("agent_{payload}")).map_err(Into::into)
}

fn decode_terminal_defaults(stored: StoredTerminalDefaults) -> anyhow::Result<DefaultColors> {
    let mut palette = [None; 256];
    for (index, color) in stored.palette {
        let index = index
            .parse::<u8>()
            .with_context(|| format!("terminal palette index {index:?} is invalid"))?;
        anyhow::ensure!(
            palette[usize::from(index)].is_none(),
            "terminal palette index {index} is duplicated"
        );
        palette[usize::from(index)] = Some(parse_rgb(&color)?);
    }
    Ok(DefaultColors {
        fg: stored.foreground.as_deref().map(parse_rgb).transpose()?,
        bg: stored.background.as_deref().map(parse_rgb).transpose()?,
        cursor: stored.cursor.as_deref().map(parse_rgb).transpose()?,
        selection_bg: stored.selection_background.as_deref().map(parse_rgb).transpose()?,
        selection_fg: stored.selection_foreground.as_deref().map(parse_rgb).transpose()?,
        cursor_style: stored.cursor_style.map(|style| match style {
            StoredCursorStyle::Block => CursorShape::Block,
            StoredCursorStyle::Bar => CursorShape::Bar,
            StoredCursorStyle::Underline => CursorShape::Underline,
        }),
        cursor_blink: stored.cursor_blink,
        palette,
    })
}

fn parse_rgb(value: &str) -> anyhow::Result<Rgb> {
    let hex = value
        .strip_prefix('#')
        .filter(|hex| hex.len() == 6)
        .with_context(|| format!("terminal color {value:?} must use #rrggbb"))?;
    let parse = |range| {
        u8::from_str_radix(&hex[range], 16)
            .with_context(|| format!("terminal color {value:?} must use #rrggbb"))
    };
    Ok(Rgb { r: parse(0..2)?, g: parse(2..4)?, b: parse(4..6)? })
}

#[cfg(test)]
mod tests;
