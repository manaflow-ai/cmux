// Extracted from workspace_registry.rs; this module owns schema, migrations, and integrity checks.
use super::*;

pub(super) fn mark_journal_auto_vacuum_migrated(connection: &Connection) -> anyhow::Result<()> {
    connection.execute(
        "INSERT INTO meta(key, value) VALUES(?1, '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [JOURNAL_AUTO_VACUUM_META_KEY],
    )?;
    Ok(())
}

/// A legacy registry is converted to incremental auto-vacuum only while its
/// live data is at most this many bytes. VACUUM rewrites every live page while
/// the caller holds the registry (in WAL mode it writes them all to the WAL):
/// a registry that grew to 10.7 GB without journal maintenance would stall
/// its owner for minutes, so every client read "not connected" (cx-4bd8m).
/// Above the bound the conversion is skipped; sealing still deletes archived
/// journal rows and SQLite reuses their pages, so the file stops growing once
/// sealing keeps up, but it does not shrink. Sealed segments stay in this
/// database, so a large registry may never fall under the bound: giving its
/// free pages back needs a compaction that does not hold the registry.
const LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES: u64 = 64 * 1024 * 1024;

/// Debug builds only: overrides [`LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES`], so
/// behavior tests through the binary need no large fixture.
#[cfg(debug_assertions)]
const LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES_TEST_ENV: &str =
    "CMUX_TUI_TEST_LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES";

fn legacy_auto_vacuum_max_live_bytes() -> u64 {
    #[cfg(debug_assertions)]
    if let Some(bytes) = std::env::var(LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES_TEST_ENV)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
    {
        return bytes;
    }
    LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES
}

/// The registry's live data in bytes: every page but the free ones. Reads
/// only the database header, so it is cheap at any size.
fn registry_live_bytes(connection: &Connection) -> anyhow::Result<u64> {
    let pragma = |name: &str| -> anyhow::Result<u64> {
        let value =
            connection.query_row(&format!("PRAGMA {name}"), [], |row| row.get::<_, i64>(0))?;
        Ok(u64::try_from(value).unwrap_or(0))
    };
    let pages = pragma("page_count")?.saturating_sub(pragma("freelist_count")?);
    Ok(pages.saturating_mul(pragma("page_size")?))
}

/// What [`migrate_journal_auto_vacuum`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AutoVacuumMigration {
    /// Already incremental (now marked), or marked before.
    NotNeeded,
    /// Converted with one full VACUUM.
    Converted,
    /// A legacy registry with this many live bytes, above the bound: not
    /// converted, and asked again on the next call.
    Deferred { live_bytes: u64 },
}

/// Convert registries created before journal maintenance to incremental
/// auto-vacuum once. SQLite applies the auto-vacuum mode change during VACUUM;
/// the marker keeps reopening an existing registry from repeating that work.
/// A legacy registry with live data above [`LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES`]
/// is not converted (`Deferred`).
pub(super) fn migrate_journal_auto_vacuum(
    connection: &Connection,
) -> anyhow::Result<AutoVacuumMigration> {
    if meta_value(connection, JOURNAL_AUTO_VACUUM_META_KEY)?.is_some() {
        return Ok(AutoVacuumMigration::NotNeeded);
    }
    let auto_vacuum = connection.query_row("PRAGMA auto_vacuum", [], |row| row.get::<_, i64>(0))?;
    if auto_vacuum == 2 {
        mark_journal_auto_vacuum_migrated(connection)?;
        return Ok(AutoVacuumMigration::NotNeeded);
    }
    let live_bytes = registry_live_bytes(connection)?;
    if live_bytes > legacy_auto_vacuum_max_live_bytes() {
        return Ok(AutoVacuumMigration::Deferred { live_bytes });
    }
    eprintln!("cmux-tui: migrating session journal to incremental auto-vacuum");
    vacuum_with_file_temp_store(connection, "PRAGMA auto_vacuum=INCREMENTAL; VACUUM;")?;
    mark_journal_auto_vacuum_migrated(connection)?;
    Ok(AutoVacuumMigration::Converted)
}

