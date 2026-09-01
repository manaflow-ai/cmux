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
    pub body: String,
    pub level: String,
    pub terminal_id: Option<TerminalPublicId>,
    pub created_at_ms: u64,
    pub unread: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryAgentProjection {
    pub id: AgentPublicId,
    pub terminal_id: TerminalPublicId,
    pub state: String,
    pub source: String,
    pub updated_at_ms: u64,
    pub source_session: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RegistryAgentHookState {
    pub terminal_id: TerminalPublicId,
    pub agent_session_id: String,
    pub applied_sequence: u64,
    pub ended: bool,
}

impl RegistryAgentProjection {
    pub(crate) fn into_public_snapshot(self, session_id: &SessionPublicId) -> Value {
        json!({
            "id": self.id,
            "session_id": session_id,
            "terminal_id": self.terminal_id,
            "state": self.state,
            "source": self.source,
            "updated_at_ms": self.updated_at_ms.to_string(),
            "source_session": self.source_session,
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
    body: String,
    level: StoredNotificationLevel,
    terminal_id: Option<TerminalPublicId>,
    created_at_ms: WireDecimal,
    unread: bool,
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
}

impl StoredAgentSource {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Hook => "hook",
            Self::Socket => "socket",
            Self::Detected => "detected",
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

    fn live_terminal_public_ids(&self) -> anyhow::Result<HashSet<TerminalPublicId>> {
        let mut statement = self.connection.prepare(
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

    fn durable_notifications(
        &self,
        live_terminals: &HashSet<TerminalPublicId>,
    ) -> anyhow::Result<Vec<RegistryNotificationProjection>> {
        let mut statement = self.connection.prepare(
            "SELECT outcome_json, idempotency_key
             FROM resource_effect_receipts
             WHERE operation = 'notification.create'
               AND state = 'committed'
               AND json_extract(outcome_json, '$.kind') = 'success'
             ORDER BY committed_revision DESC, idempotency_key DESC
             LIMIT ?1",
        )?;
        let rows = statement
            .query_map([i64::try_from(NOTIFICATION_LEDGER_CAPACITY)?], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
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
            let _ = stored.extra;
            notifications.push(RegistryNotificationProjection {
                id: stored.id,
                title: stored.title,
                body: stored.body,
                level: stored.level.as_str().to_string(),
                terminal_id: stored
                    .terminal_id
                    .filter(|terminal_id| live_terminals.contains(terminal_id)),
                created_at_ms: stored.created_at_ms.get(),
                unread: stored.unread,
            });
        }
        notifications.reverse();
        Ok(notifications)
    }

    fn durable_agents(
        &self,
        terminal: Option<&TerminalPublicId>,
        state: Option<&str>,
    ) -> anyhow::Result<Vec<RegistryAgentProjection>> {
        let mut statement = self.connection.prepare(
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
            let _ = stored.extra;
            agents.push(RegistryAgentProjection {
                id: stored.id,
                terminal_id: stored.terminal_id,
                state: stored.state.as_str().to_string(),
                source: stored.source.as_str().to_string(),
                updated_at_ms: stored.updated_at_ms.get(),
                source_session: stored.source_session,
            });
        }
        agents.reverse();
        Ok(agents)
    }

    fn durable_agent_hook_states(&self) -> anyhow::Result<Vec<RegistryAgentHookState>> {
        let mut statement = self.connection.prepare(
            "SELECT terminal_id, agent_session_id, applied_sequence, ended
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
                ))
            })?
            .map(|row| {
                let (terminal_id, agent_session_id, applied_sequence, ended) = row?;
                Ok(RegistryAgentHookState {
                    terminal_id: TerminalPublicId::parse(terminal_id)?,
                    agent_session_id,
                    applied_sequence: u64::try_from(applied_sequence)
                        .context("agent hook sequence is negative")?,
                    ended,
                })
            })
            .collect()
    }

    fn durable_terminal_defaults(&self) -> anyhow::Result<Option<DefaultColors>> {
        let stored = self
            .connection
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

    pub fn public_frontend_projections(&self) -> anyhow::Result<Vec<FrontendProjection>> {
        let mut statement = self.connection.prepare(
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
mod tests {
    use super::*;
    use serde_json::json;

    fn terminal_id(value: u128) -> TerminalPublicId {
        TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
    }

    fn notification_id(value: u128) -> NotificationPublicId {
        NotificationPublicId::parse(format!("notification_{value:032x}")).unwrap()
    }

    fn projection_id(value: u128) -> FrontendProjectionPublicId {
        FrontendProjectionPublicId::parse(format!("projection_{value:032x}")).unwrap()
    }

    fn seed_live_terminal(
        registry: &mut WorkspaceRegistry,
    ) -> (TerminalPublicId, PanePublicId, TabPublicId) {
        const HOST_ID: &str = "00000000000040008000000000000001";
        let workspace = RegistryWorkspace {
            id: 1,
            public_id: WorkspacePublicId::parse("ws_00000000000000000000000000000001").unwrap(),
            key: "workspace-one".into(),
            name: "One".into(),
            group_key: "public-projections".into(),
        };
        let screen = ScreenPublicId::parse("screen_00000000000000000000000000000001").unwrap();
        let pane = PanePublicId::parse("pane_00000000000000000000000000000001").unwrap();
        let tab = TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
        let terminal = terminal_id(1);
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("seed-terminal", "test").unwrap(),
                "workspace.create",
                &json!({"fixture":"live-terminal"}),
                None,
                Some(0),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertWorkspace {
                            workspace: workspace.clone(),
                            position: 0,
                            active_screen: Some(screen.clone()),
                        },
                        ResourceChange::UpsertScreen(RegistryScreen {
                            public_id: screen.clone(),
                            workspace_id: workspace.public_id.clone(),
                            position: 0,
                            name: None,
                            layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                            active_pane: pane.clone(),
                            zoomed_pane: None,
                            auto_layout: None,
                            viewport: RegistryViewport::default(),
                        }),
                        ResourceChange::UpsertPane(RegistryPane {
                            public_id: pane.clone(),
                            screen_id: screen.clone(),
                            name: None,
                            active_tab: Some(tab.clone()),
                            creation_ordinal: 1,
                        }),
                        ResourceChange::UpsertTerminal {
                            public_id: terminal.clone(),
                            terminal: RegistryTerminal {
                                terminal_id: HOST_ID.into(),
                                workspace_key: workspace.key.clone(),
                                incarnation: None,
                                lifecycle: TerminalLifecycle::Launching,
                                launch_spec: json!({}),
                                exit: None,
                                on_exit: TerminalOnExit::Close,
                            },
                        },
                        ResourceChange::UpsertTab(RegistryTab {
                            public_id: tab.clone(),
                            pane_id: pane.clone(),
                            position: 0,
                            content_id: ContentPublicId::Terminal(terminal.clone()),
                            name: None,
                            browser_url: None,
                            terminal_id: Some(HOST_ID.into()),
                        }),
                        ResourceChange::SetWorkspaceOrder {
                            workspace_ids: vec![workspace.public_id.clone()],
                        },
                        ResourceChange::SetScreenOrder {
                            workspace_id: workspace.public_id.clone(),
                            screen_ids: vec![screen],
                        },
                        ResourceChange::SetTabOrder {
                            pane_id: pane.clone(),
                            tab_ids: vec![tab.clone()],
                        },
                        ResourceChange::SetActiveWorkspace {
                            workspace_id: Some(workspace.public_id),
                        },
                    ],
                },
                &json!({"created":true}),
                &json!([]),
            )
            .unwrap();
        (terminal, pane, tab)
    }

    fn insert_mutation(
        registry: &WorkspaceRegistry,
        key: &str,
        operation: &str,
        result: &Value,
        revision: i64,
    ) {
        registry
            .connection
            .execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', ?2, '{}', ?3, ?4)",
                params![key, operation, canonical_json(result).unwrap(), revision],
            )
            .unwrap();
        if operation == "agent.report" {
            let terminal_id = result["terminal_id"].as_str().unwrap();
            registry
                .connection
                .execute(
                    "INSERT INTO resource_agent_projections(
                       terminal_id, result_json, committed_revision
                     )
                     SELECT ?1, ?2, ?3
                     WHERE EXISTS (
                       SELECT 1 FROM resource_terminals
                       WHERE public_id = ?1 AND deleted_revision IS NULL
                     )
                     ON CONFLICT(terminal_id) DO UPDATE SET
                       result_json = excluded.result_json,
                       committed_revision = excluded.committed_revision",
                    params![terminal_id, canonical_json(result).unwrap(), revision,],
                )
                .unwrap();
        }
    }

    fn insert_notification(registry: &WorkspaceRegistry, key: &str, result: &Value, revision: i64) {
        let outcome = ResourceEffectOutcome::Success(result.clone());
        registry
            .connection
            .execute(
                "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(?1, 'notification.create', '{}', '{}', 'committed', ?2, ?3)",
                params![
                    key,
                    canonical_json(&serde_json::to_value(outcome).unwrap()).unwrap(),
                    revision
                ],
            )
            .unwrap();
    }

    fn defaults(foreground: &str) -> Value {
        json!({
            "foreground":foreground,
            "background":null,
            "cursor":null,
            "selection_background":null,
            "selection_foreground":null,
            "cursor_style":"bar",
            "cursor_blink":true,
            "palette":{"0":"#010203","255":"#fdfefe"},
        })
    }

    #[test]
    fn reconstructs_bounded_notifications_latest_agents_defaults_and_projections() {
        let mut registry = WorkspaceRegistry::in_memory("public-projections").unwrap();
        let session = registry.session_id().clone();
        for revision in 1..=260 {
            insert_notification(
                &registry,
                &format!("notification-{revision}"),
                &json!({
                    "id":notification_id(revision),
                    "session_id":session,
                    "title":format!("title-{revision}"),
                    "body":"",
                    "level":"info",
                    "created_at_ms":revision.to_string(),
                    "unread":false,
                }),
                revision as i64,
            );
        }
        let terminal = terminal_id(1);
        let agent = agent_id(&terminal).unwrap();
        insert_mutation(
            &registry,
            "agent-old",
            "agent.report",
            &json!({
                "id":agent,
                "session_id":session,
                "terminal_id":terminal,
                "state":"working",
                "source":"hook",
                "updated_at_ms":"1",
                "source_session":null,
            }),
            261,
        );
        insert_mutation(
            &registry,
            "agent-new",
            "agent.report",
            &json!({
                "id":agent,
                "session_id":session,
                "terminal_id":terminal,
                "state":"done",
                "source":"hook",
                "updated_at_ms":"2",
                "source_session":"agent-session",
            }),
            262,
        );
        insert_mutation(
            &registry,
            "defaults-old",
            "session.terminal_defaults.update",
            &defaults("#111111"),
            263,
        );
        insert_mutation(
            &registry,
            "defaults-new",
            "session.terminal_defaults.update",
            &defaults("#abcdef"),
            264,
        );
        let projection = projection_id(1);
        registry
            .put_frontend_projection(
                &WorkspaceMutation::new("projection-one", "test").unwrap(),
                "resource-api",
                "session",
                projection.as_str(),
                RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION,
                None,
                &json!({
                    "frontend_id":"cmux-test",
                    "window_id":"window-test",
                    "generation":"launch-test",
                    "projection":{"columns":[1,2]},
                }),
            )
            .unwrap();

        // This fixture has no terminal row, so notification links are cleared
        // and the historical agent mutations never form a valid projection.
        let restored = registry.public_projections().unwrap();
        assert_eq!(restored.notifications.len(), 256);
        assert_eq!(restored.notifications.first().unwrap().title, "title-5");
        assert_eq!(restored.notifications.last().unwrap().title, "title-260");
        assert!(restored.notifications.iter().all(|item| item.terminal_id.is_none()));
        assert!(restored.agents.is_empty());
        let defaults = restored.terminal_defaults.unwrap();
        assert_eq!(defaults.fg, Some(Rgb { r: 0xab, g: 0xcd, b: 0xef }));
        assert_eq!(defaults.cursor_style, Some(CursorShape::Bar));
        assert_eq!(defaults.palette[0], Some(Rgb { r: 1, g: 2, b: 3 }));
        assert_eq!(defaults.palette[255], Some(Rgb { r: 0xfd, g: 0xfe, b: 0xfe }));
        assert_eq!(restored.frontend_projections.len(), 1);
        assert_eq!(restored.frontend_projections[0].subject_key, projection.as_str());
        assert_eq!(
            restored.frontend_projections[0].projection["projection"],
            json!({"columns":[1,2]})
        );
    }

    #[test]
    fn malformed_authoritative_rows_fail_closed() {
        let registry = WorkspaceRegistry::in_memory("malformed-public-projections").unwrap();
        insert_mutation(
            &registry,
            "bad-defaults",
            "session.terminal_defaults.update",
            &json!({
                "foreground":"red",
                "background":null,
                "cursor":null,
                "selection_background":null,
                "selection_foreground":null,
                "cursor_style":null,
                "cursor_blink":null,
                "palette":{},
            }),
            1,
        );
        let error = registry.public_projections().unwrap_err().to_string();
        assert!(error.contains("terminal color \"red\" must use #rrggbb"), "{error}");
    }

    #[test]
    fn malformed_notification_outcome_fails_closed() {
        let registry = WorkspaceRegistry::in_memory("malformed-notification").unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES('bad-notification', 'notification.create', '{}', '{}',
                          'committed', '{\"kind\":\"success\",\"value\":{\"id\":7}}', 1)",
                [],
            )
            .unwrap();
        let error = registry.public_projections().unwrap_err().to_string();
        assert!(error.contains("invalid committed notification result"), "{error}");
    }

    #[test]
    fn agent_projections_survive_terminal_tombstones() {
        let mut registry = WorkspaceRegistry::in_memory("terminal-relationships").unwrap();
        let session = registry.session_id().clone();
        let (terminal, pane, tab) = seed_live_terminal(&mut registry);
        let agent = agent_id(&terminal).unwrap();
        insert_mutation(
            &registry,
            "agent-live",
            "agent.report",
            &json!({
                "id":agent,
                "session_id":session,
                "terminal_id":terminal,
                "state":"working",
                "source":"hook",
                "updated_at_ms":"10",
                "source_session":null,
            }),
            2,
        );
        insert_notification(
            &registry,
            "notification-live",
            &json!({
                "id":notification_id(1),
                "session_id":session,
                "title":"terminal",
                "body":"",
                "level":"warning",
                "terminal_id":terminal,
                "created_at_ms":"11",
                "unread":true,
            }),
            3,
        );

        let live = registry.public_projections().unwrap();
        assert_eq!(live.agents.len(), 1);
        assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
        assert_eq!(live.agents[0].terminal_id, terminal);
        assert_eq!(live.notifications[0].terminal_id, Some(terminal.clone()));
        assert!(live.notifications[0].unread);

        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("tombstone-terminal", "test").unwrap(),
                "terminal.close",
                &json!({"terminal_id":terminal}),
                None,
                Some(1),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertPane(RegistryPane {
                            public_id: pane.clone(),
                            screen_id: ScreenPublicId::parse(
                                "screen_00000000000000000000000000000001",
                            )
                            .unwrap(),
                            name: None,
                            active_tab: None,
                            creation_ordinal: 1,
                        }),
                        ResourceChange::TombstoneTab { tab_id: tab, close_content: true },
                        ResourceChange::TombstoneTerminal {
                            public_id: terminal.clone(),
                            expected_incarnation: None,
                        },
                        ResourceChange::SetTabOrder { pane_id: pane, tab_ids: Vec::new() },
                    ],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap();

        let tombstoned = registry.public_projections().unwrap();
        assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
        assert_eq!(tombstoned.agents.len(), 1);
        assert_eq!(tombstoned.agents[0].terminal_id, terminal);
        assert_eq!(tombstoned.notifications.len(), 1);
        assert_eq!(tombstoned.notifications[0].terminal_id, None);
    }
}
