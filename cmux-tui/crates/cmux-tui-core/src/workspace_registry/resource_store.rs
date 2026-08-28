use super::*;

/// Completed pure mutations keep a finite exactly-once replay window. Pruning
/// runs in batches, so a live registry may temporarily retain the interval as
/// slack; startup always restores the hard bound. Non-terminal effect or
/// creation receipts remain protected by their authoritative receipt tables.
pub(super) const RESOURCE_MUTATION_REPLAY_CAPACITY: usize = 4096;
pub(super) const RESOURCE_MUTATION_PRUNE_INTERVAL: u64 = 128;
const RESOURCE_EVENT_PAGE_SIZE: usize = 1024;
pub(super) const AGENT_HOOK_RETRY_PAGE_SIZE: i64 = 64;
// Rows that reach this cap stay durable as dead-letter records. Selectors
// exclude them, so a permanent projection failure cannot spin forever.
pub(super) const AGENT_HOOK_MAX_ATTEMPTS: i64 = 8;
pub(crate) const AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE: usize = 16;

pub(super) fn create_resource_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_identities (
           public_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (kind = 'workspace' AND length(public_id) = 35 AND substr(public_id, 1, 3) = 'ws_'
               AND substr(public_id, 4) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'screen' AND length(public_id) = 39 AND substr(public_id, 1, 7) = 'screen_'
               AND substr(public_id, 8) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'pane' AND length(public_id) = 37 AND substr(public_id, 1, 5) = 'pane_'
               AND substr(public_id, 6) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'tab' AND length(public_id) = 36 AND substr(public_id, 1, 4) = 'tab_'
               AND substr(public_id, 5) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'terminal' AND length(public_id) = 37 AND substr(public_id, 1, 5) = 'term_'
               AND substr(public_id, 6) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'browser' AND length(public_id) = 40 AND substr(public_id, 1, 8) = 'browser_'
               AND substr(public_id, 9) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'split' AND length(public_id) = 38 AND substr(public_id, 1, 6) = 'split_'
               AND substr(public_id, 7) NOT GLOB '*[^0-9a-f]*')
           )
         );
         CREATE TABLE IF NOT EXISTS resource_workspaces (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           workspace_key TEXT UNIQUE NOT NULL REFERENCES workspaces(workspace_key)
             DEFERRABLE INITIALLY DEFERRED,
           active_screen_id TEXT REFERENCES resource_screens(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE TABLE IF NOT EXISTS resource_screens (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           workspace_id TEXT NOT NULL REFERENCES resource_workspaces(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           position INTEGER,
           name TEXT,
           layout_json TEXT NOT NULL,
           active_pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           zoomed_pane_id TEXT REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           auto_layout_json TEXT,
           viewport_json TEXT NOT NULL,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND position IS NOT NULL) OR
             (deleted_revision IS NOT NULL AND position IS NULL)
           )
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_resource_screen_position
           ON resource_screens(workspace_id, position) WHERE deleted_revision IS NULL;
         CREATE TABLE IF NOT EXISTS resource_panes (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           screen_id TEXT NOT NULL REFERENCES resource_screens(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           name TEXT,
           active_tab_id TEXT REFERENCES resource_tabs(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           creation_ordinal INTEGER NOT NULL,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE TABLE IF NOT EXISTS resource_tabs (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           position INTEGER,
           content_kind TEXT NOT NULL CHECK(content_kind IN ('terminal','browser')),
           content_id TEXT NOT NULL REFERENCES resource_identities(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           name TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND position IS NOT NULL) OR
             (deleted_revision IS NOT NULL AND position IS NULL)
           )
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_resource_tab_position
           ON resource_tabs(pane_id, position) WHERE deleted_revision IS NULL;
         CREATE INDEX IF NOT EXISTS resource_tabs_by_content
           ON resource_tabs(content_id);
         CREATE UNIQUE INDEX IF NOT EXISTS live_resource_browser_view
           ON resource_tabs(content_id)
           WHERE content_kind = 'browser' AND deleted_revision IS NULL;
         CREATE TABLE IF NOT EXISTS resource_terminals (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           terminal_id TEXT UNIQUE NOT NULL REFERENCES terminal_hosts(terminal_id)
             DEFERRABLE INITIALLY DEFERRED,
           lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','tombstoned')),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND lifecycle = 'active') OR
             (deleted_revision IS NOT NULL AND lifecycle = 'tombstoned')
           )
         );
         CREATE TABLE IF NOT EXISTS resource_browsers (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           url TEXT NOT NULL,
           metadata_json TEXT NOT NULL,
           lifecycle TEXT NOT NULL CHECK(lifecycle IN ('running','tombstoned')),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND lifecycle = 'running') OR
             (deleted_revision IS NOT NULL AND lifecycle = 'tombstoned')
           )
         );
         CREATE TABLE IF NOT EXISTS resource_mutations (
           idempotency_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           operation TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(idempotency_key)
         );
         CREATE TABLE IF NOT EXISTS resource_agent_projections (
           terminal_id TEXT PRIMARY KEY NOT NULL
             REFERENCES resource_terminals(public_id) ON DELETE CASCADE,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL CHECK(committed_revision >= 0),
           CHECK (
             json_valid(result_json)
             AND COALESCE(
               json_extract(result_json, '$.terminal_id') = terminal_id,
               0
             )
           )
         );
         CREATE TABLE IF NOT EXISTS resource_agent_hook_state (
           terminal_id TEXT PRIMARY KEY NOT NULL
             REFERENCES resource_terminals(public_id) ON DELETE CASCADE,
           agent_session_id TEXT NOT NULL,
           applied_sequence INTEGER NOT NULL CHECK(applied_sequence >= 0),
           ended INTEGER NOT NULL CHECK(ended IN (0, 1)),
           committed_revision INTEGER NOT NULL CHECK(committed_revision >= 0)
         );
         CREATE TABLE IF NOT EXISTS resource_agent_hook_pending (
           producer_id TEXT NOT NULL,
           origin TEXT NOT NULL,
           idempotency_key TEXT NOT NULL,
           terminal_id TEXT,
           event_sequence INTEGER NOT NULL CHECK(event_sequence >= 0),
           ingress_json TEXT NOT NULL CHECK(json_valid(ingress_json)),
           error TEXT NOT NULL,
           attempt INTEGER NOT NULL CHECK(attempt >= 0),
           PRIMARY KEY(producer_id, origin, idempotency_key)
         );
         DROP TRIGGER IF EXISTS resource_agent_projection_terminal_tombstone;
         CREATE INDEX IF NOT EXISTS resource_mutations_by_operation_revision
           ON resource_mutations(operation, committed_revision DESC);
         CREATE INDEX IF NOT EXISTS resource_agent_projections_by_revision
           ON resource_agent_projections(committed_revision DESC, terminal_id DESC);
         CREATE INDEX IF NOT EXISTS resource_agent_projections_by_state_revision
           ON resource_agent_projections(
             json_extract(result_json, '$.state'),
             committed_revision DESC,
             terminal_id DESC
           );",
    )?;
    let has_scoped_pending = transaction
        .prepare("PRAGMA table_info(resource_agent_hook_pending)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "producer_id");
    if !has_scoped_pending {
        transaction.execute_batch(
            "ALTER TABLE resource_agent_hook_pending RENAME TO resource_agent_hook_pending_legacy;
             CREATE TABLE resource_agent_hook_pending (
               producer_id TEXT NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               terminal_id TEXT,
               event_sequence INTEGER NOT NULL CHECK(event_sequence >= 0),
               ingress_json TEXT NOT NULL CHECK(json_valid(ingress_json)),
               error TEXT NOT NULL,
               attempt INTEGER NOT NULL CHECK(attempt >= 0),
               PRIMARY KEY(producer_id, origin, idempotency_key)
             );
             INSERT INTO resource_agent_hook_pending(
               producer_id, origin, idempotency_key, terminal_id, event_sequence, ingress_json, error, attempt
             ) SELECT '', '', idempotency_key,
               (SELECT json_extract(value, '$.id')
                FROM json_each(resource_agent_hook_pending_legacy.ingress_json, '$.subjects')
                WHERE json_extract(value, '$.kind') = 'terminal' LIMIT 1),
               event_sequence, ingress_json, error, attempt
             FROM resource_agent_hook_pending_legacy;
             DROP TABLE resource_agent_hook_pending_legacy;",
        )?;
    }
    let has_pending_terminal_id = transaction
        .prepare("PRAGMA table_info(resource_agent_hook_pending)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?
        .iter()
        .any(|column| column == "terminal_id");
    if !has_pending_terminal_id {
        transaction
            .execute("ALTER TABLE resource_agent_hook_pending ADD COLUMN terminal_id TEXT", [])?;
        transaction.execute(
            "UPDATE resource_agent_hook_pending
             SET terminal_id = (
               SELECT json_extract(value, '$.id')
               FROM json_each(resource_agent_hook_pending.ingress_json, '$.subjects')
               WHERE json_extract(value, '$.kind') = 'terminal' LIMIT 1
             )
             WHERE terminal_id IS NULL",
            [],
        )?;
    }
    transaction.execute_batch(
        "DROP INDEX IF EXISTS resource_agent_hook_pending_by_terminal;
         CREATE INDEX IF NOT EXISTS resource_agent_hook_pending_by_terminal
           ON resource_agent_hook_pending(terminal_id, event_sequence, idempotency_key);",
    )?;
    Ok(())
}

/// Schema 9 turns tabs into view items. Terminal content may be referenced by
/// any number of live tabs, while browser content retains its single-view
/// invariant. Foreign keys are disabled by the caller for this table rebuild
/// and checked immediately after the migration commits.
pub(super) fn migrate_resource_tabs_to_multiview(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let duplicate_live_browser = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM resource_tabs
           WHERE content_kind = 'browser' AND deleted_revision IS NULL
           GROUP BY content_id HAVING COUNT(*) > 1
         )",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    anyhow::ensure!(
        !duplicate_live_browser,
        "workspace registry contains multiple live views for one browser"
    );
    transaction.execute_batch(
        "DROP INDEX IF EXISTS live_resource_tab_position;
         DROP INDEX IF EXISTS live_resource_browser_view;
         CREATE TABLE resource_tabs_multiview (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           position INTEGER,
           content_kind TEXT NOT NULL CHECK(content_kind IN ('terminal','browser')),
           content_id TEXT NOT NULL REFERENCES resource_identities(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           name TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND position IS NOT NULL) OR
             (deleted_revision IS NOT NULL AND position IS NULL)
           )
         );
         INSERT INTO resource_tabs_multiview(
           public_id, pane_id, position, content_kind, content_id, name,
           created_revision, updated_revision, deleted_revision
         )
         SELECT public_id, pane_id, position, content_kind, content_id, name,
                created_revision, updated_revision, deleted_revision
         FROM resource_tabs;
         DROP TABLE resource_tabs;
         ALTER TABLE resource_tabs_multiview RENAME TO resource_tabs;
         CREATE UNIQUE INDEX live_resource_tab_position
           ON resource_tabs(pane_id, position) WHERE deleted_revision IS NULL;
         CREATE INDEX resource_tabs_by_content
           ON resource_tabs(content_id);
         CREATE UNIQUE INDEX live_resource_browser_view
           ON resource_tabs(content_id)
           WHERE content_kind = 'browser' AND deleted_revision IS NULL;",
    )?;
    Ok(())
}

/// Detect a legacy table-level `UNIQUE(content_id)` constraint or a missing or
/// malformed browser-view index. Any such shape must be rebuilt before terminal
/// content can have multiple views without weakening the one-live-view browser rule.
pub(super) fn resource_tabs_needs_multiview_normalization(
    connection: &Connection,
) -> anyhow::Result<bool> {
    const CANONICAL_BROWSER_VIEW_INDEX: &str = concat!(
        "create unique index live_resource_browser_view on resource_tabs(content_id)",
        " where content_kind = 'browser' and deleted_revision is null",
    );
    let mut indexes = connection
        .prepare("SELECT name, [unique], partial FROM pragma_index_list('resource_tabs')")?;
    let indexes = indexes
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?, row.get::<_, bool>(2)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut saw_browser_view_index = false;
    for (name, unique, partial) in indexes {
        let mut columns =
            connection.prepare("SELECT name FROM pragma_index_info(?1) ORDER BY seqno ASC")?;
        let columns = columns
            .query_map([&name], |row| row.get::<_, Option<String>>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let indexes_content = columns.as_slice() == [Some("content_id".to_string())];
        if name == "live_resource_browser_view" {
            saw_browser_view_index = true;
            let definition = connection.query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?1",
                [&name],
                |row| row.get::<_, Option<String>>(0),
            )?;
            let definition = definition
                .unwrap_or_default()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
                .to_ascii_lowercase();
            if !unique || !partial || !indexes_content || definition != CANONICAL_BROWSER_VIEW_INDEX
            {
                return Ok(true);
            }
            continue;
        }
        if unique && !partial && indexes_content {
            return Ok(true);
        }
    }
    Ok(!saw_browser_view_index)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentHookProjectionState {
    pub agent_session_id: String,
    pub applied_sequence: u64,
    pub ended: bool,
}

pub(super) fn migrate_resource_agent_projections(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute(
        "WITH ranked AS (
           SELECT result_json, committed_revision,
                  json_extract(result_json, '$.terminal_id') AS terminal_id,
                  ROW_NUMBER() OVER (
                    PARTITION BY json_extract(result_json, '$.terminal_id')
                    ORDER BY committed_revision DESC, idempotency_key DESC
                  ) AS terminal_rank
           FROM resource_mutations
           WHERE operation = 'agent.report'
         )
         INSERT INTO resource_agent_projections(
           terminal_id, result_json, committed_revision
         )
         SELECT ranked.terminal_id, ranked.result_json, ranked.committed_revision
         FROM ranked
         JOIN resource_terminals AS terminal
           ON terminal.public_id = ranked.terminal_id
         WHERE ranked.terminal_rank = 1
         ON CONFLICT(terminal_id) DO UPDATE SET
           result_json = excluded.result_json,
           committed_revision = excluded.committed_revision",
        [],
    )?;
    Ok(())
}

pub(super) fn migrate_resource_mutations_to_session_scope(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "ALTER TABLE resource_mutations RENAME TO resource_mutations_by_origin;
         CREATE TABLE resource_mutations (
           idempotency_key TEXT PRIMARY KEY NOT NULL,
           origin TEXT NOT NULL,
           operation TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL
         );
         INSERT INTO resource_mutations(
           idempotency_key, origin, operation, fingerprint, result_json, committed_revision
         )
         SELECT idempotency_key, origin, operation, fingerprint, result_json, committed_revision
         FROM resource_mutations_by_origin;
         DROP TABLE resource_mutations_by_origin;
         CREATE INDEX IF NOT EXISTS resource_mutations_by_operation_revision
           ON resource_mutations(operation, committed_revision DESC);",
    )?;
    Ok(())
}

pub(super) fn initialize_resource_mutation_retention(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    compact_resource_mutations(transaction)
}

pub(super) fn prune_resource_mutations(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    if transaction_resource_revision(transaction)? % RESOURCE_MUTATION_PRUNE_INTERVAL != 0 {
        return Ok(());
    }
    compact_resource_mutations(transaction)
}