/// Runs `sql` (a VACUUM) with the temp store on disk, then puts the
/// connection's memory temp store back. VACUUM builds a copy of the whole
/// database in the temp store; the registry connection keeps it in memory
/// for savepoint journals only (see `initialize`).
pub(super) fn vacuum_with_file_temp_store(
    connection: &Connection,
    sql: &str,
) -> anyhow::Result<()> {
    connection.execute_batch("PRAGMA temp_store=FILE;")?;
    let result = connection.execute_batch(sql);
    connection.execute_batch("PRAGMA temp_store=MEMORY;")?;
    Ok(result?)
}

pub(super) fn require_resource_effect_pepper_id(
    transaction: &Transaction<'_>,
    expected: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [RESOURCE_EFFECT_PEPPER_META_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    anyhow::ensure!(
        stored.as_deref() == Some(expected),
        "resource receipt pepper does not match this registry"
    );
    Ok(())
}

pub(super) fn migrate_resource_effect_pepper(
    transaction: &Transaction<'_>,
    identifier: &str,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY],
    )?;
    delete_legacy_sensitive_effect_receipts(transaction)?;
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![RESOURCE_EFFECT_PEPPER_META_KEY, identifier],
    )?;
    transaction.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
        [SCHEMA_VERSION.to_string()],
    )?;
    Ok(())
}

