use super::*;
use std::borrow::Cow;
use std::collections::BTreeSet;
use std::time::{SystemTime, UNIX_EPOCH};

const JOURNAL_RECORD_SCHEMA_VERSION: u32 = 1;
const MAX_JOURNAL_PAGE_SIZE: usize = 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalClass {
    State,
    Observation,
    Effect,
    Checkpoint,
}

impl JournalClass {
    fn as_str(self) -> &'static str {
        match self {
            Self::State => "state",
            Self::Observation => "observation",
            Self::Effect => "effect",
            Self::Checkpoint => "checkpoint",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalReplayPolicy {
    Required,
    Advisory,
    Never,
}

impl JournalReplayPolicy {
    fn as_str(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::Advisory => "advisory",
            Self::Never => "never",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalSensitivity {
    Public,
    Metadata,
    Sensitive,
    Secret,
}

impl JournalSensitivity {
    fn as_str(self) -> &'static str {
        match self {
            Self::Public => "public",
            Self::Metadata => "metadata",
            Self::Sensitive => "sensitive",
            Self::Secret => "secret",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducer {
    pub kind: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalAuthority {
    pub principal_id: String,
    pub lease_id: String,
    pub generation: String,
    pub role: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalSubject {
    pub kind: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionJournalRecord {
    pub sequence: u64,
    pub event_id: String,
    pub schema_version: u32,
    pub kind: String,
    pub class: JournalClass,
    pub replay: JournalReplayPolicy,
    pub occurred_at_ms: u64,
    pub committed_at_ms: u64,
    pub producer: JournalProducer,
    pub authority: Option<JournalAuthority>,
    pub causation_id: Option<String>,
    pub correlation_id: Option<String>,
    pub causation_depth: u16,
    pub subjects: Vec<JournalSubject>,
    pub sensitivity: JournalSensitivity,
    pub payload: Value,
    pub resource_revision: Option<u64>,
    pub previous_resource_revision: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SessionJournalPage {
    pub head_sequence: u64,
    pub records: Vec<SessionJournalRecord>,
}

struct JournalAppend<'a> {
    event_id: &'a str,
    kind: &'a str,
    class: JournalClass,
    replay: JournalReplayPolicy,
    occurred_at_ms: u64,
    producer: &'a JournalProducer,
    authority: Option<&'a JournalAuthority>,
    causation_id: Option<&'a str>,
    correlation_id: Option<&'a str>,
    causation_depth: u16,
    subjects: &'a [JournalSubject],
    sensitivity: JournalSensitivity,
    payload: &'a Value,
    resource_revision: Option<u64>,
    previous_resource_revision: Option<u64>,
}

pub(super) fn create_session_journal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_journal (
           sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           event_id TEXT UNIQUE NOT NULL,
           schema_version INTEGER NOT NULL CHECK(schema_version > 0),
           kind TEXT NOT NULL,
           class TEXT NOT NULL CHECK(class IN ('state', 'observation', 'effect', 'checkpoint')),
           replay_policy TEXT NOT NULL CHECK(replay_policy IN ('required', 'advisory', 'never')),
           occurred_at_ms INTEGER NOT NULL CHECK(occurred_at_ms >= 0),
           committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
           producer_json TEXT NOT NULL CHECK(json_valid(producer_json)),
           authority_json TEXT CHECK(authority_json IS NULL OR json_valid(authority_json)),
           causation_id TEXT,
           correlation_id TEXT,
           causation_depth INTEGER NOT NULL CHECK(causation_depth >= 0),
           subjects_json TEXT NOT NULL CHECK(json_valid(subjects_json)),
           sensitivity TEXT NOT NULL CHECK(sensitivity IN ('public', 'metadata', 'sensitive', 'secret')),
           payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
           resource_revision INTEGER UNIQUE,
           previous_resource_revision INTEGER,
           CHECK(
             (resource_revision IS NULL AND previous_resource_revision IS NULL)
             OR (
               resource_revision IS NOT NULL
               AND previous_resource_revision IS NOT NULL
               AND resource_revision = previous_resource_revision + 1
             )
           )
         );
         CREATE INDEX IF NOT EXISTS session_journal_by_kind_sequence
           ON session_journal(kind, sequence);
         CREATE INDEX IF NOT EXISTS session_journal_by_correlation_sequence
           ON session_journal(correlation_id, sequence)
           WHERE correlation_id IS NOT NULL;
         CREATE TRIGGER IF NOT EXISTS session_journal_reject_update
           BEFORE UPDATE ON session_journal
         BEGIN
           SELECT RAISE(ABORT, 'session journal is append-only');
         END;
         CREATE TRIGGER IF NOT EXISTS session_journal_reject_delete
           BEFORE DELETE ON session_journal
         BEGIN
           SELECT RAISE(ABORT, 'session journal is append-only');
         END;",
    )?;
    Ok(())
}

pub(super) fn migrate_resource_events_to_session_journal(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    create_session_journal_schema(transaction)?;
    let has_resource_events = table_exists(transaction, "resource_events")?;

    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let (oldest_revision, newest_revision) = if has_resource_events {
        transaction.query_row(
            "SELECT MIN(revision), MAX(revision) FROM resource_events",
            [],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )?
    } else {
        (None, None)
    };
    let resource_head_revision = transaction_resource_revision(transaction)?;
    let history_complete = resource_head_revision == 0
        || (oldest_revision == Some(1)
            && newest_revision
                == Some(
                    i64::try_from(resource_head_revision)
                        .context("resource revision exceeds SQLite range")?,
                ));
    let subject = JournalSubject { kind: "session".into(), id: session_id };
    let producer = JournalProducer { kind: "migration".into(), id: "workspace-registry-v8".into() };
    let payload = serde_json::json!({
        "source": if has_resource_events { "resource_events" } else { "projection_only" },
        "oldest_retained_resource_revision": oldest_revision.map(|value| value.to_string()),
        "newest_retained_resource_revision": newest_revision.map(|value| value.to_string()),
        "resource_head_revision": resource_head_revision.to_string(),
        "history_complete": history_complete,
    });
    append_journal_record(
        transaction,
        &JournalAppend {
            event_id: "event_session_journal_v9_migration",
            kind: "session.journal.migrated",
            class: JournalClass::Checkpoint,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms: 0,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: None,
            causation_depth: 0,
            subjects: &[subject],
            sensitivity: JournalSensitivity::Metadata,
            payload: &payload,
            resource_revision: None,
            previous_resource_revision: None,
        },
    )?;

    let rows = if has_resource_events {
        let mut statement = transaction.prepare(
            "SELECT event.revision, event.previous_revision, event.origin,
                    event.idempotency_key, event.deltas_json,
                    mutation.operation, mutation.result_json
             FROM resource_events AS event
             LEFT JOIN resource_mutations AS mutation
               ON mutation.idempotency_key = event.idempotency_key
             ORDER BY event.revision ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    } else {
        Vec::new()
    };
    for (revision, previous_revision, origin, idempotency_key, changes, operation, result) in rows {
        let revision = u64::try_from(revision).context("stored resource revision is negative")?;
        let previous_revision = u64::try_from(previous_revision)
            .context("stored previous resource revision is negative")?;
        let changes = serde_json::from_str::<Value>(&changes)?;
        let result = result
            .as_deref()
            .map(serde_json::from_str::<Value>)
            .transpose()?
            .unwrap_or(Value::Null);
        append_resource_journal_record_at(
            transaction,
            revision,
            previous_revision,
            &origin,
            &idempotency_key,
            operation.as_deref().unwrap_or("resource.legacy"),
            None,
            &result,
            &changes,
            0,
        )?;
    }
    if has_resource_events {
        transaction.execute_batch("DROP TABLE resource_events;")?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn append_resource_journal_record(
    transaction: &Transaction<'_>,
    revision: u64,
    previous_revision: u64,
    origin: &str,
    idempotency_key: &str,
    operation: &str,
    patch: Option<&ResourcePatch>,
    result: &Value,
    changes: &Value,
) -> anyhow::Result<()> {
    append_resource_journal_record_at(
        transaction,
        revision,
        previous_revision,
        origin,
        idempotency_key,
        operation,
        patch,
        result,
        changes,
        unix_epoch_ms()?,
    )
}

#[allow(clippy::too_many_arguments)]
fn append_resource_journal_record_at(
    transaction: &Transaction<'_>,
    revision: u64,
    previous_revision: u64,
    origin: &str,
    idempotency_key: &str,
    operation: &str,
    patch: Option<&ResourcePatch>,
    result: &Value,
    changes: &Value,
    occurred_at_ms: u64,
) -> anyhow::Result<()> {
    validate_identifier("journal operation", operation)?;
    let kind = semantic_journal_kind(operation);
    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let mut subjects = BTreeSet::from([JournalSubject { kind: "session".into(), id: session_id }]);
    if let Some(patch) = patch {
        collect_patch_subjects(patch, &mut subjects);
    }
    collect_subjects(result, &mut subjects);
    collect_subjects(changes, &mut subjects);
    expand_topology_subjects(transaction, &mut subjects)?;
    let subjects = subjects.into_iter().collect::<Vec<_>>();
    let producer = JournalProducer { kind: "resource_operation".into(), id: origin.into() };
    let payload = serde_json::json!({
        "idempotency_key": idempotency_key,
        "result": result,
        "changes": changes,
    });
    let event_id = format!("event_resource_{revision:020}");
    append_journal_record(
        transaction,
        &JournalAppend {
            event_id: &event_id,
            kind: &kind,
            class: JournalClass::State,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: Some(idempotency_key),
            causation_depth: 0,
            subjects: &subjects,
            sensitivity: JournalSensitivity::Sensitive,
            payload: &payload,
            resource_revision: Some(revision),
            previous_resource_revision: Some(previous_revision),
        },
    )?;
    Ok(())
}

fn append_journal_record(
    transaction: &Transaction<'_>,
    append: &JournalAppend<'_>,
) -> anyhow::Result<u64> {
    validate_identifier("journal event id", append.event_id)?;
    validate_identifier("journal event kind", append.kind)?;
    let committed_at_ms =
        if append.occurred_at_ms == 0 { unix_epoch_ms()? } else { append.occurred_at_ms };
    transaction.execute(
        "INSERT INTO session_journal(
           event_id, schema_version, kind, class, replay_policy,
           occurred_at_ms, committed_at_ms, producer_json, authority_json,
           causation_id, correlation_id, causation_depth, subjects_json,
           sensitivity, payload_json, resource_revision, previous_resource_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
        params![
            append.event_id,
            i64::from(JOURNAL_RECORD_SCHEMA_VERSION),
            append.kind,
            append.class.as_str(),
            append.replay.as_str(),
            i64::try_from(append.occurred_at_ms).context("journal occurrence time is too large")?,
            i64::try_from(committed_at_ms).context("journal commit time is too large")?,
            canonical_json(&serde_json::to_value(append.producer)?)?,
            append
                .authority
                .map(serde_json::to_value)
                .transpose()?
                .as_ref()
                .map(canonical_json)
                .transpose()?,
            append.causation_id,
            append.correlation_id,
            i64::from(append.causation_depth),
            canonical_json(&serde_json::to_value(append.subjects)?)?,
            append.sensitivity.as_str(),
            canonical_json(append.payload)?,
            append
                .resource_revision
                .map(i64::try_from)
                .transpose()
                .context("resource revision exceeds SQLite range")?,
            append
                .previous_resource_revision
                .map(i64::try_from)
                .transpose()
                .context("previous resource revision exceeds SQLite range")?,
        ],
    )?;
    u64::try_from(transaction.last_insert_rowid()).context("journal sequence is negative")
}

impl WorkspaceRegistry {
    pub fn session_journal_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> anyhow::Result<SessionJournalPage> {
        anyhow::ensure!(limit > 0, "journal page limit must be positive");
        anyhow::ensure!(
            limit <= MAX_JOURNAL_PAGE_SIZE,
            "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
        );
        let head_sequence = self.connection.query_row(
            "SELECT COALESCE(MAX(sequence), 0) FROM session_journal",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let head_sequence =
            u64::try_from(head_sequence).context("journal head sequence is negative")?;
        anyhow::ensure!(
            sequence <= head_sequence,
            "cursor.invalid: journal sequence {sequence} is ahead of {head_sequence}"
        );
        let mut statement = self.connection.prepare(
            "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                    occurred_at_ms, committed_at_ms, producer_json, authority_json,
                    causation_id, correlation_id, causation_depth, subjects_json,
                    sensitivity, payload_json, resource_revision, previous_resource_revision
             FROM session_journal
             WHERE sequence > ?1
             ORDER BY sequence ASC
             LIMIT ?2",
        )?;
        let records = statement
            .query_map(
                params![
                    i64::try_from(sequence).context("journal sequence exceeds SQLite range")?,
                    i64::try_from(limit).context("journal page limit exceeds SQLite range")?,
                ],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, String>(8)?,
                        row.get::<_, Option<String>>(9)?,
                        row.get::<_, Option<String>>(10)?,
                        row.get::<_, Option<String>>(11)?,
                        row.get::<_, i64>(12)?,
                        row.get::<_, String>(13)?,
                        row.get::<_, String>(14)?,
                        row.get::<_, String>(15)?,
                        row.get::<_, Option<i64>>(16)?,
                        row.get::<_, Option<i64>>(17)?,
                    ))
                },
            )?
            .map(|row| decode_record(row?))
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(SessionJournalPage { head_sequence, records })
    }
}

#[allow(clippy::type_complexity)]
fn decode_record(
    row: (
        i64,
        String,
        i64,
        String,
        String,
        String,
        i64,
        i64,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        i64,
        String,
        String,
        String,
        Option<i64>,
        Option<i64>,
    ),
) -> anyhow::Result<SessionJournalRecord> {
    let (
        sequence,
        event_id,
        schema_version,
        kind,
        class,
        replay,
        occurred_at_ms,
        committed_at_ms,
        producer,
        authority,
        causation_id,
        correlation_id,
        causation_depth,
        subjects,
        sensitivity,
        payload,
        resource_revision,
        previous_resource_revision,
    ) = row;
    Ok(SessionJournalRecord {
        sequence: u64::try_from(sequence).context("journal sequence is negative")?,
        event_id,
        schema_version: u32::try_from(schema_version)
            .context("journal schema version is invalid")?,
        kind,
        class: match class.as_str() {
            "state" => JournalClass::State,
            "observation" => JournalClass::Observation,
            "effect" => JournalClass::Effect,
            "checkpoint" => JournalClass::Checkpoint,
            _ => anyhow::bail!("unknown journal class {class:?}"),
        },
        replay: match replay.as_str() {
            "required" => JournalReplayPolicy::Required,
            "advisory" => JournalReplayPolicy::Advisory,
            "never" => JournalReplayPolicy::Never,
            _ => anyhow::bail!("unknown journal replay policy {replay:?}"),
        },
        occurred_at_ms: u64::try_from(occurred_at_ms)
            .context("journal occurrence time is negative")?,
        committed_at_ms: u64::try_from(committed_at_ms)
            .context("journal commit time is negative")?,
        producer: serde_json::from_str(&producer)?,
        authority: authority.as_deref().map(serde_json::from_str).transpose()?,
        causation_id,
        correlation_id,
        causation_depth: u16::try_from(causation_depth)
            .context("journal causation depth is invalid")?,
        subjects: serde_json::from_str(&subjects)?,
        sensitivity: match sensitivity.as_str() {
            "public" => JournalSensitivity::Public,
            "metadata" => JournalSensitivity::Metadata,
            "sensitive" => JournalSensitivity::Sensitive,
            "secret" => JournalSensitivity::Secret,
            _ => anyhow::bail!("unknown journal sensitivity {sensitivity:?}"),
        },
        payload: serde_json::from_str(&payload)?,
        resource_revision: resource_revision
            .map(u64::try_from)
            .transpose()
            .context("journal resource revision is negative")?,
        previous_resource_revision: previous_resource_revision
            .map(u64::try_from)
            .transpose()
            .context("journal previous resource revision is negative")?,
    })
}

fn collect_patch_subjects(patch: &ResourcePatch, subjects: &mut BTreeSet<JournalSubject>) {
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, active_screen, .. } => {
                insert_subject(subjects, "workspace", workspace.public_id.as_str());
                if let Some(screen) = active_screen {
                    insert_subject(subjects, "screen", screen.as_str());
                }
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                insert_subject(subjects, "workspace", workspace_id.as_str());
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                for workspace in workspace_ids {
                    insert_subject(subjects, "workspace", workspace.as_str());
                }
            }
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                if let Some(workspace) = workspace_id {
                    insert_subject(subjects, "workspace", workspace.as_str());
                }
            }
            ResourceChange::UpsertScreen(screen) => {
                insert_subject(subjects, "screen", screen.public_id.as_str());
                insert_subject(subjects, "workspace", screen.workspace_id.as_str());
                insert_subject(subjects, "pane", screen.active_pane.as_str());
                if let Some(pane) = &screen.zoomed_pane {
                    insert_subject(subjects, "pane", pane.as_str());
                }
                if let Some(panes) = &screen.auto_layout {
                    for pane in panes {
                        insert_subject(subjects, "pane", pane.as_str());
                    }
                }
                collect_layout_subjects(&screen.layout, subjects);
                for column in &screen.viewport.columns {
                    insert_subject(subjects, "split", column.id.as_str());
                    collect_layout_subjects(&column.layout, subjects);
                    if let Some(panes) = &column.auto_layout {
                        for pane in panes {
                            insert_subject(subjects, "pane", pane.as_str());
                        }
                    }
                }
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                insert_subject(subjects, "screen", screen_id.as_str());
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                insert_subject(subjects, "workspace", workspace_id.as_str());
                for screen in screen_ids {
                    insert_subject(subjects, "screen", screen.as_str());
                }
            }
            ResourceChange::UpsertPane(pane) => {
                insert_subject(subjects, "pane", pane.public_id.as_str());
                insert_subject(subjects, "screen", pane.screen_id.as_str());
                if let Some(tab) = &pane.active_tab {
                    insert_subject(subjects, "tab", tab.as_str());
                }
            }
            ResourceChange::TombstonePane { pane_id } => {
                insert_subject(subjects, "pane", pane_id.as_str());
            }
            ResourceChange::UpsertTab(tab) => {
                insert_subject(subjects, "tab", tab.public_id.as_str());
                insert_subject(subjects, "pane", tab.pane_id.as_str());
                match &tab.content_id {
                    ContentPublicId::Terminal(terminal) => {
                        insert_subject(subjects, "terminal", terminal.as_str());
                    }
                    ContentPublicId::Browser(browser) => {
                        insert_subject(subjects, "browser", browser.as_str());
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id } => {
                insert_subject(subjects, "tab", tab_id.as_str());
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                insert_subject(subjects, "pane", pane_id.as_str());
                for tab in tab_ids {
                    insert_subject(subjects, "tab", tab.as_str());
                }
            }
            ResourceChange::UpsertTerminal { public_id, .. }
            | ResourceChange::TombstoneTerminal { public_id, .. } => {
                insert_subject(subjects, "terminal", public_id.as_str());
            }
            ResourceChange::UpsertBrowser(browser) => {
                insert_subject(subjects, "browser", browser.public_id.as_str());
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                insert_subject(subjects, "browser", public_id.as_str());
            }
        }
    }
}

fn collect_layout_subjects(layout: &RegistryLayoutNode, subjects: &mut BTreeSet<JournalSubject>) {
    match layout {
        RegistryLayoutNode::Leaf { pane } => insert_subject(subjects, "pane", pane.as_str()),
        RegistryLayoutNode::Split { split, first, second, .. } => {
            insert_subject(subjects, "split", split.as_str());
            collect_layout_subjects(first, subjects);
            collect_layout_subjects(second, subjects);
        }
        RegistryLayoutNode::Stack { panes, expanded } => {
            for pane in panes {
                insert_subject(subjects, "pane", pane.as_str());
            }
            insert_subject(subjects, "pane", expanded.as_str());
        }
    }
}

fn insert_subject(subjects: &mut BTreeSet<JournalSubject>, kind: &str, id: &str) {
    subjects.insert(JournalSubject { kind: kind.into(), id: id.into() });
}

fn collect_subjects(value: &Value, subjects: &mut BTreeSet<JournalSubject>) {
    match value {
        Value::Array(values) => {
            for value in values {
                collect_subjects(value, subjects);
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                collect_subjects(value, subjects);
            }
        }
        Value::String(value) => {
            if let Some(kind) = public_id_kind(value) {
                subjects.insert(JournalSubject { kind: kind.into(), id: value.clone() });
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

fn expand_topology_subjects(
    transaction: &Transaction<'_>,
    subjects: &mut BTreeSet<JournalSubject>,
) -> anyhow::Result<()> {
    if !subjects.iter().any(|subject| {
        matches!(subject.kind.as_str(), "screen" | "pane" | "tab" | "terminal" | "browser")
    }) {
        return Ok(());
    }
    let ids = subjects.iter().map(|subject| &subject.id).collect::<Vec<_>>();
    let ids_json = canonical_json(&serde_json::to_value(ids)?)?;
    let mut statement = transaction.prepare(
        "WITH seeds(id) AS (
           SELECT value FROM json_each(?1)
         ),
         tab_paths(tab_id, pane_id, screen_id, workspace_id) AS (
           SELECT tab.public_id, tab.pane_id, pane.screen_id, screen.workspace_id
           FROM resource_tabs AS tab
           JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
           WHERE tab.public_id IN (SELECT id FROM seeds)
              OR tab.content_id IN (SELECT id FROM seeds)
         ),
         pane_paths(pane_id, screen_id, workspace_id) AS (
           SELECT pane.public_id, pane.screen_id, screen.workspace_id
           FROM resource_panes AS pane
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
           WHERE pane.public_id IN (SELECT id FROM seeds)
         ),
         screen_paths(screen_id, workspace_id) AS (
           SELECT screen.public_id, screen.workspace_id
           FROM resource_screens AS screen
           WHERE screen.public_id IN (SELECT id FROM seeds)
         )
         SELECT 'tab', tab_id FROM tab_paths
         UNION SELECT 'pane', pane_id FROM tab_paths
         UNION SELECT 'screen', screen_id FROM tab_paths
         UNION SELECT 'workspace', workspace_id FROM tab_paths
         UNION SELECT 'pane', pane_id FROM pane_paths
         UNION SELECT 'screen', screen_id FROM pane_paths
         UNION SELECT 'workspace', workspace_id FROM pane_paths
         UNION SELECT 'screen', screen_id FROM screen_paths
         UNION SELECT 'workspace', workspace_id FROM screen_paths",
    )?;
    let expanded = statement
        .query_map([ids_json], |row| Ok(JournalSubject { kind: row.get(0)?, id: row.get(1)? }))?
        .collect::<Result<Vec<_>, _>>()?;
    subjects.extend(expanded);
    Ok(())
}

fn public_id_kind(value: &str) -> Option<&'static str> {
    const PREFIXES: [(&str, &str); 17] = [
        ("frontend_projection", "projection"),
        ("pairing_request", "pairing"),
        ("sidebar_plugin", "sidebar_plugin"),
        ("sidebar_view", "sidebar_view"),
        ("notification", "notification"),
        ("workspace", "ws"),
        ("terminal", "term"),
        ("session", "session"),
        ("machine", "machine"),
        ("screen", "screen"),
        ("browser", "browser"),
        ("client", "client"),
        ("pane", "pane"),
        ("split", "split"),
        ("agent", "agent"),
        ("stream", "stream"),
        ("tab", "tab"),
    ];
    for (kind, prefix) in PREFIXES {
        let Some(payload) = value.strip_prefix(prefix).and_then(|value| value.strip_prefix('_'))
        else {
            continue;
        };
        if payload.len() == 32
            && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Some(kind);
        }
    }
    None
}

fn semantic_journal_kind(operation: &str) -> Cow<'_, str> {
    if operation.contains('-') && !operation.contains('.') {
        Cow::Owned(operation.replace('-', "."))
    } else {
        Cow::Borrowed(operation)
    }
}

fn table_exists(transaction: &Transaction<'_>, table: &str) -> anyhow::Result<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn unix_epoch_ms() -> anyhow::Result<u64> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?;
    u64::try_from(duration.as_millis()).context("system clock exceeds journal range")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resource_record_is_typed_scoped_and_append_only() {
        let mut registry = WorkspaceRegistry::in_memory("journal").unwrap();
        let workspace_id = format!("ws_{}", "1".repeat(32));
        let pane_id = format!("pane_{}", "2".repeat(32));
        let result = serde_json::json!({"workspace_id":workspace_id});
        let changes = serde_json::json!([{
            "kind":"upsert",
            "resource":"pane",
            "id":pane_id,
            "value":{"workspace_id":workspace_id,"pane_id":pane_id}
        }]);
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
        append_resource_journal_record(
            &tx,
            1,
            0,
            "test-client",
            "focus-one",
            "pane.focus",
            None,
            &result,
            &changes,
        )
        .unwrap();
        tx.commit().unwrap();

        let page = registry.session_journal_after(0, 10).unwrap();
        assert_eq!(page.head_sequence, 1);
        assert_eq!(page.records.len(), 1);
        let record = &page.records[0];
        assert_eq!(record.kind, "pane.focus");
        assert_eq!(record.class, JournalClass::State);
        assert_eq!(record.replay, JournalReplayPolicy::Required);
        assert_eq!(record.correlation_id.as_deref(), Some("focus-one"));
        assert_eq!(record.resource_revision, Some(1));
        assert_eq!(record.previous_resource_revision, Some(0));
        assert!(
            record
                .subjects
                .iter()
                .any(|subject| { subject.kind == "workspace" && subject.id == workspace_id })
        );
        assert!(
            record.subjects.iter().any(|subject| subject.kind == "pane" && subject.id == pane_id)
        );

        let update = registry
            .connection
            .execute("UPDATE session_journal SET kind = 'pane.changed' WHERE sequence = 1", []);
        assert!(update.unwrap_err().to_string().contains("append-only"));
        let delete = registry.connection.execute("DELETE FROM session_journal", []);
        assert!(delete.unwrap_err().to_string().contains("append-only"));
    }

    #[test]
    fn migration_marks_incomplete_history_and_preserves_retained_events() {
        let mut registry = WorkspaceRegistry::in_memory("migration").unwrap();
        let tx = registry.connection.transaction().unwrap();
        tx.execute_batch(
            "DROP TABLE session_journal;
             CREATE TABLE resource_events (
               revision INTEGER PRIMARY KEY NOT NULL,
               previous_revision INTEGER NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               deltas_json TEXT NOT NULL
             );
             UPDATE meta SET value = '4' WHERE key = 'resource_revision';",
        )
        .unwrap();
        let result = serde_json::json!({"focused":true});
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES('test', 'focus-four', 'pane.focus', '{}', ?1, 4)",
            [canonical_json(&result).unwrap()],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(4, 3, 'test', 'focus-four', '[]')",
            [],
        )
        .unwrap();
        migrate_resource_events_to_session_journal(&tx).unwrap();
        tx.commit().unwrap();

        let page = registry.session_journal_after(0, 10).unwrap();
        assert_eq!(page.records.len(), 2);
        assert_eq!(page.records[0].kind, "session.journal.migrated");
        assert_eq!(page.records[0].payload["history_complete"], false);
        assert_eq!(page.records[1].kind, "pane.focus");
        assert_eq!(page.records[1].resource_revision, Some(4));
        assert_eq!(registry.resource_events_after(3).unwrap().batches.len(), 1);
    }

    #[test]
    fn migration_marks_projection_only_legacy_history_incomplete() {
        let mut registry = WorkspaceRegistry::in_memory("projection-only-migration").unwrap();
        let tx = registry.connection.transaction().unwrap();
        tx.execute_batch(
            "DROP TABLE session_journal;
             UPDATE meta SET value = '7' WHERE key = 'resource_revision';",
        )
        .unwrap();
        migrate_resource_events_to_session_journal(&tx).unwrap();
        tx.commit().unwrap();

        let page = registry.session_journal_after(0, 10).unwrap();
        assert_eq!(page.records.len(), 1);
        assert_eq!(page.records[0].kind, "session.journal.migrated");
        assert_eq!(page.records[0].payload["source"], "projection_only");
        assert_eq!(page.records[0].payload["resource_head_revision"], "7");
        assert_eq!(page.records[0].payload["history_complete"], false);
    }

    #[test]
    fn journal_cursor_and_page_limits_fail_closed() {
        let registry = WorkspaceRegistry::in_memory("limits").unwrap();
        assert!(registry.session_journal_after(1, 1).unwrap_err().to_string().contains("ahead"));
        assert!(registry.session_journal_after(0, 0).unwrap_err().to_string().contains("positive"));
        assert!(
            registry
                .session_journal_after(0, MAX_JOURNAL_PAGE_SIZE + 1)
                .unwrap_err()
                .to_string()
                .contains("exceeds")
        );
    }
}