fn compact_resource_mutations(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM resource_mutations
         WHERE rowid IN (
           SELECT candidate.rowid
           FROM resource_mutations AS candidate
           WHERE candidate.rowid != COALESCE((
                   SELECT latest.rowid
                   FROM resource_mutations AS latest
                   WHERE latest.operation = 'session.terminal_defaults.update'
                   ORDER BY latest.committed_revision DESC, latest.rowid DESC
                   LIMIT 1
                 ), -1)
             AND NOT EXISTS (
               SELECT 1
               FROM resource_effect_receipts AS effect
               WHERE effect.idempotency_key = candidate.idempotency_key
                 AND effect.state IN ('pending', 'executing', 'indeterminate')
             )
             AND NOT EXISTS (
               SELECT 1
               FROM resource_creation_receipts AS creation
               WHERE creation.idempotency_key = candidate.idempotency_key
                 AND creation.state IN ('prepared', 'executing', 'indeterminate')
             )
           ORDER BY candidate.committed_revision DESC, candidate.rowid DESC
           LIMIT -1 OFFSET ?1
         )",
        [i64::try_from(RESOURCE_MUTATION_REPLAY_CAPACITY)?],
    )?;
    Ok(())
}

pub(super) fn migrate_resource_browser_metadata(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let columns = {
        let mut statement = transaction.prepare("PRAGMA table_info(resource_browsers)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    if columns.contains("metadata_json") {
        return Ok(());
    }
    transaction.execute("ALTER TABLE resource_browsers ADD COLUMN metadata_json TEXT", [])?;
    let rows = {
        let mut statement = transaction.prepare("SELECT public_id, url FROM resource_browsers")?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (public_id, url) in rows {
        let browser =
            RegistryBrowser::recreate(BrowserPublicId::parse(public_id.clone())?, url, 80, 24);
        transaction.execute(
            "UPDATE resource_browsers SET metadata_json = ?1 WHERE public_id = ?2",
            params![canonical_json(&serde_json::to_value(browser)?)?, public_id],
        )?;
    }
    Ok(())
}

impl WorkspaceRegistry {
    pub(super) fn stage_agent_hook_pending(
        transaction: &Transaction<'_>,
        producer_id: &str,
        origin: &str,
        idempotency_key: &str,
        sequence: u64,
        ingress: &crate::JournalIngress,
    ) -> anyhow::Result<()> {
        let ingress_json = serde_json::to_string(ingress)?;
        let terminal_id = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .map(|subject| subject.id.as_str());
        transaction.execute(
            "INSERT INTO resource_agent_hook_pending(
               producer_id, origin, idempotency_key, terminal_id, event_sequence, ingress_json, error, attempt
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, '', 0)
             ON CONFLICT(producer_id, origin, idempotency_key) DO UPDATE SET
               terminal_id = excluded.terminal_id,
               event_sequence = excluded.event_sequence,
               ingress_json = excluded.ingress_json",
            params![producer_id, origin, idempotency_key, terminal_id, i64::try_from(sequence)?, ingress_json],
        )?;
        Ok(())
    }

    pub fn enqueue_agent_hook_pending(
        &mut self,
        producer_id: &str,
        origin: &str,
        idempotency_key: &str,
        sequence: u64,
        ingress: &crate::JournalIngress,
        error: &str,
    ) -> anyhow::Result<()> {
        const MAX_ERROR_CHARS: usize = 1_024;
        let ingress_json = serde_json::to_string(ingress)?;
        let terminal_id = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .map(|subject| subject.id.as_str());
        let bounded_error = error.chars().take(MAX_ERROR_CHARS).collect::<String>();
        self.connection.execute(
            "INSERT INTO resource_agent_hook_pending(
               producer_id, origin, idempotency_key, terminal_id, event_sequence, ingress_json, error, attempt
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, 1)
             ON CONFLICT(producer_id, origin, idempotency_key) DO UPDATE SET
               terminal_id = excluded.terminal_id,
               event_sequence = excluded.event_sequence,
               ingress_json = excluded.ingress_json,
               error = CASE
                 WHEN resource_agent_hook_pending.attempt + 1 >= ?8
                 THEN 'agent hook retry limit reached'
                 ELSE excluded.error
               END,
               attempt = CASE
                 WHEN resource_agent_hook_pending.attempt < ?8
                 THEN resource_agent_hook_pending.attempt + 1
                 ELSE resource_agent_hook_pending.attempt
               END",
            params![
                producer_id,
                origin,
                idempotency_key,
                terminal_id,
                i64::try_from(sequence)?,
                ingress_json,
                bounded_error,
                AGENT_HOOK_MAX_ATTEMPTS
            ],
        )?;
        Ok(())
    }

    pub fn clear_agent_hook_pending(
        &mut self,
        producer_id: &str,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        self.connection.execute(
            "DELETE FROM resource_agent_hook_pending
             WHERE producer_id = ?1 AND origin = ?2 AND idempotency_key = ?3",
            params![producer_id, origin, idempotency_key],
        )?;
        Ok(())
    }

    fn record_agent_hook_pending_failure(
        &self,
        producer_id: &str,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<()> {
        self.connection.execute(
            "UPDATE resource_agent_hook_pending
             SET error = CASE
                   WHEN attempt + 1 >= ?4 THEN 'agent hook retry limit reached'
                   ELSE 'invalid pending agent hook payload'
                 END,
                 attempt = CASE
                   WHEN attempt < ?4 THEN attempt + 1
                   ELSE attempt
                 END
             WHERE producer_id = ?1 AND origin = ?2 AND idempotency_key = ?3",
            params![producer_id, origin, idempotency_key, AGENT_HOOK_MAX_ATTEMPTS],
        )?;
        Ok(())
    }

    pub fn pending_agent_hook_projections(
        &self,
    ) -> anyhow::Result<Vec<(String, String, String, u64, crate::JournalIngress)>> {
        let mut statement = self.connection.prepare(
            "SELECT producer_id, origin, idempotency_key, event_sequence, ingress_json
             FROM resource_agent_hook_pending ORDER BY event_sequence ASC, idempotency_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })?
            .map(|row| {
                let (producer_id, origin, key, sequence, ingress_json) = row?;
                Ok((
                    producer_id,
                    origin,
                    key,
                    u64::try_from(sequence).context("pending hook sequence is negative")?,
                    serde_json::from_str(&ingress_json)?,
                ))
            })
            .collect()
    }

    pub fn pending_agent_hook_projections_for_terminal(
        &self,
        terminal_id: &crate::resource::TerminalPublicId,
    ) -> anyhow::Result<Vec<(String, String, String, u64, crate::JournalIngress)>> {
        let mut statement = self.connection.prepare(
            "SELECT producer_id, origin, idempotency_key, event_sequence, ingress_json
             FROM resource_agent_hook_pending
             WHERE terminal_id = ?1 AND attempt < ?2
             ORDER BY event_sequence ASC, idempotency_key ASC
             LIMIT ?3",
        )?;
        let rows = statement
            .query_map(
                params![terminal_id.as_str(), AGENT_HOOK_MAX_ATTEMPTS, AGENT_HOOK_RETRY_PAGE_SIZE],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, String>(4)?,
                    ))
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        let mut pending = Vec::with_capacity(rows.len());
        for (producer_id, origin, key, sequence, ingress_json) in rows {
            let ingress = match serde_json::from_str(&ingress_json) {
                Ok(ingress) => ingress,
                Err(_) => {
                    self.record_agent_hook_pending_failure(&producer_id, &origin, &key)?;
                    continue;
                }
            };
            pending.push((
                producer_id,
                origin,
                key,
                u64::try_from(sequence).context("pending hook sequence is negative")?,
                ingress,
            ));
        }
        Ok(pending)
    }

    pub fn pending_agent_hook_projections_page(
        &self,
        after: Option<(u64, String, i64)>,
    ) -> anyhow::Result<(
        Vec<(String, String, String, u64, crate::JournalIngress)>,
        Option<(u64, String, i64)>,
    )> {
        let (after_sequence, after_key, after_rowid) = after.unwrap_or((0, String::new(), 0));
        let mut statement = self.connection.prepare(
            "SELECT rowid, producer_id, origin, idempotency_key, event_sequence, ingress_json
             FROM resource_agent_hook_pending
             WHERE attempt < ?1
               AND (event_sequence > ?2
                    OR (event_sequence = ?2 AND idempotency_key > ?3)
                    OR (event_sequence = ?2 AND idempotency_key = ?3 AND rowid > ?4))
             ORDER BY event_sequence ASC, idempotency_key ASC, rowid ASC
             LIMIT ?5",
        )?;
        let rows = statement
            .query_map(
                params![
                    AGENT_HOOK_MAX_ATTEMPTS,
                    i64::try_from(after_sequence)?,
                    after_key,
                    after_rowid,
                    AGENT_HOOK_RETRY_PAGE_SIZE
                ],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, String>(5)?,
                    ))
                },
            )?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        let mut pending = Vec::with_capacity(rows.len());
        let mut next_cursor = None;
        for (rowid, producer_id, origin, key, sequence, ingress_json) in rows {
            let sequence = u64::try_from(sequence).context("pending hook sequence is negative")?;
            next_cursor = Some((sequence, key.clone(), rowid));
            let ingress = match serde_json::from_str(&ingress_json) {
                Ok(ingress) => ingress,
                Err(_) => {
                    self.record_agent_hook_pending_failure(&producer_id, &origin, &key)?;
                    continue;
                }
            };
            pending.push((producer_id, origin, key, sequence, ingress));
        }
        Ok((pending, next_cursor))
    }

    pub fn commit_agent_projection_with_hook_state(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        terminal_id: &TerminalPublicId,
        result: &Value,
        deltas: &Value,
        hook_state: Option<&AgentHookProjectionState>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_agent_projection_inner(
            mutation,
            fingerprint,
            expected_revision,
            terminal_id,
            result,
            deltas,
            hook_state,
        )
    }

    pub fn replay_resource_patch(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<ResourcePatchCommit>> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        resource_patch_replay(&self.connection, mutation, operation, &fingerprint)
    }

    pub fn commit_agent_projection(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        terminal_id: &TerminalPublicId,
        result: &Value,
        deltas: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_agent_projection_inner(
            mutation,
            fingerprint,
            expected_revision,
            terminal_id,
            result,
            deltas,
            None,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_agent_projection_inner(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        terminal_id: &TerminalPublicId,
        result: &Value,
        deltas: &Value,
        hook_state: Option<&AgentHookProjectionState>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        const OPERATION: &str = "agent.report";
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        anyhow::ensure!(
            result.get("terminal_id").and_then(Value::as_str) == Some(terminal_id.as_str()),
            "agent projection terminal does not match {terminal_id}"
        );
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let tx = self.connection.transaction()?;
        if let Some(replayed) = resource_patch_replay(&tx, mutation, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let terminal_is_live = tx
            .query_row(
                "SELECT 1 FROM resource_terminals
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [terminal_id.as_str()],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        anyhow::ensure!(terminal_is_live, "unknown terminal {terminal_id}");
        let previous_revision = transaction_resource_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != previous_revision
        {
            anyhow::bail!(
                "resource revision conflict: expected {expected}, current {previous_revision}"
            );
        }
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;
        tx.execute(
            "INSERT INTO resource_agent_projections(
               terminal_id, result_json, committed_revision
             ) VALUES(?1, ?2, ?3)
             ON CONFLICT(terminal_id) DO UPDATE SET
               result_json = excluded.result_json,
               committed_revision = excluded.committed_revision",
            params![terminal_id.as_str(), result_json, sqlite_revision],
        )?;
        if let Some(hook_state) = hook_state {
            let applied_sequence = i64::try_from(hook_state.applied_sequence)
                .context("agent hook sequence exceeds SQLite range")?;
            tx.execute(
                "INSERT INTO resource_agent_hook_state(
                   terminal_id, agent_session_id, applied_sequence, ended, committed_revision
                 ) VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(terminal_id) DO UPDATE SET
                   agent_session_id = excluded.agent_session_id,
                   applied_sequence = excluded.applied_sequence,
                   ended = excluded.ended,
                   committed_revision = excluded.committed_revision",
                params![
                    terminal_id.as_str(),
                    hook_state.agent_session_id,
                    applied_sequence,
                    hook_state.ended,
                    sqlite_revision,
                ],
            )?;
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.origin,
                mutation.id,
                OPERATION,
                fingerprint,
                result_json,
                sqlite_revision,
            ],
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            OPERATION,
            None,
            result,
            deltas,
        )?;
        prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok(ResourcePatchCommit { revision, result: result.clone(), replayed: false })
    }

    pub fn terminal_resource_id(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalPublicId>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        self.connection
            .query_row(
                "SELECT public_id FROM resource_terminals
                 WHERE terminal_id = ?1 AND deleted_revision IS NULL",
                [terminal_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .map(TerminalPublicId::parse)
            .transpose()
            .map_err(Into::into)
    }

    /// Return every live public terminal-to-host identity in one deterministic
    /// bulk read instead of resolving each terminal with a separate query.
    pub fn live_terminal_resource_ids(&self) -> anyhow::Result<Vec<(String, TerminalPublicId)>> {
        let mut statement = self.connection.prepare(
            "SELECT terminal_id, public_id
             FROM resource_terminals
             WHERE deleted_revision IS NULL
             ORDER BY created_revision ASC, public_id ASC",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .map(|row| {
                let (terminal_id, public_id) = row?;
                Ok((terminal_id, TerminalPublicId::parse(public_id)?))
            })
            .collect()
    }

    /// Resolve the immutable resource-to-host relationship, including after
    /// explicit close, so lifecycle reads can distinguish tombstones from
    /// identifiers that never existed.
    pub fn terminal_host_id(&self, public_id: &TerminalPublicId) -> anyhow::Result<Option<String>> {
        self.connection
            .query_row(
                "SELECT terminal_id FROM resource_terminals
                 WHERE public_id = ?1",
                [public_id.as_str()],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    /// Resolve only a live resource-to-host relationship for mutations that
    /// must never act on a tombstoned terminal.
    pub fn live_terminal_host_id(
        &self,
        public_id: &TerminalPublicId,
    ) -> anyhow::Result<Option<String>> {
        self.connection
            .query_row(
                "SELECT terminal_id FROM resource_terminals
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [public_id.as_str()],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn resource_topology_snapshot(&self) -> anyhow::Result<ResourceTopologySnapshot> {
        let revision = current_resource_revision(&self.connection)?;
        let active_workspace = meta_value(&self.connection, "active_workspace_id")?
            .map(WorkspacePublicId::parse)
            .transpose()?;
        let active_screens = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, active_screen_id
                 FROM resource_workspaces
                 WHERE deleted_revision IS NULL
                 ORDER BY created_revision ASC, public_id ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
                })?
                .map(|row| {
                    let (workspace, screen) = row?;
                    Ok((
                        WorkspacePublicId::parse(workspace)?,
                        screen.map(ScreenPublicId::parse).transpose()?,
                    ))
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let screens = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, workspace_id, position, name, layout_json,
                        active_pane_id, zoomed_pane_id, auto_layout_json, viewport_json
                 FROM resource_screens
                 WHERE deleted_revision IS NULL
                 ORDER BY workspace_id ASC, position ASC",
            )?;
            statement
                .query_map([], |row| {
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
                        auto_layout: auto_layout
                            .map(|value| serde_json::from_str(&value))
                            .transpose()?,
                        viewport: serde_json::from_str(&viewport)?,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let panes = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, screen_id, name, active_tab_id, creation_ordinal
                 FROM resource_panes
                 WHERE deleted_revision IS NULL
                 ORDER BY screen_id ASC, creation_ordinal ASC, public_id ASC",
            )?;
            statement
                .query_map([], |row| {
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
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let tabs = {
            let mut statement = self.connection.prepare(
                "SELECT t.public_id, t.pane_id, t.position, t.content_kind,
                        t.content_id, t.name, b.url, rt.terminal_id
                 FROM resource_tabs t
                 LEFT JOIN resource_browsers b ON b.public_id = t.content_id
                 LEFT JOIN resource_terminals rt ON rt.public_id = t.content_id
                 WHERE t.deleted_revision IS NULL
                 ORDER BY t.pane_id ASC, t.position ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, Option<String>>(7)?,
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
                    ) = row?;
                    let content_id = match kind.as_str() {
                        "terminal" => {
                            ContentPublicId::Terminal(TerminalPublicId::parse(content_id)?)
                        }
                        "browser" => ContentPublicId::Browser(BrowserPublicId::parse(content_id)?),
                        _ => anyhow::bail!("stored tab has invalid content kind {kind:?}"),
                    };
                    Ok(RegistryTab {
                        public_id: TabPublicId::parse(public_id)?,
                        pane_id: PanePublicId::parse(pane_id)?,
                        position: usize::try_from(position)
                            .context("stored tab position is negative")?,
                        content_id,
                        name,
                        browser_url,
                        terminal_id,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let browsers = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, url, metadata_json
                 FROM resource_browsers
                 WHERE deleted_revision IS NULL
                 ORDER BY public_id ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })?
                .map(|row| {
                    let (public_id, url, metadata) = row?;
                    let browser: RegistryBrowser = serde_json::from_str(&metadata)
                        .with_context(|| format!("invalid metadata for browser {public_id}"))?;
                    validate_registry_browser(&browser)?;
                    if browser.public_id.as_str() != public_id || browser.url != url {
                        anyhow::bail!(
                            "browser {public_id} metadata does not match its indexed fields"
                        );
                    }
                    Ok(browser)
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        Ok(ResourceTopologySnapshot {
            session_id: self.session_id.clone(),
            generation: self.generation.clone(),
            revision,
            active_workspace,
            active_screens,
            screens,
            panes,
            tabs,
            browsers,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn commit_resource_patch(
        &mut self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_patch_with_workspace_ledger(
            mutation,
            operation,
            fingerprint,
            expected_generation,
            expected_revision,
            patch,
            result,
            deltas,
            None,
        )
        .map(|(commit, _)| commit)
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_resource_patch_with_workspace_ledger(
        &mut self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
        workspace_ledger: Option<&ResourceWorkspaceLedger>,
    ) -> anyhow::Result<(ResourcePatchCommit, Option<u64>)> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        validate_resource_patch(patch)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let tx = self.connection.transaction()?;
        if let Some(replayed) = resource_patch_replay(&tx, mutation, operation, &fingerprint)? {
            return Ok((replayed, None));
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "resource generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let previous_revision = transaction_resource_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != previous_revision
        {
            anyhow::bail!(
                "resource revision conflict: expected {expected}, current {previous_revision}"
            );
        }
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;

        // The legacy ledger commit runs first, mirroring the resource close
        // path: its full-registry rewrite is then corrected in place by the
        // patch's own upserts inside this same transaction.
        let workspace_revision = workspace_ledger
            .map(|ledger| {
                super::commit_workspace_registry_in_transaction(
                    &tx,
                    mutation,
                    &fingerprint,
                    None,
                    ledger.event_kind,
                    &ledger.workspace_key,
                    &ledger.workspaces,
                    &canonical_json(&ledger.legacy_result)?,
                )
                .map(|(revision, _)| revision)
            })
            .transpose()?;

        apply_resource_patch(&tx, patch, sqlite_revision)?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.origin,
                mutation.id,
                operation,
                fingerprint,
                result_json,
                sqlite_revision,
            ],
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            operation,
            Some(patch),
            result,
            deltas,
        )?;
        prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok((
            ResourcePatchCommit { revision, result: result.clone(), replayed: false },
            workspace_revision,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn commit_resource_projection(
        &mut self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_projection_revision: Option<u64>,
        frontend: &str,
        scope: &str,
        subject_key: &str,
        schema_version: u32,
        projection: &Value,
        result: &Value,
        deltas: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        validate_identifier("frontend", frontend)?;
        validate_identifier("projection scope", scope)?;
        validate_identifier("projection subject", subject_key)?;
        let fingerprint = canonical_json(fingerprint)?;
        let projection_json = canonical_json(projection)?;
        if projection_json.len() > MAX_PROJECTION_BYTES {
            anyhow::bail!("frontend projection exceeds {MAX_PROJECTION_BYTES} bytes");
        }
        let result_json = canonical_json(result)?;
        let tx = self.connection.transaction()?;
        if let Some(replay) = resource_patch_replay(&tx, mutation, operation, &fingerprint)? {
            return Ok(replay);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "resource generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let previous_revision = transaction_resource_revision(&tx)?;
        let current_projection_revision = tx
            .query_row(
                "SELECT projection_revision FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![frontend, scope, subject_key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(u64::try_from)
            .transpose()
            .context("projection revision is negative")?
            .unwrap_or(0);
        if let Some(expected) = expected_projection_revision
            && expected != current_projection_revision
        {
            anyhow::bail!(
                "projection revision conflict: expected {expected}, current {current_projection_revision}"
            );
        }
        let projection_revision = current_projection_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("projection revision exhausted"))?;
        tx.execute(
            "INSERT INTO frontend_projections(
               frontend, scope, subject_key, schema_version, projection_revision, payload
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(frontend, scope, subject_key) DO UPDATE SET
               schema_version=excluded.schema_version,
               projection_revision=excluded.projection_revision,
               payload=excluded.payload",
            params![
                frontend,
                scope,
                subject_key,
                i64::from(schema_version),
                i64::try_from(projection_revision)
                    .context("projection revision exceeds SQLite range")?,
                projection_json,
            ],
        )?;
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.origin,
                mutation.id,
                operation,
                fingerprint,
                result_json,
                sqlite_revision,
            ],
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            operation,
            None,
            result,
            deltas,
        )?;
        prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok(ResourcePatchCommit { revision, result: result.clone(), replayed: false })
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failure(&self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.connection.execute_batch(
                "CREATE TEMP TRIGGER cmux_test_fail_resource_patch
                 BEFORE INSERT ON session_journal
                 BEGIN SELECT RAISE(ABORT, 'forced resource patch failure'); END;",
            )?;
        } else {
            self.connection
                .execute_batch("DROP TRIGGER IF EXISTS cmux_test_fail_resource_patch")?;
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn resource_mutation_count_for_test(&self) -> anyhow::Result<u64> {
        let count =
            self.connection.query_row("SELECT COUNT(*) FROM resource_mutations", [], |row| {
                row.get::<_, i64>(0)
            })?;
        u64::try_from(count).context("resource mutation count is negative")
    }

    #[cfg(test)]
    pub(crate) fn resource_agent_projection_count_for_test(&self) -> anyhow::Result<u64> {
        let count = self.connection.query_row(
            "SELECT COUNT(*) FROM resource_agent_projections",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        u64::try_from(count).context("resource agent projection count is negative")
    }

    #[cfg(test)]
    pub(crate) fn delete_agent_hook_state_for_test(
        &mut self,
        terminal_id: &crate::resource::TerminalPublicId,
    ) -> anyhow::Result<()> {
        self.connection.execute(
            "DELETE FROM resource_agent_hook_state WHERE terminal_id = ?1",
            [terminal_id.as_str()],
        )?;
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn agent_hook_pending_retry_state_for_test(
        &self,
        producer_id: &str,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<Option<(i64, String)>> {
        self.connection
            .query_row(
                "SELECT attempt, error
                 FROM resource_agent_hook_pending
                 WHERE producer_id = ?1 AND origin = ?2 AND idempotency_key = ?3",
                params![producer_id, origin, idempotency_key],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(Into::into)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryScreen {
    pub public_id: ScreenPublicId,
    pub workspace_id: WorkspacePublicId,
    pub position: usize,
    pub name: Option<String>,
    pub layout: RegistryLayoutNode,
    pub active_pane: PanePublicId,
    pub zoomed_pane: Option<PanePublicId>,
    pub auto_layout: Option<Vec<PanePublicId>>,
    pub viewport: RegistryViewport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegistryBrowserSource {
    Unknown,
    External,
    Launched,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegistryBrowserLaunch {
    Create,
    Adopted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegistryBrowserReconnect {
    Recreate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegistryBrowserStatus {
    Starting,
    Live,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryBrowser {
    pub public_id: BrowserPublicId,
    pub url: String,
    pub source: RegistryBrowserSource,
    pub launch: RegistryBrowserLaunch,
    pub reconnect: RegistryBrowserReconnect,
    pub status: RegistryBrowserStatus,
    pub cols: u16,
    pub rows: u16,
}

impl RegistryBrowser {
    pub fn recreate(public_id: BrowserPublicId, url: String, cols: u16, rows: u16) -> Self {
        Self {
            public_id,
            url,
            source: RegistryBrowserSource::Unknown,
            launch: RegistryBrowserLaunch::Create,
            reconnect: RegistryBrowserReconnect::Recreate,
            status: RegistryBrowserStatus::Starting,
            cols,
            rows,
        }
    }
}

fn validate_registry_browser(browser: &RegistryBrowser) -> anyhow::Result<()> {
    if browser.url.is_empty() {
        anyhow::bail!("browser URL cannot be empty");
    }
    if !(1..=10_000).contains(&browser.cols) || !(1..=10_000).contains(&browser.rows) {
        anyhow::bail!(
            "browser {} has invalid size {}x{}",
            browser.public_id,
            browser.cols,
            browser.rows
        );
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RegistryViewport {
    pub base_width: Option<f32>,
    pub columns: Vec<RegistryViewportColumn>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryViewportColumn {
    pub id: SplitPublicId,
    pub width: f32,
    pub layout: RegistryLayoutNode,
    pub auto_layout: Option<Vec<PanePublicId>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum RegistryLayoutNode {
    Leaf {
        pane: PanePublicId,
    },
    Split {
        split: SplitPublicId,
        direction: String,
        ratio: f32,
        first: Box<RegistryLayoutNode>,
        second: Box<RegistryLayoutNode>,
    },
    Stack {
        panes: Vec<PanePublicId>,
        expanded: PanePublicId,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryPane {
    pub public_id: PanePublicId,
    pub screen_id: ScreenPublicId,
    pub name: Option<String>,
    pub active_tab: Option<TabPublicId>,
    pub creation_ordinal: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryTab {
    pub public_id: TabPublicId,
    pub pane_id: PanePublicId,
    pub position: usize,
    pub content_id: ContentPublicId,
    pub name: Option<String>,
    pub browser_url: Option<String>,
    pub terminal_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourceTopologySnapshot {
    pub session_id: SessionPublicId,
    pub generation: String,
    pub revision: u64,
    pub active_workspace: Option<WorkspacePublicId>,
    pub active_screens: Vec<(WorkspacePublicId, Option<ScreenPublicId>)>,
    pub screens: Vec<RegistryScreen>,
    pub panes: Vec<RegistryPane>,
    pub tabs: Vec<RegistryTab>,
    pub browsers: Vec<RegistryBrowser>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourcePatch {
    pub changes: Vec<ResourceChange>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResourceChange {
    UpsertWorkspace {
        workspace: RegistryWorkspace,
        position: usize,
        active_screen: Option<ScreenPublicId>,
    },
    TombstoneWorkspace {
        workspace_id: WorkspacePublicId,
    },
    SetWorkspaceOrder {
        workspace_ids: Vec<WorkspacePublicId>,
    },
    SetActiveWorkspace {
        workspace_id: Option<WorkspacePublicId>,
    },
    UpsertScreen(RegistryScreen),
    TombstoneScreen {
        screen_id: ScreenPublicId,
    },
    SetScreenOrder {
        workspace_id: WorkspacePublicId,
        screen_ids: Vec<ScreenPublicId>,
    },
    UpsertPane(RegistryPane),
    TombstonePane {
        pane_id: PanePublicId,
    },
    UpsertTab(RegistryTab),
    TombstoneTab {
        tab_id: TabPublicId,
        close_content: bool,
    },
    SetTabOrder {
        pane_id: PanePublicId,
        tab_ids: Vec<TabPublicId>,
    },
    UpsertTerminal {
        public_id: TerminalPublicId,
        terminal: RegistryTerminal,
    },
    TombstoneTerminal {
        public_id: TerminalPublicId,
        expected_incarnation: Option<String>,
    },
    UpsertBrowser(RegistryBrowser),
    TombstoneBrowser {
        public_id: BrowserPublicId,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourcePatchCommit {
    pub revision: u64,
    pub result: Value,
    pub replayed: bool,
}

/// Legacy workspace-ledger commit to run inside the same transaction as a
/// resource patch that changes the workspace projection. The legacy CAS
/// (`create-workspace`/`rename-workspace`/`move-workspace`/`close-workspace`)
/// compares client snapshot revisions against this ledger, so any resource
/// commit that changes the reported workspace registry without advancing the
/// ledger permanently wedges every later legacy mutation (issue: packaged
/// browsers fail alt+n forever after a receipted `workspace.create`).
#[derive(Debug, Clone)]
pub struct ResourceWorkspaceLedger {
    pub event_kind: &'static str,
    pub workspace_key: String,
    pub workspaces: Vec<RegistryWorkspace>,
    pub legacy_result: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourceEventBatch {
    pub previous_revision: u64,
    pub revision: u64,
    pub changes: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourceEventPage {
    pub generation: String,
    pub head_revision: u64,
    pub oldest_revision: Option<u64>,
    pub batches: Vec<ResourceEventBatch>,
}

impl WorkspaceRegistry {
    pub fn resource_events_after(&self, revision: u64) -> anyhow::Result<ResourceEventPage> {
        let head_revision = current_resource_revision(&self.connection)?;
        if revision > head_revision {
            anyhow::bail!(
                "cursor.invalid: revision {revision} is ahead of current revision {head_revision}"
            );
        }
        let oldest_revision = self
            .connection
            .query_row(
                "SELECT MIN(resource_revision) FROM journal_event_index
                 WHERE resource_revision IS NOT NULL",
                [],
                |row| row.get::<_, Option<i64>>(0),
            )?
            .map(|revision| {
                u64::try_from(revision).context("stored resource event revision is negative")
            })
            .transpose()?;
        if oldest_revision.is_some_and(|oldest| revision < oldest.saturating_sub(1))
            || (oldest_revision.is_none() && revision < head_revision)
        {
            anyhow::bail!(
                "cursor.gap: revision {revision} is older than retained history at {oldest_revision:?}"
            );
        }
        let indexed = {
            let mut statement = self.connection.prepare(
                "SELECT resource_revision, sequence FROM journal_event_index
                 WHERE resource_revision > ?1
                 ORDER BY resource_revision ASC
                 LIMIT ?2",
            )?;
            statement
                .query_map(
                    params![
                        i64::try_from(revision)
                            .context("resource revision exceeds SQLite range")?,
                        i64::try_from(RESOURCE_EVENT_PAGE_SIZE)?,
                    ],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
                )?
                .map(|row| {
                    let (resource_revision, sequence) = row?;
                    Ok((
                        u64::try_from(resource_revision)
                            .context("resource event revision is negative")?,
                        u64::try_from(sequence).context("resource event sequence is negative")?,
                    ))
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let sequences = indexed.iter().map(|(_, sequence)| *sequence).collect::<Vec<_>>();
        let mut records =
            session_journal::query_session_journal_sequences(&self.connection, &sequences)?
                .into_iter()
                .map(|record| (record.sequence, record))
                .collect::<HashMap<_, _>>();
        let mut expected_revision = revision.saturating_add(1);
        let mut batches = Vec::with_capacity(indexed.len());
        for (indexed_revision, sequence) in indexed {
            anyhow::ensure!(
                indexed_revision == expected_revision,
                "resource event history contains a gap before revision {indexed_revision}"
            );
            let record = records
                .remove(&sequence)
                .context("indexed resource event is absent from the journal")?;
            anyhow::ensure!(
                record.resource_revision == Some(indexed_revision)
                    && record.previous_resource_revision == Some(indexed_revision - 1),
                "indexed resource event revision does not match its journal record"
            );
            batches.push(ResourceEventBatch {
                previous_revision: indexed_revision - 1,
                revision: indexed_revision,
                changes: record
                    .payload
                    .get("changes")
                    .cloned()
                    .context("resource journal record omitted changes")?,
            });
            expected_revision = expected_revision.saturating_add(1);
        }
        Ok(ResourceEventPage {
            generation: self.generation.clone(),
            head_revision,
            oldest_revision,
            batches,
        })
    }
}

pub(super) fn collect_split_public_ids(layout: &RegistryLayoutNode, output: &mut Vec<String>) {
    match layout {
        RegistryLayoutNode::Leaf { .. } | RegistryLayoutNode::Stack { .. } => {}
        RegistryLayoutNode::Split { split, first, second, .. } => {
            output.push(split.to_string());
            collect_split_public_ids(first, output);
            collect_split_public_ids(second, output);
        }
    }
}

pub(super) fn collect_screen_split_public_ids(
    layout: &RegistryLayoutNode,
    viewport: &RegistryViewport,
    output: &mut Vec<String>,
) {
    collect_split_public_ids(layout, output);
    for column in &viewport.columns {
        if !output.iter().any(|id| id == column.id.as_str()) {
            output.push(column.id.to_string());
        }
    }
}

pub(super) fn resource_patch_replay(
    transaction: &Connection,
    mutation: &WorkspaceMutation,
    operation: &str,
    fingerprint: &str,
) -> anyhow::Result<Option<ResourcePatchCommit>> {
    let stored = transaction
        .query_row(
            "SELECT operation, fingerprint, result_json, committed_revision
             FROM resource_mutations
             WHERE idempotency_key = ?1",
            [&mutation.id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((stored_operation, stored_fingerprint, result, revision)) = stored else {
        return Ok(None);
    };
    if stored_operation != operation || stored_fingerprint != fingerprint {
        anyhow::bail!(
            "idempotency.conflict: key {} committed_operation {} from {} was reused with different input",
            mutation.id,
            stored_operation,
            mutation.origin
        );
    }
    Ok(Some(ResourcePatchCommit {
        revision: u64::try_from(revision).context("stored resource revision is negative")?,
        result: serde_json::from_str(&result)?,
        replayed: true,
    }))
}

pub(super) fn validate_resource_patch(patch: &ResourcePatch) -> anyhow::Result<()> {
    let mut targets = HashSet::new();
    let mut singleton_changes = HashSet::new();
    for change in &patch.changes {
        let target = match change {
            ResourceChange::UpsertWorkspace { workspace, .. } => {
                validate_registry(std::slice::from_ref(workspace))?;
                format!("workspace:{}", workspace.public_id)
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                format!("workspace:{workspace_id}")
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                validate_order_ids("workspace", workspace_ids.iter().map(|id| id.as_str()))?;
                "singleton:workspace-order".to_string()
            }
            ResourceChange::SetActiveWorkspace { .. } => "singleton:active-workspace".to_string(),
            ResourceChange::UpsertScreen(screen) => {
                let mut panes = HashSet::new();
                let mut splits = HashSet::new();
                validate_layout_node(&screen.layout, &mut panes, &mut splits)?;
                if !panes.contains(&screen.active_pane)
                    || screen.zoomed_pane.as_ref().is_some_and(|pane| !panes.contains(pane))
                {
                    anyhow::bail!("screen {} has invalid selection", screen.public_id);
                }
                validate_registry_viewport(&screen.viewport, &screen.layout, &panes, &splits)?;
                format!("screen:{}", screen.public_id)
            }
            ResourceChange::TombstoneScreen { screen_id } => format!("screen:{screen_id}"),
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                validate_order_ids("screen", screen_ids.iter().map(|id| id.as_str()))?;
                format!("screen-order:{workspace_id}")
            }
            ResourceChange::UpsertPane(pane) => format!("pane:{}", pane.public_id),
            ResourceChange::TombstonePane { pane_id } => format!("pane:{pane_id}"),
            ResourceChange::UpsertTab(tab) => {
                match (&tab.content_id, &tab.browser_url, &tab.terminal_id) {
                    (ContentPublicId::Terminal(_), None, Some(terminal_id)) => {
                        validate_terminal_identity("terminal id", terminal_id)?;
                    }
                    (ContentPublicId::Browser(_), Some(_), None) => {}
                    (ContentPublicId::Terminal(_), Some(_), _) => {
                        anyhow::bail!("terminal tab {} cannot carry a browser URL", tab.public_id)
                    }
                    (ContentPublicId::Terminal(_), None, None) => {
                        anyhow::bail!("terminal tab {} is missing its host id", tab.public_id)
                    }
                    (ContentPublicId::Browser(_), None, _) => {
                        anyhow::bail!("browser tab {} is missing its URL", tab.public_id)
                    }
                    (ContentPublicId::Browser(_), Some(_), Some(_)) => {
                        anyhow::bail!(
                            "browser tab {} cannot carry a terminal host id",
                            tab.public_id
                        )
                    }
                }
                format!("tab:{}", tab.public_id)
            }
            ResourceChange::TombstoneTab { tab_id, .. } => format!("tab:{tab_id}"),
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                validate_order_ids("tab", tab_ids.iter().map(|id| id.as_str()))?;
                format!("tab-order:{pane_id}")
            }
            ResourceChange::UpsertTerminal { public_id, terminal } => {
                validate_terminal(terminal)?;
                format!("terminal:{public_id}")
            }
            ResourceChange::TombstoneTerminal { public_id, expected_incarnation } => {
                if let Some(incarnation) = expected_incarnation {
                    validate_terminal_identity("terminal incarnation", incarnation)?;
                }
                format!("terminal:{public_id}")
            }
            ResourceChange::UpsertBrowser(browser) => {
                validate_registry_browser(browser)?;
                format!("browser:{}", browser.public_id)
            }
            ResourceChange::TombstoneBrowser { public_id } => format!("browser:{public_id}"),
        };
        if target.starts_with("singleton:") {
            if !singleton_changes.insert(target.clone()) {
                anyhow::bail!("duplicate resource patch change: {target}");
            }
        } else if !targets.insert(target.clone()) {
            anyhow::bail!("resource patch changes {target} more than once");
        }
    }
    Ok(())
}

fn validate_order_ids<'a>(
    kind: &str,
    ids: impl IntoIterator<Item = &'a str>,
) -> anyhow::Result<()> {
    let mut seen = HashSet::new();
    if ids.into_iter().any(|id| !seen.insert(id)) {
        anyhow::bail!("{kind} order contains a duplicate id");
    }
    Ok(())
}

fn validate_layout_node<'a>(
    layout: &'a RegistryLayoutNode,
    panes: &mut HashSet<&'a PanePublicId>,
    splits: &mut HashSet<&'a SplitPublicId>,
) -> anyhow::Result<()> {
    match layout {
        RegistryLayoutNode::Leaf { pane } => {
            if !panes.insert(pane) {
                anyhow::bail!("pane {pane} appears twice in one layout");
            }
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            if !splits.insert(split) {
                anyhow::bail!("duplicate split public id: {split}");
            }
            if !matches!(direction.as_str(), "right" | "down") {
                anyhow::bail!("invalid split direction {direction:?}");
            }
            if !ratio.is_finite() || !(0.0..1.0).contains(ratio) {
                anyhow::bail!("split {split} has invalid ratio {ratio}");
            }
            validate_layout_node(first, panes, splits)?;
            validate_layout_node(second, panes, splits)?;
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            if members.is_empty() || !members.contains(expanded) {
                anyhow::bail!("stack layout has invalid expanded pane");
            }
            for pane in members {
                if !panes.insert(pane) {
                    anyhow::bail!("pane {pane} appears twice in one layout");
                }
            }
        }
    }
    Ok(())
}

fn validate_registry_viewport(
    viewport: &RegistryViewport,
    screen_layout: &RegistryLayoutNode,
    screen_panes: &HashSet<&PanePublicId>,
    screen_splits: &HashSet<&SplitPublicId>,
) -> anyhow::Result<()> {
    let valid_width = |width: f32| {
        width.is_finite()
            && (crate::MIN_VIEWPORT_PANE_WIDTH..=crate::MAX_VIEWPORT_PANE_WIDTH).contains(&width)
    };
    if viewport.columns.is_empty() {
        if viewport.base_width.is_some() {
            anyhow::bail!("viewport metadata has no columns");
        }
        return Ok(());
    }
    if viewport.columns.len() < 2 {
        anyhow::bail!("viewport must have at least two columns when active");
    }
    let base_width =
        viewport.base_width.ok_or_else(|| anyhow::anyhow!("viewport is missing base width"))?;
    if !valid_width(base_width) || viewport.columns[0].width != base_width {
        anyhow::bail!("viewport has invalid base width {base_width}");
    }
    let mut column_ids = HashSet::new();
    let mut internal_splits = HashSet::new();
    let mut column_panes = HashSet::new();
    for (index, column) in viewport.columns.iter().enumerate() {
        if !valid_width(column.width) {
            anyhow::bail!("viewport column has invalid width {}", column.width);
        }
        if !column_ids.insert(&column.id) {
            anyhow::bail!("viewport has duplicate column id {}", column.id);
        }
        if index != 0 && !screen_splits.contains(&column.id) {
            anyhow::bail!("viewport column has unknown projected split {}", column.id);
        }
        let mut panes = HashSet::new();
        let mut splits = HashSet::new();
        validate_layout_node(&column.layout, &mut panes, &mut splits)?;
        if panes.iter().any(|pane| !screen_panes.contains(*pane))
            || splits.iter().any(|split| !screen_splits.contains(*split))
        {
            anyhow::bail!("viewport column references content outside its screen");
        }
        for split in splits {
            if !internal_splits.insert(split) {
                anyhow::bail!("split {split} appears in more than one viewport column");
            }
        }
        if let Some(auto_layout) = &column.auto_layout
            && (auto_layout.len() != panes.len()
                || auto_layout.iter().any(|pane| !panes.contains(pane)))
        {
            anyhow::bail!("viewport column has invalid auto-layout membership");
        }
        for pane in panes {
            if !column_panes.insert(pane) {
                anyhow::bail!("pane {pane} appears in more than one viewport column");
            }
        }
    }
    if &column_panes != screen_panes {
        anyhow::bail!("viewport columns do not cover the screen panes");
    }
    let owners = viewport.columns.iter().skip(1).map(|column| &column.id).collect::<HashSet<_>>();
    if owners.iter().any(|owner| internal_splits.contains(*owner)) {
        anyhow::bail!("viewport boundary owner also appears inside a column");
    }
    let covered_splits =
        owners.iter().copied().chain(internal_splits.iter().copied()).collect::<HashSet<_>>();
    if &covered_splits != screen_splits {
        anyhow::bail!("viewport columns do not cover the screen splits");
    }
    let mut projected = viewport.columns[0].layout.clone();
    let mut width_before = viewport.columns[0].width;
    for column in viewport.columns.iter().skip(1) {
        projected = RegistryLayoutNode::Split {
            split: column.id.clone(),
            direction: "right".into(),
            ratio: width_before / (width_before + column.width),
            first: Box::new(projected),
            second: Box::new(column.layout.clone()),
        };
        width_before += column.width;
    }
    if &projected != screen_layout {
        anyhow::bail!("viewport compatibility layout does not match its ordered columns");
    }
    Ok(())
}

pub(crate) fn validate_registry_screen_projection(
    screen: &RegistryScreen,
    expected_panes: &HashSet<PanePublicId>,
) -> anyhow::Result<()> {
    let mut layout_panes = HashSet::new();
    let mut layout_splits = HashSet::new();
    validate_layout_node(&screen.layout, &mut layout_panes, &mut layout_splits)?;
    let layout_panes = layout_panes.into_iter().cloned().collect::<HashSet<PanePublicId>>();
    if &layout_panes != expected_panes {
        anyhow::bail!("screen {} layout does not cover its panes exactly once", screen.public_id);
    }
    let layout_pane_refs = layout_panes.iter().collect::<HashSet<_>>();
    validate_registry_viewport(&screen.viewport, &screen.layout, &layout_pane_refs, &layout_splits)
}

pub(super) fn apply_resource_patch(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
    revision: i64,
) -> anyhow::Result<()> {
    validate_resource_order_coverage(transaction, patch)?;
    prepare_resource_order_slots(transaction, patch)?;

    // Explicit leaf closes run first so their positions can be reused by
    // additions in this patch. Parent closes run after upserts so a tab or
    // pane can move out of the closing parent without losing its identity.
    for change in &patch.changes {
        match change {
            ResourceChange::TombstoneTab { tab_id, close_content } => {
                tombstone_resource_tab(transaction, tab_id.as_str(), revision, *close_content)?;
            }
            ResourceChange::TombstoneTerminal { public_id, expected_incarnation } => {
                tombstone_resource_terminal(
                    transaction,
                    public_id.as_str(),
                    expected_incarnation.as_deref(),
                    revision,
                )?;
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                tombstone_resource_browser(transaction, public_id.as_str(), revision)?;
            }
            _ => {}
        }
    }

    for change in &patch.changes {
        if let ResourceChange::UpsertWorkspace { workspace, position, active_screen } = change {
            upsert_resource_workspace(
                transaction,
                workspace,
                *position,
                active_screen.as_ref(),
                revision,
            )?;
        }
    }
    for change in &patch.changes {
        if let ResourceChange::UpsertScreen(screen) = change {
            upsert_resource_screen(transaction, screen, revision)?;
        }
    }
    for change in &patch.changes {
        if let ResourceChange::UpsertPane(pane) = change {
            upsert_resource_pane(transaction, pane, revision)?;
        }
    }
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertTerminal { public_id, terminal } => {
                upsert_resource_terminal(transaction, public_id, terminal, revision)?;
            }
            ResourceChange::UpsertBrowser(browser) => {
                upsert_resource_browser(transaction, browser, revision)?;
            }
            _ => {}
        }
    }
    for change in &patch.changes {
        if let ResourceChange::UpsertTab(tab) = change {
            upsert_resource_tab(transaction, tab, revision)?;
        }
    }

    for change in &patch.changes {
        match change {
            ResourceChange::TombstonePane { pane_id } => {
                tombstone_resource_pane(transaction, pane_id.as_str(), revision)?;
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                tombstone_resource_screen(transaction, screen_id.as_str(), revision)?;
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                tombstone_resource_workspace(transaction, workspace_id.as_str(), revision)?;
            }
            _ => {}
        }
    }

    for change in &patch.changes {
        match change {
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                set_resource_workspace_order(transaction, workspace_ids, revision)?;
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                set_resource_screen_order(transaction, workspace_id, screen_ids, revision)?;
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                set_resource_tab_order(transaction, pane_id, tab_ids, revision)?;
            }
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                set_active_resource_workspace(transaction, workspace_id.as_ref())?;
            }
            _ => {}
        }
    }

    validate_touched_resource_invariants(transaction, patch)
}

fn validate_resource_order_coverage(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let workspace_order = patch
        .changes
        .iter()
        .any(|change| matches!(change, ResourceChange::SetWorkspaceOrder { .. }));
    let screen_orders = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::SetScreenOrder { workspace_id, .. } => Some(workspace_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let tab_orders = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::SetTabOrder { pane_id, .. } => Some(pane_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let closing_workspaces = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneWorkspace { workspace_id } => Some(workspace_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let closing_screens = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneScreen { screen_id } => Some(screen_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let closing_panes = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstonePane { pane_id } => Some(pane_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();

    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, position, .. } => {
                let stored_position = transaction
                    .query_row(
                        "SELECT position FROM workspaces
                         WHERE workspace_key = ?1 AND tombstoned = 0",
                        [&workspace.key],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?;
                let desired =
                    i64::try_from(*position).context("workspace position exceeds SQLite range")?;
                if stored_position != Some(desired) && !workspace_order {
                    anyhow::bail!(
                        "creating or moving workspace {} requires SetWorkspaceOrder",
                        workspace.public_id
                    );
                }
            }
            ResourceChange::TombstoneWorkspace { .. } if !workspace_order => {
                anyhow::bail!("closing a workspace requires SetWorkspaceOrder");
            }
            ResourceChange::UpsertScreen(screen) => {
                let stored = transaction
                    .query_row(
                        "SELECT workspace_id, position FROM resource_screens
                         WHERE public_id = ?1 AND deleted_revision IS NULL",
                        [screen.public_id.as_str()],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
                    )
                    .optional()?;
                let desired_position = i64::try_from(screen.position)
                    .context("screen position exceeds SQLite range")?;
                if stored.as_ref().is_none_or(|(workspace, position)| {
                    workspace != screen.workspace_id.as_str() || *position != desired_position
                }) {
                    if !screen_orders.contains(screen.workspace_id.as_str()) {
                        anyhow::bail!(
                            "creating or moving screen {} requires SetScreenOrder for {}",
                            screen.public_id,
                            screen.workspace_id
                        );
                    }
                    if let Some((old_workspace, _)) = stored
                        && old_workspace != screen.workspace_id.as_str()
                        && !closing_workspaces.contains(old_workspace.as_str())
                        && !screen_orders.contains(old_workspace.as_str())
                    {
                        anyhow::bail!(
                            "moving screen {} requires SetScreenOrder for old workspace {}",
                            screen.public_id,
                            old_workspace
                        );
                    }
                }
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                if let Some(workspace_id) = resource_field_any(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    screen_id.as_str(),
                )? && !closing_workspaces.contains(workspace_id.as_str())
                    && !screen_orders.contains(workspace_id.as_str())
                {
                    anyhow::bail!(
                        "closing screen {screen_id} requires SetScreenOrder for {workspace_id}"
                    );
                }
            }
            ResourceChange::UpsertTab(tab) => {
                let stored = transaction
                    .query_row(
                        "SELECT pane_id, position FROM resource_tabs
                         WHERE public_id = ?1 AND deleted_revision IS NULL",
                        [tab.public_id.as_str()],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
                    )
                    .optional()?;
                let desired_position =
                    i64::try_from(tab.position).context("tab position exceeds SQLite range")?;
                if stored.as_ref().is_none_or(|(pane, position)| {
                    pane != tab.pane_id.as_str() || *position != desired_position
                }) {
                    if !pane_closes_in_patch(
                        transaction,
                        tab.pane_id.as_str(),
                        &closing_panes,
                        &closing_screens,
                        &closing_workspaces,
                    )? && !tab_orders.contains(tab.pane_id.as_str())
                    {
                        anyhow::bail!(
                            "creating or moving tab {} requires SetTabOrder for {}",
                            tab.public_id,
                            tab.pane_id
                        );
                    }
                    if let Some((old_pane, _)) = stored
                        && old_pane != tab.pane_id.as_str()
                        && !pane_closes_in_patch(
                            transaction,
                            &old_pane,
                            &closing_panes,
                            &closing_screens,
                            &closing_workspaces,
                        )?
                        && !tab_orders.contains(old_pane.as_str())
                    {
                        anyhow::bail!(
                            "moving tab {} requires SetTabOrder for old pane {}",
                            tab.public_id,
                            old_pane
                        );
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id, .. } => {
                if let Some(pane_id) =
                    resource_field_any(transaction, "resource_tabs", "pane_id", tab_id.as_str())?
                    && !pane_closes_in_patch(
                        transaction,
                        &pane_id,
                        &closing_panes,
                        &closing_screens,
                        &closing_workspaces,
                    )?
                    && !tab_orders.contains(pane_id.as_str())
                {
                    anyhow::bail!("closing tab {tab_id} requires SetTabOrder for pane {pane_id}");
                }
            }
            ResourceChange::TombstoneTerminal { public_id, .. } => {
                require_content_tab_order(
                    transaction,
                    public_id.as_str(),
                    &tab_orders,
                    &closing_panes,
                    &closing_screens,
                    &closing_workspaces,
                )?;
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                require_content_tab_order(
                    transaction,
                    public_id.as_str(),
                    &tab_orders,
                    &closing_panes,
                    &closing_screens,
                    &closing_workspaces,
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn require_content_tab_order(
    transaction: &Transaction<'_>,
    content_id: &str,
    tab_orders: &HashSet<&str>,
    closing_panes: &HashSet<&str>,
    closing_screens: &HashSet<&str>,
    closing_workspaces: &HashSet<&str>,
) -> anyhow::Result<()> {
    let pane_ids = {
        let mut statement = transaction.prepare(
            "SELECT pane_id FROM resource_tabs
             WHERE content_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([content_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for pane_id in pane_ids {
        if !pane_closes_in_patch(
            transaction,
            &pane_id,
            closing_panes,
            closing_screens,
            closing_workspaces,
        )? && !tab_orders.contains(pane_id.as_str())
        {
            anyhow::bail!("closing content {content_id} requires SetTabOrder for pane {pane_id}");
        }
    }
    Ok(())
}

fn pane_closes_in_patch(
    transaction: &Transaction<'_>,
    pane_id: &str,
    closing_panes: &HashSet<&str>,
    closing_screens: &HashSet<&str>,
    closing_workspaces: &HashSet<&str>,
) -> anyhow::Result<bool> {
    if closing_panes.contains(pane_id) {
        return Ok(true);
    }
    let Some(screen_id) = resource_field_any(transaction, "resource_panes", "screen_id", pane_id)?
    else {
        return Ok(false);
    };
    if closing_screens.contains(screen_id.as_str()) {
        return Ok(true);
    }
    let workspace_id =
        resource_field_any(transaction, "resource_screens", "workspace_id", &screen_id)?;
    Ok(workspace_id.is_some_and(|workspace| closing_workspaces.contains(workspace.as_str())))
}

fn resource_field_any(
    transaction: &Transaction<'_>,
    table: &str,
    field: &str,
    public_id: &str,
) -> anyhow::Result<Option<String>> {
    let query = format!("SELECT {field} FROM {table} WHERE public_id = ?1");
    Ok(transaction.query_row(&query, [public_id], |row| row.get::<_, String>(0)).optional()?)
}

fn prepare_resource_order_slots(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    for change in &patch.changes {
        match change {
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                let desired = workspace_ids
                    .iter()
                    .enumerate()
                    .map(|(position, id)| (id.as_str(), position))
                    .collect::<HashMap<_, _>>();
                let current = {
                    let mut statement = transaction.prepare(
                        "SELECT rw.public_id, w.workspace_key, w.position
                         FROM workspaces w
                         JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
                         WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL",
                    )?;
                    statement
                        .query_map([], |row| {
                            Ok((
                                row.get::<_, String>(0)?,
                                row.get::<_, String>(1)?,
                                row.get::<_, i64>(2)?,
                            ))
                        })?
                        .collect::<Result<Vec<_>, _>>()?
                };
                for (public_id, workspace_key, position) in current {
                    let unchanged = desired
                        .get(public_id.as_str())
                        .and_then(|position| i64::try_from(*position).ok())
                        == Some(position);
                    if !unchanged {
                        transaction.execute(
                            "UPDATE workspaces SET position = -rowid
                             WHERE workspace_key = ?1 AND tombstoned = 0",
                            [&workspace_key],
                        )?;
                    }
                }
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                prepare_child_order_slots(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    workspace_id.as_str(),
                    screen_ids.iter().map(ScreenPublicId::as_str),
                )?;
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                prepare_child_order_slots(
                    transaction,
                    "resource_tabs",
                    "pane_id",
                    pane_id.as_str(),
                    tab_ids.iter().map(TabPublicId::as_str),
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn prepare_child_order_slots<'a>(
    transaction: &Transaction<'_>,
    table: &str,
    parent_field: &str,
    parent_id: &str,
    desired_ids: impl IntoIterator<Item = &'a str>,
) -> anyhow::Result<()> {
    let desired = desired_ids
        .into_iter()
        .enumerate()
        .map(|(position, id)| (id, position))
        .collect::<HashMap<_, _>>();
    let query = format!(
        "SELECT public_id, position FROM {table}
         WHERE {parent_field} = ?1 AND deleted_revision IS NULL"
    );
    let current = {
        let mut statement = transaction.prepare(&query)?;
        statement
            .query_map([parent_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (public_id, position) in current {
        let unchanged =
            desired.get(public_id.as_str()).and_then(|position| i64::try_from(*position).ok())
                == Some(position);
        if !unchanged {
            transaction.execute(
                &format!(
                    "UPDATE {table} SET position = -rowid
                     WHERE public_id = ?1 AND deleted_revision IS NULL"
                ),
                [&public_id],
            )?;
        }
    }
    Ok(())
}

fn upsert_resource_workspace(
    transaction: &Transaction<'_>,
    workspace: &RegistryWorkspace,
    position: usize,
    active_screen: Option<&ScreenPublicId>,
    revision: i64,
) -> anyhow::Result<()> {
    upsert_workspace_resource(transaction, workspace, revision)?;
    let position = i64::try_from(position).context("workspace position exceeds SQLite range")?;
    transaction.execute(
        "INSERT INTO workspaces(
           workspace_key, numeric_id, name, group_key, position, tombstoned,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, NULL)
         ON CONFLICT(workspace_key) DO UPDATE SET
           numeric_id=excluded.numeric_id,
           name=excluded.name,
           group_key=excluded.group_key,
           position=excluded.position,
           updated_revision=excluded.updated_revision",
        params![
            workspace.key,
            i64::try_from(workspace.id).context("workspace id exceeds SQLite range")?,
            workspace.name,
            workspace.group_key,
            position,
            revision,
        ],
    )?;
    transaction.execute(
        "UPDATE resource_workspaces
         SET active_screen_id = ?1, updated_revision = ?2
         WHERE public_id = ?3 AND deleted_revision IS NULL",
        params![active_screen.map(ScreenPublicId::as_str), revision, workspace.public_id.as_str(),],
    )?;
    Ok(())
}

fn upsert_resource_screen(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
    revision: i64,
) -> anyhow::Result<()> {
    let old_splits = transaction
        .query_row(
            "SELECT layout_json, viewport_json FROM resource_screens WHERE public_id = ?1",
            [screen.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
        .map(|(layout, viewport)| {
            let layout: RegistryLayoutNode = serde_json::from_str(&layout)?;
            let viewport: RegistryViewport = serde_json::from_str(&viewport)?;
            let mut splits = Vec::new();
            collect_screen_split_public_ids(&layout, &viewport, &mut splits);
            Ok::<_, anyhow::Error>(splits)
        })
        .transpose()?
        .unwrap_or_default();
    upsert_resource_identity(transaction, screen.public_id.as_str(), "screen", revision)?;
    let mut desired_splits = Vec::new();
    collect_screen_split_public_ids(&screen.layout, &screen.viewport, &mut desired_splits);
    for split in &desired_splits {
        upsert_resource_identity(transaction, split, "split", revision)?;
    }
    let desired_splits = desired_splits.into_iter().collect::<HashSet<_>>();
    for split in old_splits {
        if !desired_splits.contains(&split) {
            tombstone_resource_identity(transaction, &split, revision)?;
        }
    }
    let layout = canonical_json(&serde_json::to_value(&screen.layout)?)?;
    let auto_layout = screen
        .auto_layout
        .as_ref()
        .map(|value| canonical_json(&serde_json::to_value(value)?))
        .transpose()?;
    let viewport = canonical_json(&serde_json::to_value(&screen.viewport)?)?;
    transaction.execute(
        "INSERT INTO resource_screens(
           public_id, workspace_id, position, name, layout_json, active_pane_id,
           zoomed_pane_id, auto_layout_json, viewport_json,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           workspace_id=excluded.workspace_id,
           position=excluded.position,
           name=excluded.name,
           layout_json=excluded.layout_json,
           active_pane_id=excluded.active_pane_id,
           zoomed_pane_id=excluded.zoomed_pane_id,
           auto_layout_json=excluded.auto_layout_json,
           viewport_json=excluded.viewport_json,
           updated_revision=excluded.updated_revision",
        params![
            screen.public_id.as_str(),
            screen.workspace_id.as_str(),
            i64::try_from(screen.position).context("screen position exceeds SQLite range")?,
            screen.name,
            layout,
            screen.active_pane.as_str(),
            screen.zoomed_pane.as_ref().map(PanePublicId::as_str),
            auto_layout,
            viewport,
            revision,
        ],
    )?;
    Ok(())
}

fn upsert_resource_pane(
    transaction: &Transaction<'_>,
    pane: &RegistryPane,
    revision: i64,
) -> anyhow::Result<()> {
    upsert_resource_identity(transaction, pane.public_id.as_str(), "pane", revision)?;
    transaction.execute(
        "INSERT INTO resource_panes(
           public_id, screen_id, name, active_tab_id, creation_ordinal,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           screen_id=excluded.screen_id,
           name=excluded.name,
           active_tab_id=excluded.active_tab_id,
           creation_ordinal=excluded.creation_ordinal,
           updated_revision=excluded.updated_revision",
        params![
            pane.public_id.as_str(),
            pane.screen_id.as_str(),
            pane.name,
            pane.active_tab.as_ref().map(TabPublicId::as_str),
            i64::try_from(pane.creation_ordinal)
                .context("pane creation ordinal exceeds SQLite range")?,
            revision,
        ],
    )?;
    Ok(())
}

fn upsert_resource_tab(
    transaction: &Transaction<'_>,
    tab: &RegistryTab,
    revision: i64,
) -> anyhow::Result<()> {
    upsert_resource_identity(transaction, tab.public_id.as_str(), "tab", revision)?;
    let (content_kind, content_id) = match &tab.content_id {
        ContentPublicId::Terminal(id) => ("terminal", id.as_str()),
        ContentPublicId::Browser(id) => ("browser", id.as_str()),
    };
    let concrete_table = match content_kind {
        "terminal" => "resource_terminals",
        "browser" => "resource_browsers",
        _ => unreachable!("content kind is exhaustive"),
    };
    if live_resource_field(transaction, concrete_table, "public_id", content_id)?.is_none() {
        anyhow::bail!("tab {} references unknown {content_kind} {content_id}", tab.public_id);
    }
    if let (ContentPublicId::Browser(_), Some(expected_url)) = (&tab.content_id, &tab.browser_url) {
        let stored_url = live_resource_field(transaction, "resource_browsers", "url", content_id)?;
        if stored_url.as_deref() != Some(expected_url.as_str()) {
            anyhow::bail!(
                "tab {} browser URL does not match browser {}",
                tab.public_id,
                content_id
            );
        }
    }
    if let (ContentPublicId::Terminal(_), Some(expected_terminal_id)) =
        (&tab.content_id, &tab.terminal_id)
    {
        let stored_terminal_id =
            live_resource_field(transaction, "resource_terminals", "terminal_id", content_id)?;
        if stored_terminal_id.as_deref() != Some(expected_terminal_id.as_str()) {
            anyhow::bail!(
                "tab {} terminal host does not match terminal {}",
                tab.public_id,
                content_id
            );
        }
    }
    if let Some((stored_kind, stored_id)) = transaction
        .query_row(
            "SELECT content_kind, content_id FROM resource_tabs WHERE public_id = ?1",
            [tab.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
        && (stored_kind != content_kind || stored_id != content_id)
    {
        anyhow::bail!("tab {} cannot change its content identity", tab.public_id);
    }
    transaction.execute(
        "INSERT INTO resource_tabs(
           public_id, pane_id, position, content_kind, content_id, name,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           pane_id=excluded.pane_id,
           position=excluded.position,
           name=excluded.name,
           updated_revision=excluded.updated_revision",
        params![
            tab.public_id.as_str(),
            tab.pane_id.as_str(),
            i64::try_from(tab.position).context("tab position exceeds SQLite range")?,
            content_kind,
            content_id,
            tab.name,
            revision,
        ],
    )?;
    Ok(())
}

fn upsert_resource_terminal(
    transaction: &Transaction<'_>,
    public_id: &TerminalPublicId,
    terminal: &RegistryTerminal,
    revision: i64,
) -> anyhow::Result<()> {
    let existing = read_terminal(transaction, &terminal.terminal_id)?;
    validate_terminal_transition(existing.as_ref(), terminal)?;
    if terminal.lifecycle != TerminalLifecycle::Tombstoned
        && existing.as_ref().is_none_or(|stored| stored.workspace_key != terminal.workspace_key)
    {
        require_live_workspace(transaction, &terminal.workspace_key)?;
    }
    let launch_spec = canonical_json(&terminal.launch_spec)?;
    if launch_spec.len() > MAX_LAUNCH_SPEC_BYTES {
        anyhow::bail!("terminal launch spec exceeds {MAX_LAUNCH_SPEC_BYTES} bytes");
    }
    let exit = terminal.exit.as_ref().map(canonical_json).transpose()?;
    upsert_resource_identity(transaction, public_id.as_str(), "terminal", revision)?;
    transaction.execute(
        "INSERT INTO resource_terminals(
           public_id, terminal_id, lifecycle,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, 'active', ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           lifecycle='active',
           updated_revision=excluded.updated_revision",
        params![public_id.as_str(), terminal.terminal_id, revision],
    )?;
    // Full topology projections also carry catalog-only terminals with no
    // views. Their host row is already authoritative, so avoid rewriting it
    // merely because an unrelated tab, pane, or workspace changed.
    if existing.as_ref() == Some(terminal) {
        return Ok(());
    }
    if existing.as_ref().is_some_and(|stored| {
        stored.lifecycle == TerminalLifecycle::Exited
            && terminal.lifecycle == TerminalLifecycle::Exited
    }) {
        if existing.as_ref().and_then(|stored| stored.incarnation.as_deref())
            != terminal.incarnation.as_deref()
        {
            anyhow::bail!("terminal_incarnation_mismatch");
        }
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO terminal_hosts(
           terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
           exit_json, on_exit, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9)
         ON CONFLICT(terminal_id) DO UPDATE SET
           workspace_key=excluded.workspace_key,
           incarnation=excluded.incarnation,
           lifecycle=excluded.lifecycle,
           launch_spec_json=excluded.launch_spec_json,
           exit_json=excluded.exit_json,
           on_exit=excluded.on_exit,
           updated_revision=excluded.updated_revision,
           deleted_revision=excluded.deleted_revision",
        params![
            terminal.terminal_id,
            terminal.workspace_key,
            terminal.incarnation,
            terminal.lifecycle.as_str(),
            launch_spec,
            exit,
            terminal.on_exit.as_str(),
            revision,
            (terminal.lifecycle == TerminalLifecycle::Tombstoned).then_some(revision),
        ],
    )?;
    Ok(())
}

fn upsert_resource_browser(
    transaction: &Transaction<'_>,
    browser: &RegistryBrowser,
    revision: i64,
) -> anyhow::Result<()> {
    validate_registry_browser(browser)?;
    let metadata = canonical_json(&serde_json::to_value(browser)?)?;
    upsert_resource_identity(transaction, browser.public_id.as_str(), "browser", revision)?;
    transaction.execute(
        "INSERT INTO resource_browsers(
           public_id, url, metadata_json, lifecycle,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, 'running', ?4, ?4, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           url=excluded.url,
           metadata_json=excluded.metadata_json,
           lifecycle='running',
           updated_revision=excluded.updated_revision",
        params![browser.public_id.as_str(), browser.url.as_str(), metadata, revision],
    )?;
    Ok(())
}

fn tombstone_resource_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    let Some(workspace_key) =
        live_resource_field(transaction, "resource_workspaces", "workspace_key", workspace_id)?
    else {
        require_known_resource(transaction, workspace_id, "workspace")?;
        return Ok(());
    };
    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_screens
             WHERE workspace_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([workspace_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for screen in screens {
        tombstone_resource_screen(transaction, &screen, revision)?;
    }

    transaction.execute(
        "UPDATE resource_workspaces
         SET active_screen_id = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, workspace_id],
    )?;
    transaction.execute(
        "UPDATE workspaces
         SET position = NULL, tombstoned = 1, updated_revision = ?1, deleted_revision = ?1
         WHERE workspace_key = ?2 AND tombstoned = 0",
        params![revision, workspace_key],
    )?;
    tombstone_resource_identity(transaction, workspace_id, revision)?;
    if meta_value(transaction, "active_workspace_id")?.as_deref() == Some(workspace_id) {
        transaction.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
    }
    Ok(())
}

fn tombstone_resource_screen(
    transaction: &Transaction<'_>,
    screen_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT layout_json, viewport_json FROM resource_screens
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [screen_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    let Some((layout_json, viewport_json)) = stored else {
        require_known_resource(transaction, screen_id, "screen")?;
        return Ok(());
    };
    let panes = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_panes
             WHERE screen_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([screen_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for pane in panes {
        tombstone_resource_pane(transaction, &pane, revision)?;
    }
    let layout: RegistryLayoutNode = serde_json::from_str(&layout_json)?;
    let viewport: RegistryViewport = serde_json::from_str(&viewport_json)?;
    let mut splits = Vec::new();
    collect_screen_split_public_ids(&layout, &viewport, &mut splits);
    for split in splits {
        tombstone_resource_identity(transaction, &split, revision)?;
    }
    transaction.execute(
        "UPDATE resource_screens
         SET position = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, screen_id],
    )?;
    transaction.execute(
        "UPDATE resource_workspaces
         SET active_screen_id = NULL, updated_revision = ?1
         WHERE active_screen_id = ?2 AND deleted_revision IS NULL",
        params![revision, screen_id],
    )?;
    tombstone_resource_identity(transaction, screen_id, revision)
}

fn tombstone_resource_pane(
    transaction: &Transaction<'_>,
    pane_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    if live_resource_field(transaction, "resource_panes", "screen_id", pane_id)?.is_none() {
        require_known_resource(transaction, pane_id, "pane")?;
        return Ok(());
    }
    let tabs = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_tabs
             WHERE pane_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([pane_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for tab in tabs {
        tombstone_resource_tab(transaction, &tab, revision, true)?;
    }
    transaction.execute(
        "UPDATE resource_panes
         SET active_tab_id = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, pane_id],
    )?;
    tombstone_resource_identity(transaction, pane_id, revision)
}

fn tombstone_resource_tab(
    transaction: &Transaction<'_>,
    tab_id: &str,
    revision: i64,
    close_content: bool,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT content_kind, content_id FROM resource_tabs
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [tab_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    let Some((content_kind, content_id)) = stored else {
        require_known_resource(transaction, tab_id, "tab")?;
        return Ok(());
    };
    if !close_content {
        match content_kind.as_str() {
            "terminal" => {
                let terminal_id = live_resource_field(
                    transaction,
                    "resource_terminals",
                    "terminal_id",
                    &content_id,
                )?
                .with_context(|| {
                    format!("tab {tab_id} references unknown terminal {content_id}")
                })?;
                let terminal = read_terminal(transaction, &terminal_id)?
                    .with_context(|| format!("terminal {terminal_id} has no durable placement"))?;
                anyhow::ensure!(
                    terminal.lifecycle == TerminalLifecycle::Exited,
                    "tab {tab_id} can detach only exited terminal content"
                );
            }
            "browser" => anyhow::bail!("tab {tab_id} cannot detach browser content"),
            other => anyhow::bail!("stored tab {tab_id} has invalid content kind {other:?}"),
        }
    }
    tombstone_resource_tab_row(transaction, tab_id, revision)?;
    if close_content && content_kind == "browser" {
        tombstone_resource_browser(transaction, &content_id, revision)?;
    } else if !matches!(content_kind.as_str(), "terminal" | "browser") {
        anyhow::bail!("stored tab {tab_id} has invalid content kind {content_kind:?}");
    }
    Ok(())
}

fn tombstone_resource_tab_row(
    transaction: &Transaction<'_>,
    tab_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE resource_tabs
         SET position = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, tab_id],
    )?;
    transaction.execute(
        "UPDATE resource_panes
         SET active_tab_id = NULL, updated_revision = ?1
         WHERE active_tab_id = ?2 AND deleted_revision IS NULL",
        params![revision, tab_id],
    )?;
    tombstone_resource_identity(transaction, tab_id, revision)
}

fn tombstone_resource_terminal(
    transaction: &Transaction<'_>,
    public_id: &str,
    expected_incarnation: Option<&str>,
    revision: i64,
) -> anyhow::Result<()> {
    let terminal_id = transaction
        .query_row(
            "SELECT terminal_id FROM resource_terminals WHERE public_id = ?1",
            [public_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(terminal_id) = terminal_id else {
        require_known_resource(transaction, public_id, "terminal")?;
        return Ok(());
    };
    let terminal = read_terminal(transaction, &terminal_id)?;
    if let Some(expected) = expected_incarnation
        && terminal.as_ref().and_then(|stored| stored.incarnation.as_deref()) != Some(expected)
    {
        anyhow::bail!("terminal_incarnation_mismatch");
    }
    let tabs = live_tabs_for_content(transaction, public_id)?;
    for tab in tabs {
        tombstone_resource_tab_row(transaction, &tab, revision)?;
    }
    transaction.execute(
        "UPDATE resource_terminals
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, public_id],
    )?;
    transaction.execute(
        "UPDATE terminal_hosts
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE terminal_id = ?2 AND lifecycle != 'tombstoned'",
        params![revision, terminal_id],
    )?;
    tombstone_resource_identity(transaction, public_id, revision)
}

fn tombstone_resource_browser(
    transaction: &Transaction<'_>,
    public_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    let known = transaction
        .query_row("SELECT 1 FROM resource_browsers WHERE public_id = ?1", [public_id], |_| Ok(()))
        .optional()?;
    if known.is_none() {
        require_known_resource(transaction, public_id, "browser")?;
        return Ok(());
    }
    let tabs = live_tabs_for_content(transaction, public_id)?;
    for tab in tabs {
        tombstone_resource_tab_row(transaction, &tab, revision)?;
    }
    transaction.execute(
        "UPDATE resource_browsers
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, public_id],
    )?;
    tombstone_resource_identity(transaction, public_id, revision)
}

fn live_tabs_for_content(
    transaction: &Transaction<'_>,
    content_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT public_id FROM resource_tabs
         WHERE content_id = ?1 AND deleted_revision IS NULL",
    )?;
    Ok(statement
        .query_map([content_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

fn live_resource_field(
    transaction: &Transaction<'_>,
    table: &str,
    field: &str,
    public_id: &str,
) -> anyhow::Result<Option<String>> {
    let query =
        format!("SELECT {field} FROM {table} WHERE public_id = ?1 AND deleted_revision IS NULL");
    Ok(transaction.query_row(&query, [public_id], |row| row.get::<_, String>(0)).optional()?)
}

fn require_known_resource(
    transaction: &Transaction<'_>,
    public_id: &str,
    expected_kind: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT kind FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    match stored.as_deref() {
        Some(kind) if kind == expected_kind => Ok(()),
        Some(kind) => anyhow::bail!("public id {public_id} has resource kind {kind}"),
        None => anyhow::bail!("unknown {expected_kind} resource {public_id}"),
    }
}

fn tombstone_resource_identity(
    transaction: &Transaction<'_>,
    public_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE resource_identities
         SET updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, public_id],
    )?;
    Ok(())
}

fn set_resource_workspace_order(
    transaction: &Transaction<'_>,
    workspace_ids: &[WorkspacePublicId],
    revision: i64,
) -> anyhow::Result<()> {
    let live = {
        let mut statement = transaction.prepare(
            "SELECT rw.public_id
             FROM resource_workspaces rw
             JOIN workspaces w ON w.workspace_key = rw.workspace_key
             WHERE rw.deleted_revision IS NULL AND w.tombstoned = 0",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    require_exact_order_set(
        "workspace",
        &live,
        workspace_ids.iter().map(WorkspacePublicId::as_str),
    )?;
    for (position, workspace_id) in workspace_ids.iter().enumerate() {
        transaction.execute(
            "UPDATE workspaces
             SET position = ?1, updated_revision = ?2
             WHERE workspace_key = (
               SELECT workspace_key FROM resource_workspaces
               WHERE public_id = ?3 AND deleted_revision IS NULL
             ) AND tombstoned = 0 AND position != ?1",
            params![
                i64::try_from(position).context("workspace position exceeds SQLite range")?,
                revision,
                workspace_id.as_str(),
            ],
        )?;
    }
    Ok(())
}

fn set_resource_screen_order(
    transaction: &Transaction<'_>,
    workspace_id: &WorkspacePublicId,
    screen_ids: &[ScreenPublicId],
    revision: i64,
) -> anyhow::Result<()> {
    let live =
        resource_children(transaction, "resource_screens", "workspace_id", workspace_id.as_str())?;
    require_exact_order_set("screen", &live, screen_ids.iter().map(ScreenPublicId::as_str))?;
    for (position, screen_id) in screen_ids.iter().enumerate() {
        transaction.execute(
            "UPDATE resource_screens
             SET position = ?1, updated_revision = ?2
             WHERE public_id = ?3 AND workspace_id = ?4
               AND deleted_revision IS NULL AND position != ?1",
            params![
                i64::try_from(position).context("screen position exceeds SQLite range")?,
                revision,
                screen_id.as_str(),
                workspace_id.as_str(),
            ],
        )?;
    }
    Ok(())
}

fn set_resource_tab_order(
    transaction: &Transaction<'_>,
    pane_id: &PanePublicId,
    tab_ids: &[TabPublicId],
    revision: i64,
) -> anyhow::Result<()> {
    let live = resource_children(transaction, "resource_tabs", "pane_id", pane_id.as_str())?;
    require_exact_order_set("tab", &live, tab_ids.iter().map(TabPublicId::as_str))?;
    for (position, tab_id) in tab_ids.iter().enumerate() {
        transaction.execute(
            "UPDATE resource_tabs
             SET position = ?1, updated_revision = ?2
             WHERE public_id = ?3 AND pane_id = ?4
               AND deleted_revision IS NULL AND position != ?1",
            params![
                i64::try_from(position).context("tab position exceeds SQLite range")?,
                revision,
                tab_id.as_str(),
                pane_id.as_str(),
            ],
        )?;
    }
    Ok(())
}

fn resource_children(
    transaction: &Transaction<'_>,
    table: &str,
    parent_field: &str,
    parent_id: &str,
) -> anyhow::Result<HashSet<String>> {
    let query = format!(
        "SELECT public_id FROM {table}
         WHERE {parent_field} = ?1 AND deleted_revision IS NULL"
    );
    let mut statement = transaction.prepare(&query)?;
    Ok(statement
        .query_map([parent_id], |row| row.get::<_, String>(0))?
        .collect::<Result<HashSet<_>, _>>()?)
}

fn require_exact_order_set<'a>(
    kind: &str,
    live: &HashSet<String>,
    requested: impl IntoIterator<Item = &'a str>,
) -> anyhow::Result<()> {
    let requested = requested.into_iter().collect::<HashSet<_>>();
    if live.len() != requested.len() || live.iter().any(|id| !requested.contains(id.as_str())) {
        anyhow::bail!("{kind} order must contain every live sibling exactly once");
    }
    Ok(())
}

fn set_active_resource_workspace(
    transaction: &Transaction<'_>,
    workspace_id: Option<&WorkspacePublicId>,
) -> anyhow::Result<()> {
    if let Some(workspace_id) = workspace_id {
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [workspace_id.as_str()],
        )?;
    } else {
        transaction.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
    }
    Ok(())
}

fn validate_touched_resource_invariants(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let mut workspaces = HashSet::<String>::new();
    let mut screens = HashSet::<String>::new();
    let mut panes = HashSet::<String>::new();
    let mut tabs = HashSet::<String>::new();
    let mut terminals = HashSet::<String>::new();
    let mut browsers = HashSet::<String>::new();

    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, active_screen, .. } => {
                workspaces.insert(workspace.public_id.to_string());
                if let Some(screen) = active_screen {
                    screens.insert(screen.to_string());
                }
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                workspaces.insert(workspace_id.to_string());
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                workspaces.extend(workspace_ids.iter().map(ToString::to_string));
            }
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                if let Some(workspace) = workspace_id {
                    workspaces.insert(workspace.to_string());
                }
            }
            ResourceChange::UpsertScreen(screen) => {
                screens.insert(screen.public_id.to_string());
                workspaces.insert(screen.workspace_id.to_string());
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                screens.insert(screen_id.to_string());
                if let Some(workspace) = resource_field_any(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    screen_id.as_str(),
                )? {
                    workspaces.insert(workspace);
                }
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                workspaces.insert(workspace_id.to_string());
                screens.extend(screen_ids.iter().map(ToString::to_string));
            }
            ResourceChange::UpsertPane(pane) => {
                panes.insert(pane.public_id.to_string());
                screens.insert(pane.screen_id.to_string());
            }
            ResourceChange::TombstonePane { pane_id } => {
                panes.insert(pane_id.to_string());
                if let Some(screen) = resource_field_any(
                    transaction,
                    "resource_panes",
                    "screen_id",
                    pane_id.as_str(),
                )? {
                    screens.insert(screen);
                }
            }
            ResourceChange::UpsertTab(tab) => {
                tabs.insert(tab.public_id.to_string());
                panes.insert(tab.pane_id.to_string());
                match &tab.content_id {
                    ContentPublicId::Terminal(id) => {
                        terminals.insert(id.to_string());
                    }
                    ContentPublicId::Browser(id) => {
                        browsers.insert(id.to_string());
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id, .. } => {
                tabs.insert(tab_id.to_string());
                collect_stored_tab_scope(
                    transaction,
                    tab_id.as_str(),
                    &mut panes,
                    &mut terminals,
                    &mut browsers,
                )?;
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                panes.insert(pane_id.to_string());
                tabs.extend(tab_ids.iter().map(ToString::to_string));
            }
            ResourceChange::UpsertTerminal { public_id, .. }
            | ResourceChange::TombstoneTerminal { public_id, .. } => {
                terminals.insert(public_id.to_string());
                collect_content_tab_scope(transaction, public_id.as_str(), &mut tabs, &mut panes)?;
            }
            ResourceChange::UpsertBrowser(browser) => {
                browsers.insert(browser.public_id.to_string());
                collect_content_tab_scope(
                    transaction,
                    browser.public_id.as_str(),
                    &mut tabs,
                    &mut panes,
                )?;
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                browsers.insert(public_id.to_string());
                collect_content_tab_scope(transaction, public_id.as_str(), &mut tabs, &mut panes)?;
            }
        }
    }

    for workspace in &workspaces {
        validate_touched_workspace(transaction, workspace)?;
    }
    for screen in &screens {
        validate_touched_screen(transaction, screen)?;
    }
    for pane in &panes {
        validate_touched_pane(transaction, pane)?;
    }
    for tab in &tabs {
        validate_touched_tab(transaction, tab)?;
    }
    for terminal in &terminals {
        validate_touched_terminal(transaction, terminal)?;
    }
    for browser in &browsers {
        validate_touched_browser(transaction, browser)?;
    }

    for change in &patch.changes {
        match change {
            ResourceChange::SetWorkspaceOrder { .. } => validate_contiguous_positions(
                transaction,
                "SELECT '' AS parent, position FROM workspaces
                 WHERE tombstoned = 0 ORDER BY position ASC",
                "workspace",
            )?,
            ResourceChange::SetScreenOrder { workspace_id, .. } => {
                validate_positions_for_parent(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    workspace_id.as_str(),
                    "screen",
                )?;
            }
            ResourceChange::SetTabOrder { pane_id, .. } => {
                validate_positions_for_parent(
                    transaction,
                    "resource_tabs",
                    "pane_id",
                    pane_id.as_str(),
                    "tab",
                )?;
            }
            _ => {}
        }
    }
    let live_workspace_count: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM resource_workspaces WHERE deleted_revision IS NULL",
        [],
        |row| row.get(0),
    )?;
    match meta_value(transaction, "active_workspace_id")? {
        Some(active_workspace)
            if live_resource_field(
                transaction,
                "resource_workspaces",
                "public_id",
                &active_workspace,
            )?
            .is_none() =>
        {
            anyhow::bail!("active workspace {active_workspace} is not live");
        }
        Some(_) => {}
        None if live_workspace_count != 0 => {
            anyhow::bail!("live session has workspaces but no active workspace");
        }
        None => {}
    }
    Ok(())
}

fn collect_stored_tab_scope(
    transaction: &Transaction<'_>,
    tab_id: &str,
    panes: &mut HashSet<String>,
    terminals: &mut HashSet<String>,
    browsers: &mut HashSet<String>,
) -> anyhow::Result<()> {
    if let Some((pane, kind, content)) = transaction
        .query_row(
            "SELECT pane_id, content_kind, content_id
             FROM resource_tabs WHERE public_id = ?1",
            [tab_id],
            |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            },
        )
        .optional()?
    {
        panes.insert(pane);
        match kind.as_str() {
            "terminal" => {
                terminals.insert(content);
            }
            "browser" => {
                browsers.insert(content);
            }
            other => anyhow::bail!("stored tab {tab_id} has invalid content kind {other:?}"),
        }
    }
    Ok(())
}

fn collect_content_tab_scope(
    transaction: &Transaction<'_>,
    content_id: &str,
    tabs: &mut HashSet<String>,
    panes: &mut HashSet<String>,
) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction
            .prepare("SELECT public_id, pane_id FROM resource_tabs WHERE content_id = ?1")?;
        statement
            .query_map([content_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (tab, pane) in rows {
        tabs.insert(tab);
        panes.insert(pane);
    }
    Ok(())
}

fn validate_touched_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT workspace_key, active_screen_id, deleted_revision
             FROM resource_workspaces WHERE public_id = ?1",
            [workspace_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((workspace_key, active_screen, deleted)) = stored else {
        anyhow::bail!("unknown workspace resource {workspace_id}");
    };
    validate_identity_state(transaction, workspace_id, "workspace", deleted.is_none())?;
    if deleted.is_some() {
        let live_descendant: i64 = transaction.query_row(
            "SELECT
               EXISTS(SELECT 1 FROM resource_screens
                      WHERE workspace_id = ?1 AND deleted_revision IS NULL)
               OR EXISTS(
                 SELECT 1 FROM resource_panes p
                 JOIN resource_screens s ON s.public_id = p.screen_id
                 WHERE s.workspace_id = ?1 AND p.deleted_revision IS NULL
               )
               OR EXISTS(
                 SELECT 1 FROM resource_tabs t
                 JOIN resource_panes p ON p.public_id = t.pane_id
                 JOIN resource_screens s ON s.public_id = p.screen_id
                 WHERE s.workspace_id = ?1 AND t.deleted_revision IS NULL
               )",
            [workspace_id],
            |row| row.get(0),
        )?;
        if live_descendant != 0 {
            anyhow::bail!("closed workspace {workspace_id} retains live descendants");
        }
        return Ok(());
    }
    let workspace_live = transaction
        .query_row(
            "SELECT 1 FROM workspaces
             WHERE workspace_key = ?1 AND tombstoned = 0",
            [&workspace_key],
            |_| Ok(()),
        )
        .optional()?;
    if workspace_live.is_none() {
        anyhow::bail!("resource workspace {workspace_id} has no live workspace row");
    }
    let child_screens =
        resource_children(transaction, "resource_screens", "workspace_id", workspace_id)?;
    match active_screen {
        Some(active_screen) => {
            let owner = live_resource_field(
                transaction,
                "resource_screens",
                "workspace_id",
                &active_screen,
            )?;
            if owner.as_deref() != Some(workspace_id) {
                anyhow::bail!(
                    "workspace {workspace_id} selects screen {active_screen} owned by {owner:?}"
                );
            }
        }
        None if !child_screens.is_empty() => {
            anyhow::bail!("workspace {workspace_id} has screens but no active screen");
        }
        None => {}
    }
    Ok(())
}

fn validate_touched_screen(transaction: &Transaction<'_>, screen_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT workspace_id, layout_json, active_pane_id, zoomed_pane_id,
                    viewport_json, deleted_revision
             FROM resource_screens WHERE public_id = ?1",
            [screen_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<i64>>(5)?,
                ))
            },
        )
        .optional()?;
    let Some((workspace_id, layout, active_pane, zoomed_pane, viewport, deleted)) = stored else {
        anyhow::bail!("unknown screen resource {screen_id}");
    };
    validate_identity_state(transaction, screen_id, "screen", deleted.is_none())?;
    if deleted.is_some() {
        if !resource_children(transaction, "resource_panes", "screen_id", screen_id)?.is_empty() {
            anyhow::bail!("closed screen {screen_id} retains live panes");
        }
        return Ok(());
    }
    if live_resource_field(transaction, "resource_workspaces", "public_id", &workspace_id)?
        .is_none()
    {
        anyhow::bail!("screen {screen_id} has closed workspace {workspace_id}");
    }
    let layout: RegistryLayoutNode = serde_json::from_str(&layout)?;
    let viewport: RegistryViewport = serde_json::from_str(&viewport)?;
    let mut layout_panes = HashSet::new();
    let mut layout_splits = HashSet::new();
    validate_layout_node(&layout, &mut layout_panes, &mut layout_splits)?;
    validate_registry_viewport(&viewport, &layout, &layout_panes, &layout_splits)?;
    let layout_panes = layout_panes.into_iter().map(ToString::to_string).collect::<HashSet<_>>();
    let stored_panes = resource_children(transaction, "resource_panes", "screen_id", screen_id)?;
    if layout_panes != stored_panes {
        anyhow::bail!("screen {screen_id} layout does not match its live pane rows");
    }
    if !stored_panes.contains(&active_pane)
        || zoomed_pane.as_ref().is_some_and(|pane| !stored_panes.contains(pane))
    {
        anyhow::bail!("screen {screen_id} selects a pane outside its layout");
    }
    let mut split_ids = Vec::new();
    collect_screen_split_public_ids(&layout, &viewport, &mut split_ids);
    for split in split_ids {
        validate_identity_state(transaction, &split, "split", true)?;
    }
    Ok(())
}

fn validate_touched_pane(transaction: &Transaction<'_>, pane_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT screen_id, active_tab_id, deleted_revision
             FROM resource_panes WHERE public_id = ?1",
            [pane_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((screen_id, active_tab, deleted)) = stored else {
        anyhow::bail!("unknown pane resource {pane_id}");
    };
    validate_identity_state(transaction, pane_id, "pane", deleted.is_none())?;
    if deleted.is_some() {
        if !resource_children(transaction, "resource_tabs", "pane_id", pane_id)?.is_empty() {
            anyhow::bail!("closed pane {pane_id} retains live tabs");
        }
        return Ok(());
    }
    if live_resource_field(transaction, "resource_screens", "public_id", &screen_id)?.is_none() {
        anyhow::bail!("pane {pane_id} has closed screen {screen_id}");
    }
    let child_tabs = resource_children(transaction, "resource_tabs", "pane_id", pane_id)?;
    match active_tab {
        Some(active_tab) => {
            let owner = live_resource_field(transaction, "resource_tabs", "pane_id", &active_tab)?;
            if owner.as_deref() != Some(pane_id) {
                anyhow::bail!("pane {pane_id} selects tab {active_tab} owned by {owner:?}");
            }
        }
        None if !child_tabs.is_empty() => {
            anyhow::bail!("pane {pane_id} has tabs but no active tab");
        }
        None => {}
    }
    Ok(())
}

fn validate_touched_tab(transaction: &Transaction<'_>, tab_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT pane_id, content_kind, content_id, deleted_revision
             FROM resource_tabs WHERE public_id = ?1",
            [tab_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((pane_id, content_kind, content_id, deleted)) = stored else {
        anyhow::bail!("unknown tab resource {tab_id}");
    };
    validate_identity_state(transaction, tab_id, "tab", deleted.is_none())?;
    if deleted.is_some() {
        return Ok(());
    }
    if live_resource_field(transaction, "resource_panes", "public_id", &pane_id)?.is_none() {
        anyhow::bail!("tab {tab_id} has closed pane {pane_id}");
    }
    let table = match content_kind.as_str() {
        "terminal" => "resource_terminals",
        "browser" => "resource_browsers",
        other => anyhow::bail!("tab {tab_id} has invalid content kind {other:?}"),
    };
    if live_resource_field(transaction, table, "public_id", &content_id)?.is_none() {
        anyhow::bail!("tab {tab_id} references closed {content_kind} {content_id}");
    }
    validate_identity_state(transaction, &content_id, &content_kind, true)
}

fn validate_touched_terminal(
    transaction: &Transaction<'_>,
    terminal_id: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT terminal_id, lifecycle, deleted_revision
             FROM resource_terminals WHERE public_id = ?1",
            [terminal_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((host_id, lifecycle, deleted)) = stored else {
        anyhow::bail!("unknown terminal resource {terminal_id}");
    };
    validate_identity_state(transaction, terminal_id, "terminal", deleted.is_none())?;
    if (deleted.is_none() && lifecycle != "active")
        || (deleted.is_some() && lifecycle != "tombstoned")
    {
        anyhow::bail!("terminal {terminal_id} has inconsistent lifecycle {lifecycle}");
    }
    let placement = read_terminal(transaction, &host_id)?;
    if deleted.is_none()
        && placement
            .as_ref()
            .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned)
    {
        anyhow::bail!("terminal resource {terminal_id} has no live placement");
    }
    if deleted.is_some()
        && placement
            .as_ref()
            .is_some_and(|terminal| terminal.lifecycle != TerminalLifecycle::Tombstoned)
    {
        anyhow::bail!("closed terminal resource {terminal_id} retains a live placement");
    }
    Ok(())
}

fn validate_touched_browser(transaction: &Transaction<'_>, browser_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT url, metadata_json, lifecycle, deleted_revision
             FROM resource_browsers WHERE public_id = ?1",
            [browser_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((url, metadata, lifecycle, deleted)) = stored else {
        anyhow::bail!("unknown browser resource {browser_id}");
    };
    validate_identity_state(transaction, browser_id, "browser", deleted.is_none())?;
    if (deleted.is_none() && lifecycle != "running")
        || (deleted.is_some() && lifecycle != "tombstoned")
    {
        anyhow::bail!("browser {browser_id} has inconsistent lifecycle {lifecycle}");
    }
    if deleted.is_none() {
        let metadata =
            metadata.ok_or_else(|| anyhow::anyhow!("browser {browser_id} has no metadata"))?;
        let browser: RegistryBrowser = serde_json::from_str(&metadata)
            .with_context(|| format!("invalid metadata for browser {browser_id}"))?;
        validate_registry_browser(&browser)?;
        if browser.public_id.as_str() != browser_id || browser.url != url {
            anyhow::bail!("browser {browser_id} metadata does not match its indexed fields");
        }
    }
    Ok(())
}

fn validate_identity_state(
    transaction: &Transaction<'_>,
    public_id: &str,
    expected_kind: &str,
    expected_live: bool,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?;
    let Some((kind, deleted)) = stored else {
        anyhow::bail!("{expected_kind} {public_id} has no identity ledger row");
    };
    if kind != expected_kind || deleted.is_none() != expected_live {
        anyhow::bail!(
            "{expected_kind} {public_id} identity state mismatch: kind={kind}, live={}",
            deleted.is_none()
        );
    }
    Ok(())
}

fn validate_positions_for_parent(
    transaction: &Transaction<'_>,
    table: &str,
    parent_field: &str,
    parent_id: &str,
    kind: &str,
) -> anyhow::Result<()> {
    let query = format!(
        "SELECT {parent_field}, position FROM {table}
         WHERE {parent_field} = ?1 AND deleted_revision IS NULL
         ORDER BY position ASC"
    );
    let rows = {
        let mut statement = transaction.prepare(&query)?;
        statement
            .query_map([parent_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (expected, (_, position)) in rows.into_iter().enumerate() {
        if position != i64::try_from(expected)? {
            anyhow::bail!(
                "{kind} positions under {parent_id} are not contiguous: expected {expected}, found {position}"
            );
        }
    }
    Ok(())
}

pub(super) fn validate_resource_invariants(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    ensure_no_foreign_key_violations(transaction)?;
    validate_concrete_identity_lifecycles(transaction)?;
    validate_contiguous_positions(
        transaction,
        "SELECT '' AS parent, position FROM workspaces
         WHERE tombstoned = 0 ORDER BY position ASC",
        "workspace",
    )?;
    validate_contiguous_positions(
        transaction,
        "SELECT workspace_id, position FROM resource_screens
         WHERE deleted_revision IS NULL ORDER BY workspace_id ASC, position ASC",
        "screen",
    )?;
    validate_contiguous_positions(
        transaction,
        "SELECT pane_id, position FROM resource_tabs
         WHERE deleted_revision IS NULL ORDER BY pane_id ASC, position ASC",
        "tab",
    )?;

    let unmapped_workspace = transaction
        .query_row(
            "SELECT w.workspace_key
             FROM workspaces w
             LEFT JOIN resource_workspaces rw
               ON rw.workspace_key = w.workspace_key AND rw.deleted_revision IS NULL
             WHERE w.tombstoned = 0 AND rw.public_id IS NULL
               AND NOT EXISTS (
                 SELECT 1
                 FROM resource_creation_receipts creation
                 WHERE creation.execution_kind = 'effect'
                   AND creation.state = 'executing'
                   AND json_extract(
                         creation.intent_json,
                         '$.workspace_reservation.workspace_key'
                       ) = w.workspace_key
               )
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(workspace_key) = unmapped_workspace {
        anyhow::bail!("live workspace {workspace_key} has no live public identity");
    }
    let closed_workspace = transaction
        .query_row(
            "SELECT rw.public_id
             FROM resource_workspaces rw
             LEFT JOIN workspaces w
               ON w.workspace_key = rw.workspace_key AND w.tombstoned = 0
             WHERE rw.deleted_revision IS NULL AND w.workspace_key IS NULL
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(workspace_id) = closed_workspace {
        anyhow::bail!("resource workspace {workspace_id} has no live workspace row");
    }

    let live_workspace_count: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM resource_workspaces WHERE deleted_revision IS NULL",
        [],
        |row| row.get(0),
    )?;
    match meta_value(transaction, "active_workspace_id")? {
        Some(active_workspace) => {
            let live = transaction
                .query_row(
                    "SELECT 1 FROM resource_workspaces
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                    [&active_workspace],
                    |_| Ok(()),
                )
                .optional()?;
            if live.is_none() {
                anyhow::bail!("active workspace {active_workspace} is not live");
            }
        }
        None if live_workspace_count != 0 => {
            anyhow::bail!("live session has workspaces but no active workspace");
        }
        None => {}
    }

    let active_screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id, active_screen_id FROM resource_workspaces
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (workspace_id, screen_id) in active_screens {
        let child_screens =
            resource_children(transaction, "resource_screens", "workspace_id", &workspace_id)?;
        match screen_id {
            Some(screen_id) => {
                let owner = live_resource_field(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    &screen_id,
                )?;
                if owner.as_deref() != Some(workspace_id.as_str()) {
                    anyhow::bail!(
                        "workspace {workspace_id} selects screen {screen_id} owned by {owner:?}"
                    );
                }
            }
            None if !child_screens.is_empty() => {
                anyhow::bail!("workspace {workspace_id} has screens but no active screen");
            }
            None => {}
        }
    }

    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id, workspace_id, layout_json, active_pane_id, zoomed_pane_id,
                    viewport_json
             FROM resource_screens WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, String>(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut expected_splits = HashSet::new();
    for (screen_id, workspace_id, layout_json, active_pane, zoomed_pane, viewport_json) in screens {
        if live_resource_field(transaction, "resource_workspaces", "public_id", &workspace_id)?
            .is_none()
        {
            anyhow::bail!("screen {screen_id} has closed workspace {workspace_id}");
        }
        let layout: RegistryLayoutNode = serde_json::from_str(&layout_json)?;
        let viewport: RegistryViewport = serde_json::from_str(&viewport_json)?;
        let mut layout_panes = HashSet::new();
        let mut layout_splits = HashSet::new();
        validate_layout_node(&layout, &mut layout_panes, &mut layout_splits)?;
        validate_registry_viewport(&viewport, &layout, &layout_panes, &layout_splits)?;
        let layout_panes =
            layout_panes.into_iter().map(ToString::to_string).collect::<HashSet<_>>();
        let stored_panes =
            resource_children(transaction, "resource_panes", "screen_id", &screen_id)?;
        if layout_panes != stored_panes {
            anyhow::bail!("screen {screen_id} layout does not match its live pane rows");
        }
        if !stored_panes.contains(&active_pane)
            || zoomed_pane.as_ref().is_some_and(|pane| !stored_panes.contains(pane))
        {
            anyhow::bail!("screen {screen_id} selects a pane outside its layout");
        }
        let mut screen_splits = Vec::new();
        collect_screen_split_public_ids(&layout, &viewport, &mut screen_splits);
        expected_splits.extend(screen_splits);
    }
    let live_splits = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_identities
             WHERE kind = 'split' AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    if live_splits != expected_splits {
        anyhow::bail!("live split identities do not match persisted screen layouts");
    }

    let panes = {
        let mut statement = transaction.prepare(
            "SELECT public_id, screen_id, active_tab_id FROM resource_panes
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (pane_id, screen_id, active_tab) in panes {
        if live_resource_field(transaction, "resource_screens", "public_id", &screen_id)?.is_none()
        {
            anyhow::bail!("pane {pane_id} has closed screen {screen_id}");
        }
        let child_tabs = resource_children(transaction, "resource_tabs", "pane_id", &pane_id)?;
        match active_tab {
            Some(active_tab) => {
                let owner =
                    live_resource_field(transaction, "resource_tabs", "pane_id", &active_tab)?;
                if owner.as_deref() != Some(pane_id.as_str()) {
                    anyhow::bail!("pane {pane_id} selects tab {active_tab} owned by {owner:?}");
                }
            }
            None if !child_tabs.is_empty() => {
                anyhow::bail!("pane {pane_id} has tabs but no active tab");
            }
            None => {}
        }
    }

    let tabs = {
        let mut statement = transaction.prepare(
            "SELECT public_id, pane_id, content_kind, content_id
             FROM resource_tabs WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (tab_id, pane_id, content_kind, content_id) in tabs {
        if live_resource_field(transaction, "resource_panes", "public_id", &pane_id)?.is_none() {
            anyhow::bail!("tab {tab_id} has closed pane {pane_id}");
        }
        let table = match content_kind.as_str() {
            "terminal" => "resource_terminals",
            "browser" => "resource_browsers",
            other => anyhow::bail!("tab {tab_id} has invalid content kind {other:?}"),
        };
        if live_resource_field(transaction, table, "public_id", &content_id)?.is_none() {
            anyhow::bail!("tab {tab_id} references closed {content_kind} {content_id}");
        }
        let identity_kind = transaction
            .query_row(
                "SELECT kind FROM resource_identities
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [&content_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if identity_kind.as_deref() != Some(content_kind.as_str()) {
            anyhow::bail!("tab {tab_id} content {content_id} has identity kind {identity_kind:?}");
        }
    }

    let terminals = {
        let mut statement = transaction.prepare(
            "SELECT public_id, terminal_id, lifecycle FROM resource_terminals
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (public_id, terminal_id, lifecycle) in terminals {
        if lifecycle != "active" {
            anyhow::bail!("live terminal {public_id} has lifecycle {lifecycle}");
        }
        let placement = read_terminal(transaction, &terminal_id)?;
        if placement
            .as_ref()
            .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned)
        {
            anyhow::bail!("terminal resource {public_id} has no live placement");
        }
    }
    let browsers = {
        let mut statement = transaction.prepare(
            "SELECT public_id, url, metadata_json, lifecycle
             FROM resource_browsers WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (browser_id, url, metadata, lifecycle) in browsers {
        if lifecycle != "running" {
            anyhow::bail!("live browser {browser_id} is not running");
        }
        let metadata =
            metadata.ok_or_else(|| anyhow::anyhow!("browser {browser_id} has no metadata"))?;
        let browser: RegistryBrowser = serde_json::from_str(&metadata)
            .with_context(|| format!("invalid metadata for browser {browser_id}"))?;
        validate_registry_browser(&browser)?;
        if browser.public_id.as_str() != browser_id || browser.url != url {
            anyhow::bail!("browser {browser_id} metadata does not match its indexed fields");
        }
    }
    Ok(())
}

fn validate_concrete_identity_lifecycles(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    for (table, kind) in [
        ("resource_workspaces", "workspace"),
        ("resource_screens", "screen"),
        ("resource_panes", "pane"),
        ("resource_tabs", "tab"),
        ("resource_terminals", "terminal"),
        ("resource_browsers", "browser"),
    ] {
        let query = format!(
            "SELECT r.public_id
             FROM {table} r
             LEFT JOIN resource_identities i ON i.public_id = r.public_id
             WHERE i.public_id IS NULL OR i.kind != ?1
                OR ((r.deleted_revision IS NULL) != (i.deleted_revision IS NULL))
             LIMIT 1"
        );
        let mismatch =
            transaction.query_row(&query, [kind], |row| row.get::<_, String>(0)).optional()?;
        if let Some(public_id) = mismatch {
            anyhow::bail!("{kind} row {public_id} disagrees with its identity ledger");
        }
    }
    Ok(())
}

fn validate_contiguous_positions(
    transaction: &Transaction<'_>,
    query: &str,
    kind: &str,
) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(query)?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut next_by_parent = HashMap::<String, i64>::new();
    for (parent, position) in rows {
        let expected = next_by_parent.entry(parent.clone()).or_default();
        if position != *expected {
            anyhow::bail!(
                "{kind} positions under {parent:?} are not contiguous: expected {}, found {position}",
                *expected
            );
        }
        *expected += 1;
    }
    Ok(())
}

fn upsert_resource_identity(
    transaction: &Transaction<'_>,
    public_id: &str,
    kind: &str,
    revision: i64,
) -> anyhow::Result<()> {
    if let Some((stored_kind, deleted_revision)) = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_kind != kind {
            anyhow::bail!("public id {public_id} has resource kind {stored_kind}, not {kind}");
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned public id cannot be reused: {public_id}");
        }
    }
    transaction.execute(
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET updated_revision=excluded.updated_revision",
        params![public_id, kind, revision],
    )?;
    Ok(())
}

fn ensure_no_foreign_key_violations(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let violation = transaction
        .query_row("PRAGMA foreign_key_check", [], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })
        .optional()?;
    if let Some((table, rowid, parent, index)) = violation {
        anyhow::bail!(
            "resource topology foreign-key violation: table={table} rowid={rowid} parent={parent:?} index={index}"
        );
    }
    Ok(())
}