/// Converge the two development schemas which independently used version 9.
///
/// The pre-multiview table has a table-level UNIQUE constraint on
/// `resource_tabs.content_id`; SQLite exposes that constraint as an index with
/// origin `u`. The multiview browser-only partial index has origin `c`, so the
/// distinction survives formatting and index names.
pub(super) fn normalize_journal_multiview_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let legacy_content_identity = {
        let mut indexes = transaction.prepare("PRAGMA index_list(resource_tabs)")?;
        let indexes = indexes
            .query_map([], |row| Ok((row.get::<_, String>(1)?, row.get::<_, String>(3)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        let mut found = false;
        for (name, origin) in indexes {
            if origin != "u" {
                continue;
            }
            let mut columns = transaction.prepare("SELECT name FROM pragma_index_info(?1)")?;
            let columns = columns
                .query_map([name], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            if columns == ["content_id"] {
                found = true;
                break;
            }
        }
        found
    };
    if legacy_content_identity {
        migrate_resource_tabs_to_multiview(transaction)?;
    }
    migrate_resource_events_to_session_journal(transaction)?;
    create_journal_extensions_schema(transaction)?;
    migrate_resource_api_frontend_projection_envelopes(transaction)?;
    Ok(())
}

fn migrate_resource_api_frontend_projection_envelopes(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT subject_key, schema_version, payload
             FROM frontend_projections
             WHERE frontend = 'resource-api' AND scope = 'session'
             ORDER BY subject_key",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (subject_key, schema_version, payload) in rows {
        FrontendProjectionPublicId::parse(subject_key.clone())?;
        if schema_version == i64::from(RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION) {
            continue;
        }
        anyhow::ensure!(
            schema_version == 1,
            "resource API frontend projection {subject_key} has unsupported schema version {schema_version}"
        );
        let projection: Value = serde_json::from_str(&payload).with_context(|| {
            format!("resource API frontend projection {subject_key} contains invalid JSON")
        })?;
        let envelope = serde_json::json!({
            "frontend_id":"legacy-resource-api",
            "window_id":subject_key,
            "generation":"legacy-schema-13",
            "projection":projection,
        });
        let payload = canonical_json(&envelope)?;
        anyhow::ensure!(
            payload.len() <= MAX_RESOURCE_API_PROJECTION_BYTES,
            "migrated resource API frontend projection exceeds {MAX_RESOURCE_API_PROJECTION_BYTES} bytes"
        );
        transaction.execute(
            "UPDATE frontend_projections
             SET schema_version = ?1, payload = ?2
             WHERE frontend = 'resource-api' AND scope = 'session' AND subject_key = ?3",
            params![
                i64::from(RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION),
                payload,
                subject_key,
            ],
        )?;
    }
    Ok(())
}

/// Tables that hold journal history rather than registry state. They grow
/// with every terminal output chunk (millions of rows, gigabytes on a
/// long-lived machine) and are append-only or sealed archives whose records
/// are validated when they are read, so the open-time check skips them.
const JOURNAL_HISTORY_TABLES: [&str; 8] = [
    "session_journal",
    "journal_subject_index",
    "journal_event_index",
    "journal_segments",
    "journal_checkpoints",
    "journal_content_blobs",
    "journal_segment_kinds",
    "journal_segment_reducer_records",
];

/// Idempotency ledgers: one row per committed mutation, holding its result
/// for a retry of the same `(origin, mutation_id)`. They are read only by
/// that key and could reach 1 GB (a nightly's `projection_mutations`), so the
/// open-time check skips them like journal history and touches their newest
/// row and key instead; the maintenance worker bounds and scans them
/// (`mutation_ledger_retention`).
/// `resource_mutations` is not one of them: it is pruned on open and its
/// terminal-defaults rows are restored state.
const MUTATION_LEDGER_TABLES: [&str; 3] =
    ["mutations", "projection_mutations", "terminal_mutations"];

/// Journal receipt ledgers: one row per accepted ingress append, read only
/// by its `(producer, origin, idempotency key)` for a retry. A long-lived
/// machine holds hundreds of thousands (588k, about 5.5 s of a cold
/// quick_check on a 41 GB nightly registry), so the open-time checks skip
/// them like the mutation ledgers.
const RECEIPT_LEDGER_TABLES: [&str; 1] = ["journal_ingress_receipts"];

/// Tables the open-time checks leave alone: journal history, idempotency
/// ledgers and quarantined ledgers grow with use and are validated when read.
fn skipped_by_open_check(table: &str) -> bool {
    JOURNAL_HISTORY_TABLES.contains(&table)
        || MUTATION_LEDGER_TABLES.contains(&table)
        || RECEIPT_LEDGER_TABLES.contains(&table)
        || mutation_ledger_retention::is_quarantined_ledger(table)
}

/// One `PRAGMA foreign_key_check` row: `(table, rowid, parent, foreign key index)`.
pub(crate) type ForeignKeyViolation = (String, i64, Option<String>, i64);

#[cfg(test)]
thread_local! {
    static STATE_FOREIGN_KEY_CHECKS: Cell<usize> = const { Cell::new(0) };
}

/// Calls of [`first_state_foreign_key_violation`] on this thread (test hook).
#[cfg(test)]
pub(crate) fn state_foreign_key_checks_on_this_thread() -> usize {
    STATE_FOREIGN_KEY_CHECKS.with(Cell::get)
}

/// The first row of a registry state table whose foreign key names a missing
/// parent: `(table, rowid, parent, foreign key index)`. The open migrates
/// the state tables of an existing file with foreign keys off, so it checks
/// them once, after the migrations, when foreign keys are on again; an
/// unscoped `PRAGMA foreign_key_check` also walked every receipt ledger
/// (about 4 s cold on a 41 GB registry) while the daemon's socket waited.
pub(crate) fn first_state_foreign_key_violation(
    connection: &Connection,
) -> anyhow::Result<Option<ForeignKeyViolation>> {
    #[cfg(test)]
    STATE_FOREIGN_KEY_CHECKS.with(|checks| checks.set(checks.get() + 1));
    let tables = {
        let mut statement = connection.prepare(
            "SELECT DISTINCT m.name FROM sqlite_master AS m, pragma_foreign_key_list(m.name)
             WHERE m.type = 'table' ORDER BY m.name",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    for table in tables.iter().filter(|table| !skipped_by_open_check(table.as_str())) {
        let query = format!(
            "SELECT \"table\", rowid, parent, fkid FROM pragma_foreign_key_check('{}') LIMIT 1",
            table.replace('\'', "''")
        );
        let violation = connection
            .query_row(&query, [], |row| {
                let rowid = row.get::<_, Option<i64>>(1)?.unwrap_or_default();
                Ok((row.get(0)?, rowid, row.get(2)?, row.get(3)?))
            })
            .optional()?;
        if violation.is_some() {
            return Ok(violation);
        }
    }
    Ok(None)
}

/// Structural check of the registry state on open. An unscoped quick_check
/// reads every page of the file, so its cost tracked total journal history;
/// checking each state table and its indexes keeps startup proportional to
/// the registry, not to how much output its terminals ever printed.
pub(super) fn check_registry_integrity(connection: &Connection) -> anyhow::Result<()> {
    let tables = {
        let mut statement = connection.prepare(
            "SELECT name FROM sqlite_master
             WHERE type = 'table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
             ORDER BY name",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    // The tables that grow with use are checked in full by the maintenance
    // worker after the daemon serves, unless it found one damaged
    // (`history_check`).
    let full = history_check::full_open_check_required(connection)?;
    for table in tables.iter().filter(|table| {
        !skipped_by_open_check(table.as_str())
            && (full || !history_check::is_background_checked(table.as_str()))
    }) {
        let pragma = format!("PRAGMA quick_check('{}')", table.replace('\'', "''"));
        let result: String = connection.query_row(&pragma, [], |row| row.get(0))?;
        if result != "ok" {
            anyhow::bail!("workspace registry integrity check failed: {result}");
        }
    }
    if full {
        connection.execute(
            "DELETE FROM meta WHERE key = ?1",
            [history_check::FULL_OPEN_CHECK_META_KEY],
        )?;
    } else {
        history_check::touch_background_checked_tails(connection, &tables)?;
    }
    // History is validated incrementally when replayed. Touch only each
    // table's newest indexed row during open so a corrupt tail page is caught
    // without turning startup back into a full-journal scan.
    for (table, order) in [
        ("session_journal", "sequence"),
        ("journal_subject_index", "sequence"),
        ("journal_event_index", "sequence"),
        ("journal_segments", "end_sequence"),
        ("journal_checkpoints", "source_sequence"),
        // created_at_ms has no index: ordering by it scanned and sorted every
        // blob through its overflow pages (0.67 s cold on a 41.6 GB registry).
        // Blobs are append-only, so the newest rowid is the newest blob.
        ("journal_content_blobs", "rowid"),
    ] {
        let query = format!("SELECT 1 FROM {table} ORDER BY {order} DESC LIMIT 1");
        let _: Option<i64> = connection.query_row(&query, [], |row| row.get(0)).optional()?;
    }
    for table in MUTATION_LEDGER_TABLES {
        if !tables.iter().any(|name| name.as_str() == table) {
            continue;
        }
        for order in ["rowid DESC", "origin DESC, mutation_id DESC"] {
            let query = format!("SELECT 1 FROM {table} ORDER BY {order} LIMIT 1");
            let _: Option<i64> = connection.query_row(&query, [], |row| row.get(0)).optional()?;
        }
    }
    // The receipt ledgers likewise: their newest row and newest key.
    for table in RECEIPT_LEDGER_TABLES {
        if !tables.iter().any(|name| name.as_str() == table) {
            continue;
        }
        for order in ["rowid DESC", "producer_id DESC, origin DESC, idempotency_key DESC"] {
            let query = format!("SELECT 1 FROM {table} ORDER BY {order} LIMIT 1");
            let _: Option<i64> = connection.query_row(&query, [], |row| row.get(0)).optional()?;
        }
    }
    Ok(())
}

pub(super) fn checkpoint_and_truncate_wal(connection: &Connection) -> anyhow::Result<()> {
    let (busy, _, _): (i64, i64, i64) =
        connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?;
    anyhow::ensure!(busy == 0, "resource receipt cleanup could not truncate the SQLite WAL");
    Ok(())
}

pub(super) fn create_workspace_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    presentation_store::create_presentation_schema(transaction)?;
    screen_store::create_screen_schema(transaction)?;
    crate::state::store::create_state_schema(transaction)?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
           workspace_key TEXT PRIMARY KEY NOT NULL,
           numeric_id INTEGER UNIQUE NOT NULL,
           name TEXT NOT NULL,
           group_key TEXT NOT NULL,
           position INTEGER,
           tombstoned INTEGER NOT NULL DEFAULT 0 CHECK(tombstoned IN (0,1)),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_workspace_position
           ON workspaces(position) WHERE tombstoned = 0;
         CREATE TABLE IF NOT EXISTS mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );
         CREATE TABLE IF NOT EXISTS workspace_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           result_json TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS frontend_projections (
           frontend TEXT NOT NULL,
           scope TEXT NOT NULL,
           subject_key TEXT NOT NULL,
           schema_version INTEGER NOT NULL,
           projection_revision INTEGER NOT NULL,
           payload TEXT NOT NULL,
           PRIMARY KEY(frontend, scope, subject_key)
         );
         CREATE TABLE IF NOT EXISTS projection_mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );",
    )?;
    Ok(())
}

pub(super) fn create_terminal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let legacy_exists: bool = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master
           WHERE type = 'table' AND name = 'terminal_placements'
         )",
        [],
        |row| row.get(0),
    )?;
    let hosts_exist: bool = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master
           WHERE type = 'table' AND name = 'terminal_hosts'
         )",
        [],
        |row| row.get(0),
    )?;
    anyhow::ensure!(
        !(legacy_exists && hosts_exist),
        "workspace registry contains both legacy terminal placements and terminal hosts"
    );
    if legacy_exists {
        transaction.execute_batch("ALTER TABLE terminal_placements RENAME TO terminal_hosts;")?;
    }
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_hosts (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           workspace_key TEXT NOT NULL,
           incarnation TEXT,
           lifecycle TEXT NOT NULL CHECK(
             lifecycle IN ('launching','adopting','running','exited','tombstoned')
           ),
           launch_spec_json TEXT NOT NULL,
           exit_json TEXT,
           on_exit TEXT NOT NULL DEFAULT 'close' CHECK(on_exit IN ('close','keep')),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS terminal_incarnation
           ON terminal_hosts(incarnation) WHERE incarnation IS NOT NULL;
         CREATE INDEX IF NOT EXISTS live_terminals_by_workspace
           ON terminal_hosts(workspace_key, updated_revision)
           WHERE lifecycle != 'tombstoned';
         CREATE TABLE IF NOT EXISTS terminal_mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );
         CREATE TABLE IF NOT EXISTS terminal_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           terminal_id TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           result_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS terminal_events_by_terminal
           ON terminal_events(terminal_id, revision);",
    )?;
    idle_policy_store::create_terminal_idle_policy_schema(transaction)?;
    terminal_keep_store::create_terminal_keep_schema(transaction)?;
    terminal_unplaced_store::create_terminal_unplaced_schema(transaction)?;
    terminal_resume_store::create_terminal_resume_schema(transaction)?;
    relaunch_store::create_schema(transaction)?;
    Ok(())
}

pub(super) fn terminal_hosts_has_workspace_foreign_key(
    connection: &Connection,
) -> anyhow::Result<bool> {
    let mut statement = connection.prepare("PRAGMA foreign_key_list(terminal_hosts)")?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        let table = row.get::<_, String>(2)?;
        let from = row.get::<_, String>(3)?;
        if table == "workspaces" && from == "workspace_key" {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn terminal_hosts_has_on_exit_column(connection: &Connection) -> anyhow::Result<bool> {
    let mut statement = connection.prepare("PRAGMA table_info(terminal_hosts)")?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        if row.get::<_, String>(1)? == "on_exit" {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn resource_agent_hook_state_has_ended_at_column(
    connection: &Connection,
) -> anyhow::Result<bool> {
    let mut statement = connection.prepare("PRAGMA table_info(resource_agent_hook_state)")?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        if row.get::<_, String>(1)? == "ended_at_ms" {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Add the hook fence's incarnation boundary to registries created before
/// the column existed. Existing fences have no known boundary (NULL), which
/// lets a same-id `SessionStart` resume an ended session.
pub(super) fn migrate_resource_agent_hook_state_add_ended_at(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "ALTER TABLE resource_agent_hook_state ADD COLUMN ended_at_ms INTEGER
           CHECK(ended_at_ms IS NULL OR ended_at_ms >= 0);",
    )?;
    Ok(())
}

/// Add the per-terminal exit policy to registries created before the column
/// existed. Every pre-existing terminal keeps today's close-on-exit behavior.
pub(super) fn migrate_terminal_hosts_add_on_exit(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "ALTER TABLE terminal_hosts ADD COLUMN on_exit TEXT NOT NULL DEFAULT 'close'
           CHECK(on_exit IN ('close','keep'));",
    )?;
    Ok(())
}

/// Remove the legacy ownership edge from terminals to workspaces. The
/// workspace key remains useful placement history, but terminal lifetime is
/// session-owned and therefore survives removal of every view.
pub(super) fn migrate_terminal_hosts_to_session_ownership(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "DROP INDEX IF EXISTS terminal_incarnation;
         DROP INDEX IF EXISTS live_terminals_by_workspace;
         CREATE TABLE terminal_hosts_session_owned (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           workspace_key TEXT NOT NULL,
           incarnation TEXT,
           lifecycle TEXT NOT NULL CHECK(
             lifecycle IN ('launching','adopting','running','exited','tombstoned')
           ),
           launch_spec_json TEXT NOT NULL,
           exit_json TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         INSERT INTO terminal_hosts_session_owned(
           terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
           exit_json, created_revision, updated_revision, deleted_revision
         )
         SELECT terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
                exit_json, created_revision, updated_revision, deleted_revision
         FROM terminal_hosts;
         DROP TABLE terminal_hosts;
         ALTER TABLE terminal_hosts_session_owned RENAME TO terminal_hosts;
         CREATE UNIQUE INDEX terminal_incarnation
           ON terminal_hosts(incarnation) WHERE incarnation IS NOT NULL;
         CREATE INDEX live_terminals_by_workspace
           ON terminal_hosts(workspace_key, updated_revision)
           WHERE lifecycle != 'tombstoned';",
    )?;
    Ok(())
}

pub(super) fn ensure_session_public_id(
    transaction: &Transaction<'_>,
) -> anyhow::Result<SessionPublicId> {
    let stored = transaction
        .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    if let Some(stored) = stored {
        return Ok(SessionPublicId::parse(stored)?);
    }
    let session_id = SessionPublicId::random()?;
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES('session_public_id', ?1)",
        [session_id.as_str()],
    )?;
    Ok(session_id)
}

pub(super) fn backfill_workspace_public_ids(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT workspace_key, created_revision, updated_revision, deleted_revision
             FROM workspaces
             WHERE workspace_key NOT IN (SELECT workspace_key FROM resource_workspaces)
               AND NOT EXISTS (
                 SELECT 1
                 FROM resource_creation_receipts creation
                 WHERE creation.execution_kind = 'effect'
                   AND creation.state = 'executing'
                   AND json_extract(
                         creation.intent_json,
                         '$.workspace_reservation.workspace_key'
                       ) = workspaces.workspace_key
               )
             ORDER BY created_revision ASC, workspace_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (workspace_key, created_revision, updated_revision, deleted_revision) in rows {
        let public_id = WorkspacePublicId::random()?;
        transaction.execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'workspace', ?2, ?3, ?4)",
            params![public_id.as_str(), created_revision, updated_revision, deleted_revision],
        )?;
        transaction.execute(
            "INSERT INTO resource_workspaces(
               public_id, workspace_key, active_screen_id,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, NULL, ?3, ?4, ?5)",
            params![
                public_id.as_str(),
                workspace_key,
                created_revision,
                updated_revision,
                deleted_revision
            ],
        )?;
    }
    Ok(())
}

/// Seed the shared compatibility default after legacy workspace backfill.
///
/// Frontends keep their actual focus in client-local state. The registry still
/// exposes one default for legacy commands and initial placement, and older
/// registries can have live public workspaces without that metadata. Preserve
/// any stored value so invariant validation still rejects dangling selections.
pub(super) fn initialize_compatibility_active_workspace(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    if meta_value(transaction, "active_workspace_id")?.is_some() {
        return Ok(());
    }
    let active_workspace = transaction
        .query_row(
            "SELECT rw.public_id
             FROM workspaces w
             JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
             WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
             ORDER BY w.position ASC, w.workspace_key ASC
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(active_workspace) = active_workspace {
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)",
            [active_workspace],
        )?;
    }
    Ok(())
}

pub(super) fn upsert_workspace_resource(
    transaction: &Transaction<'_>,
    workspace: &RegistryWorkspace,
    revision: i64,
) -> anyhow::Result<()> {
    if transaction
        .query_row(
            "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        == Some(1)
    {
        anyhow::bail!("tombstoned workspace key cannot be reused: {}", workspace.key);
    }
    if let Some((stored_id, deleted_revision)) = transaction
        .query_row(
            "SELECT public_id, deleted_revision
             FROM resource_workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_id != workspace.public_id.as_str() {
            anyhow::bail!(
                "workspace key {} is already bound to public id {}",
                workspace.key,
                stored_id
            );
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    if let Some((stored_key, deleted_revision)) = transaction
        .query_row(
            "SELECT workspace_key, deleted_revision
             FROM resource_workspaces WHERE public_id = ?1",
            [workspace.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_key != workspace.key {
            anyhow::bail!(
                "workspace public id {} is already bound to key {}",
                workspace.public_id,
                stored_key
            );
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    if let Some((kind, deleted_revision)) = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [workspace.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if kind != "workspace" {
            anyhow::bail!("public id {} has resource kind {kind}", workspace.public_id);
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    transaction.execute(
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, 'workspace', ?2, ?2, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           updated_revision=excluded.updated_revision",
        params![workspace.public_id.as_str(), revision],
    )?;
    transaction.execute(
        "INSERT INTO resource_workspaces(
           public_id, workspace_key, active_screen_id,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, NULL, ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           updated_revision=excluded.updated_revision",
        params![workspace.public_id.as_str(), workspace.key, revision],
    )?;
    Ok(())
}

pub(super) fn normalized_workspace_resource_deltas(
    session_id: &SessionPublicId,
    workspaces: &[RegistryWorkspace],
    active_workspace: Option<&str>,
    before: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let mut deltas = workspaces
        .iter()
        .enumerate()
        .map(|(index, workspace)| {
            Ok(serde_json::json!({
                "kind":"upsert",
                "sequence":index,
                "resource":"workspace",
                "id":workspace.public_id,
                "value":{
                    "id":workspace.public_id,
                    "session_id":session_id,
                    "name":workspace.name,
                    "index":u32::try_from(index)
                        .context("workspace index exceeds public uint32 range")?,
                    "focused":active_workspace == Some(workspace.public_id.as_str()),
                    "extra":crate::resource_name::workspace_name_extra(
                        workspace.name_source,
                        workspace.name_revision,
                    ),
                },
            }))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let live_workspaces =
        workspaces.iter().map(|workspace| workspace.public_id.clone()).collect::<HashSet<_>>();
    let removed_workspaces = before
        .active_screens
        .iter()
        .filter(|(workspace, _)| !live_workspaces.contains(workspace))
        .map(|(workspace, _)| workspace.clone())
        .collect::<Vec<_>>();
    workspace_commit_intent::push_focus_move_upserts(
        &mut deltas,
        before,
        &live_workspaces,
        active_workspace,
    )?;
    let removed_workspace_ids = removed_workspaces.iter().cloned().collect::<HashSet<_>>();
    let removed_screens = before
        .screens
        .iter()
        .filter(|screen| removed_workspace_ids.contains(&screen.workspace_id))
        .map(|screen| screen.public_id.clone())
        .collect::<Vec<_>>();
    let removed_screen_ids = removed_screens.iter().cloned().collect::<HashSet<_>>();
    let removed_panes = before
        .panes
        .iter()
        .filter(|pane| removed_screen_ids.contains(&pane.screen_id))
        .map(|pane| pane.public_id.clone())
        .collect::<Vec<_>>();
    let removed_pane_ids = removed_panes.iter().cloned().collect::<HashSet<_>>();
    let removed_tabs = before
        .tabs
        .iter()
        .filter(|tab| removed_pane_ids.contains(&tab.pane_id))
        .collect::<Vec<_>>();
    let mut push_delete = |resource: &str, id: &str| {
        let sequence = deltas.len();
        deltas.push(serde_json::json!({
            "kind":"delete",
            "sequence":sequence,
            "resource":resource,
            "id":id,
        }));
    };
    for tab in &removed_tabs {
        match &tab.content_id {
            ContentPublicId::Terminal(id) => push_delete("terminal", id.as_str()),
            ContentPublicId::Browser(id) => push_delete("browser", id.as_str()),
        }
        push_delete("tab", tab.public_id.as_str());
    }
    for pane in &removed_panes {
        push_delete("pane", pane.as_str());
    }
    for screen in &removed_screens {
        push_delete("screen", screen.as_str());
    }
    for workspace in &removed_workspaces {
        push_delete("workspace", workspace.as_str());
    }
    Ok(Value::Array(deltas))
}
