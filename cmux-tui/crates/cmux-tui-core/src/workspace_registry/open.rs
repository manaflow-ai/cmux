// Extracted from workspace_registry.rs; this module owns open and initialization.
use super::*;

pub(crate) fn open_registry_database_with_flags(
    path: &Path,
    flags: OpenFlags,
) -> anyhow::Result<Connection> {
    let path = sqlite_filesystem_path(path)?;
    #[cfg(windows)]
    let connection = Connection::open_with_flags_and_vfs(path.as_ref(), flags, "win32-longpath")?;
    #[cfg(not(windows))]
    let connection = Connection::open_with_flags(path.as_ref(), flags)?;
    connection.set_prepared_statement_cache_capacity(REGISTRY_STATEMENT_CACHE_CAPACITY);
    Ok(connection)
}

pub(crate) fn open_registry_database(path: &Path) -> anyhow::Result<Connection> {
    open_registry_database_with_flags(path, OpenFlags::default()).map(registry_connection::hooked)
}

pub(crate) fn open_registry_database_read_only(path: &Path) -> anyhow::Result<Connection> {
    open_registry_database_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
}

impl std::fmt::Debug for WorkspaceRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkspaceRegistry")
            .field("registry_id", &self.registry_id)
            .field("generation", &self.generation)
            .field("session_name", &self.session_name)
            .finish_non_exhaustive()
    }
}

impl WorkspaceRegistry {
    /// The registry id stored for `session_name` under the state root `root`,
    /// read without the session's locks (its owner may be running). `None`:
    /// no registry exists there, so no owner of that state dir is running.
    pub fn stored_registry_id(root: &Path, session_name: &str) -> anyhow::Result<Option<String>> {
        let root = platform::normalize_filesystem_path(root.to_path_buf());
        let db_path = platform::normalize_filesystem_path(
            persistent_session_state_dir(&root, session_name).join(WORKSPACE_REGISTRY_FILE),
        );
        if !db_path.is_file() {
            return Ok(None);
        }
        let connection = open_registry_database_read_only(&db_path)?;
        connection.busy_timeout(std::time::Duration::from_millis(500))?;
        meta_value(&connection, "registry_id")
    }

    /// Fails with `UnsupportedWorkspaceRegistrySchema` when the session's
    /// saved registry needs a newer build, without opening it for writing.
    /// The owner checks this before it binds its socket (cx-n3bs), so the
    /// recovery text still sees whether another server holds the socket.
    pub fn check_supported_schema(root: &Path, session_name: &str) -> anyhow::Result<()> {
        let root = platform::normalize_filesystem_path(root.to_path_buf());
        let session_dir =
            platform::normalize_filesystem_path(root.join(session_storage_component(session_name)));
        let db_path =
            platform::normalize_filesystem_path(session_dir.join(WORKSPACE_REGISTRY_FILE));
        if db_path.is_file()
            && let Some(error) = preflight_unsupported_schema(&db_path)
        {
            return Err(error.into());
        }
        Ok(())
    }

    pub fn in_memory(session_name: &str) -> anyhow::Result<Self> {
        let connection = Connection::open_in_memory()?;
        connection.set_prepared_statement_cache_capacity(REGISTRY_STATEMENT_CACHE_CAPACITY);
        Self::initialize(
            connection,
            session_name.to_string(),
            MachinePublicId::random()?,
            ResourceEffectPepper::random()?,
            &mut None,
            &mut None,
            None,
            crate::startup_timings::StartupTimings::start(),
        )
    }

    pub fn open(root: &Path, session_name: &str) -> anyhow::Result<Self> {
        Self::open_inner(root, session_name, false)
    }

    /// `roll_back_first`: an owner build on a registry swapped in by output
    /// cleanup failed before any full start on it; the previous registry is
    /// put back under this open's locks before the open.
    fn open_inner(root: &Path, session_name: &str, roll_back_first: bool) -> anyhow::Result<Self> {
        let mut timings = crate::startup_timings::StartupTimings::start();
        let root = platform::normalize_filesystem_path(root.to_path_buf());
        // Keep short roots in their existing spelling while giving all
        // root-level files the same long-path handling as their descendants.
        let session_dir =
            platform::normalize_filesystem_path(root.join(session_storage_component(session_name)));
        // Normalize the complete database path. The state root can be below
        // the legacy MAX_PATH threshold while its session and database
        // descendants exceed it.
        let db_path =
            platform::normalize_filesystem_path(session_dir.join(WORKSPACE_REGISTRY_FILE));
        if db_path.is_file()
            && let Some(error) = preflight_unsupported_schema(&db_path)
        {
            return Err(error.into());
        }
        let session_guard = acquire_session_guard(&root, session_name)?;
        let machine_id = load_or_create_machine_id(&root)?;
        let resource_effect_pepper = load_or_create_resource_effect_pepper(&root)?;
        fs::create_dir_all(&session_dir).with_context(|| {
            format!("create workspace state directory {}", session_dir.display())
        })?;
        platform::restrict_directory(&session_dir)?;
        if db_path.is_file()
            && let Some(error) = preflight_unsupported_schema(&db_path)
        {
            return Err(error.into());
        }
        let session_lock =
            platform::normalize_filesystem_path(session_dir.join(SESSION_WRITER_LOCK_FILE));
        let lease = SessionLease::acquire(&session_lock)?;
        // The session's locks: a wait here is an earlier owner still closing.
        timings.lap("registry.session_locks");
        // A rollback an earlier start could not finish goes first.
        output_cleanup::finish_pending_rollback(&db_path)?;
        if roll_back_first && output_cleanup::rollback_possible(&db_path) {
            output_cleanup::roll_back_swap(
                &db_path,
                &anyhow::anyhow!("the owner did not start on the new registry"),
            )?;
        }
        // Before the orphan check: an interrupted swap is put back first.
        // The swap opens the new file through `initialize` and reads its
        // layout before the rename, so a file that cannot serve never
        // replaces the registry.
        let swapped = output_cleanup::swap_at_open(&db_path, &|staged: &Path| {
            let connection = open_registry_database(staged)?;
            let registry = Self::initialize(
                connection,
                session_name.to_string(),
                load_or_create_machine_id(&root)?,
                load_or_create_resource_effect_pepper(&root)?,
                &mut None,
                &mut None,
                None,
                crate::startup_timings::StartupTimings::start(),
            )?;
            registry.snapshot()?;
            Ok(())
        });
        // A swap that failed after it moved the registry aside left only
        // the backup: put it back before anything opens db_path. If that
        // fails, refuse: an open now would create an empty registry beside
        // the only copy of the session.
        output_cleanup::restore_interrupted_swap(&db_path);
        output_cleanup::refuse_open_beside_backup(&db_path)?;
        timings.lap("registry.output_cleanup_swap");
        // The locks stay held across a failed open and its rollback: no
        // other owner can open either file in between.
        let mut session_guard = Some(session_guard);
        let mut lease = Some(lease);
        let mut machine_id = Some(machine_id);
        let mut resource_effect_pepper = Some(resource_effect_pepper);
        let mut open_once = |session_guard: &mut Option<SessionLease>,
                             lease: &mut Option<SessionLease>|
         -> anyhow::Result<Self> {
            open_guard::refuse_orphaned_journal(&db_path)?;
            let connection = open_registry_database(&db_path)
                .with_context(|| format!("open workspace registry {}", db_path.display()))?;
            let connection = open_guard::quarantine_if_unreadable(&db_path, connection)?;
            platform::restrict_file(&db_path)?;
            // A second try (after a rollback) records its own laps.
            let mut timings = std::mem::take(&mut timings);
            timings.lap("registry.lock_and_connect");
            Self::initialize(
                connection,
                session_name.to_string(),
                match machine_id.take() {
                    Some(id) => id,
                    None => load_or_create_machine_id(&root)?,
                },
                match resource_effect_pepper.take() {
                    Some(pepper) => pepper,
                    None => load_or_create_resource_effect_pepper(&root)?,
                },
                session_guard,
                lease,
                Some(db_path.clone()),
                timings,
            )
        };
        #[cfg(debug_assertions)]
        let first =
            if swapped && std::env::var_os("CMUX_TUI_TEST_OUTPUT_CLEANUP_FAIL_OPEN").is_some() {
                Err(anyhow::anyhow!("test: the swapped registry did not open"))
            } else {
                open_once(&mut session_guard, &mut lease)
            };
        #[cfg(not(debug_assertions))]
        let first = open_once(&mut session_guard, &mut lease);
        let registry = match first {
            Ok(mut registry) => {
                // Also true on a later start when the swap start never got
                // through a full start (killed during restore).
                registry.output_cleanup_swapped =
                    swapped || output_cleanup::rollback_possible(&db_path);
                if !registry.output_cleanup_swapped {
                    output_cleanup::remove_previous_registry_when_started(&db_path);
                }
                Ok(registry)
            }
            Err(error) if swapped => {
                // A rollback that cannot put the file back refuses this start.
                output_cleanup::roll_back_swap(&db_path, &error)?;
                open_once(&mut session_guard, &mut lease)
            }
            Err(error) => Err(error),
        }
        .inspect_err(|error| {
            // Still under the session locks: the files of the quarantined
            // registry follow it before the next start can misuse them.
            if let Some(quarantined) = error.downcast_ref::<RegistryQuarantined>() {
                open_guard::keep_with_quarantined(&db_path, quarantined);
            }
        })?;
        // A roster the next build folded beside the previous owner.
        premigrate::adopt(&registry);
        Ok(registry)
    }

    /// Opens the registry and builds the owner from it with `load`. When this
    /// start swapped in a cleaned registry (output cleanup) and `load` fails,
    /// the previous registry is put back under the session locks and `load`
    /// runs once more on it. A full start after a swap is recorded, so the
    /// next start removes the previous file.
    pub(crate) fn open_with<T>(
        root: &Path,
        session_name: &str,
        mut load: impl FnMut(Self) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let registry = Self::open(root, session_name)?;
        let swapped = registry.output_cleanup_swapped;
        let db_path = registry.database_path.clone();
        #[cfg(debug_assertions)]
        let loaded =
            if swapped && std::env::var_os("CMUX_TUI_TEST_OUTPUT_CLEANUP_FAIL_LOAD").is_some() {
                drop(registry);
                Err(anyhow::anyhow!("test: the owner build failed after the swap"))
            } else {
                load(registry)
            };
        #[cfg(not(debug_assertions))]
        let loaded = load(registry);
        match loaded {
            Ok(loaded) => {
                if let Some(db_path) = db_path.as_deref() {
                    output_cleanup::note_full_start(db_path)?;
                }
                Ok(loaded)
            }
            Err(error) if swapped && db_path.is_some() => {
                eprintln!(
                    "cmux-tui: output cleanup: the owner did not start on the new registry: {error:#}"
                );
                // The failed build released its locks with the registry. One
                // open takes them again and holds them through the rollback
                // and the open of the restored registry.
                load(Self::open_inner(root, session_name, true)?)
            }
            Err(error) => Err(error),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn initialize(
        connection: Connection,
        session_name: String,
        machine_id: MachinePublicId,
        resource_effect_pepper: ResourceEffectPepper,
        session_guard: &mut Option<SessionLease>,
        lease: &mut Option<SessionLease>,
        database_path: Option<PathBuf>,
        mut timings: crate::startup_timings::StartupTimings,
    ) -> anyhow::Result<Self> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        // Before the first write, so every commit of this connection uses it.
        connection.execute_batch(REGISTRY_FULLFSYNC_PRAGMA)?;
        let fresh_database = connection.query_row(
            "SELECT COUNT(*) = 0 FROM sqlite_master WHERE type = 'table'",
            [],
            |row| row.get::<_, bool>(0),
        )?;
        if fresh_database {
            connection.execute_batch("PRAGMA auto_vacuum=INCREMENTAL;")?;
        }
        // temp_store=MEMORY: the journal writer applies each intent in a
        // savepoint, and a savepoint journals every page it changes. Past
        // 64 KiB (16 pages, an ordinary terminal write) SQLite spilled that
        // journal to a new file in the temp directory: open, write, unlink
        // and close on every commit, before the reply. In memory, it is
        // bounded by the pages one writer batch changes. VACUUM keeps its
        // whole-database copy on disk ([`vacuum_with_file_temp_store`]).
        connection.execute_batch(
            "PRAGMA foreign_keys=ON;
             PRAGMA journal_mode=WAL;
             PRAGMA synchronous=NORMAL;
             PRAGMA wal_autocheckpoint=1000;
             PRAGMA secure_delete=ON;
             PRAGMA temp_store=MEMORY;
             CREATE TABLE IF NOT EXISTS meta (
               key TEXT PRIMARY KEY NOT NULL,
               value TEXT NOT NULL
             );",
        )?;

        let stored_schema = meta_value(&connection, "schema_version")?;
        let stored_schema = stored_schema
            .as_deref()
            .map(str::parse::<i64>)
            .transpose()
            .context("workspace registry schema is invalid")?;
        // Existing registries may carry the pre-multiview terminal-to-workspace
        // foreign key even when a development build already stamped the
        // current schema number. Revalidate and normalize every existing DB.
        let migrate_existing_registry = stored_schema.is_some();
        if migrate_existing_registry {
            connection.execute_batch("PRAGMA foreign_keys=OFF;")?;
        }
        let cleanup_pending =
            match meta_value(&connection, RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY)?.as_deref() {
                None => false,
                Some("1") => true,
                Some(_) => anyhow::bail!("resource receipt pepper cleanup state is invalid"),
            };
        let needs_sensitive_receipt_cleanup = cleanup_pending
            || stored_schema.is_some_and(|schema| schema < RESOURCE_EFFECT_PEPPER_SCHEMA_VERSION);
        if needs_sensitive_receipt_cleanup {
            connection.execute_batch("PRAGMA secure_delete=ON;")?;
        }
        let resource_effect_pepper_id = resource_effect_pepper.identifier();
        match stored_schema {
            Some(value) if value > SCHEMA_VERSION => {
                return Err(UnsupportedWorkspaceRegistrySchema {
                    found: value,
                    newest_supported: SCHEMA_VERSION,
                    registry_id: meta_value(&connection, "registry_id")?,
                    database_path,
                }
                .into());
            }
            Some(value) if value == SCHEMA_VERSION => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                create_session_journal_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                require_resource_effect_pepper_id(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(9..=14) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(8) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                require_resource_effect_pepper_id(&tx, &resource_effect_pepper_id)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(6) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(7) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                require_resource_effect_pepper_id(&tx, &resource_effect_pepper_id)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(5) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                ensure_session_public_id(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(4) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                ensure_session_public_id(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(3) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                migrate_resource_mutations_to_session_scope(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                create_resource_effect_schema(&tx)?;
                ensure_session_public_id(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(1 | 2) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_resource_effect_schema(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                migrate_resource_agent_projections(&tx)?;
                normalize_journal_multiview_schema(&tx)?;
                terminal_exit_store::migrate_legacy_terminal_exit_receipts(&tx)?;
                migrate_resource_effect_pepper(&tx, &resource_effect_pepper_id)?;
                tx.commit()?;
            }
            Some(value) => {
                anyhow::bail!(
                    "unsupported workspace registry schema {value}; expected 1 through {SCHEMA_VERSION}"
                );
            }
            None => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                create_session_journal_schema(&tx)?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('schema_version', ?1)",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.execute("INSERT INTO meta(key, value) VALUES('revision', '0')", [])?;
                tx.execute("INSERT INTO meta(key, value) VALUES('terminal_revision', '0')", [])?;
                tx.execute("INSERT INTO meta(key, value) VALUES('resource_revision', '0')", [])?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('session_name', ?1)",
                    [&session_name],
                )?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('registry_id', ?1)",
                    [try_new_uuid_v4()?],
                )?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES(?1, ?2)",
                    params![RESOURCE_EFFECT_PEPPER_META_KEY, resource_effect_pepper_id],
                )?;
                ensure_session_public_id(&tx)?;
                tx.commit()?;
            }
        }
        if migrate_existing_registry && resource_tabs_needs_multiview_normalization(&connection)? {
            let tx = connection.unchecked_transaction()?;
            migrate_resource_tabs_to_multiview(&tx)?;
            tx.commit()?;
        }
        timings.lap("registry.schema");
        {
            let tx = connection.unchecked_transaction()?;
            resource_store::migrate_tab_name_authority(&tx)?;
            workspace_name_store::migrate_workspace_name_authority(&tx)?;
            tx.commit()?;
        }
        if terminal_hosts_has_workspace_foreign_key(&connection)? {
            let tx = connection.unchecked_transaction()?;
            migrate_terminal_hosts_to_session_ownership(&tx)?;
            tx.commit()?;
        }
        // Probe the actual table shape instead of the stamped schema number:
        // the column ships without a version bump so older builds keep opening
        // this registry (they omit the column on writes and the durable
        // default applies).
        if !terminal_hosts_has_on_exit_column(&connection)? {
            let tx = connection.unchecked_transaction()?;
            migrate_terminal_hosts_add_on_exit(&tx)?;
            tx.commit()?;
        }
        // Same probe-not-version rule: older builds keep opening the registry
        // and leave the nullable column untouched on their writes.
        if !resource_agent_hook_state_has_ended_at_column(&connection)? {
            let tx = connection.unchecked_transaction()?;
            migrate_resource_agent_hook_state_add_ended_at(&tx)?;
            tx.commit()?;
        }
        timings.lap("registry.migrations.columns");
        if migrate_existing_registry {
            connection.execute_batch("PRAGMA foreign_keys=ON;")?;
        }
        // The one foreign key check of an open, for a new file too. From here
        // foreign keys are on for this connection until the open returns, so
        // SQLite refuses each later write that breaks a key and the topology
        // checks below do not check the keys again.
        if first_state_foreign_key_violation(&connection)?.is_some() {
            anyhow::bail!(
                "saved session data could not be loaded; start a new session or restore this session from a backup"
            );
        }
        timings.lap("registry.migrations.foreign_key_check");
        if needs_sensitive_receipt_cleanup {
            checkpoint_and_truncate_wal(&connection)?;
            vacuum_with_file_temp_store(&connection, "VACUUM;")?;
            checkpoint_and_truncate_wal(&connection)?;
            let tx = connection.unchecked_transaction()?;
            tx.execute(
                "DELETE FROM meta WHERE key = ?1",
                [RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY],
            )?;
            tx.commit()?;
        }
        timings.lap("registry.migrations.receipt_cleanup");
        // Existing registries are migrated by the background journal
        // maintenance worker. VACUUM can rewrite a large cloud registry, so
        // startup only stamps fresh databases that already use incremental
        // auto-vacuum and leaves legacy conversion for availability work after
        // the mux is serving.
        if fresh_database {
            mark_journal_auto_vacuum_migrated(&connection)?;
        }
        let scrubbed;
        {
            let tx = connection.unchecked_transaction()?;
            create_session_journal_schema(&tx)?;
            resource_store::create_lookup_indexes(&tx)?;
            create_resource_effect_schema(&tx)?;
            create_journal_extensions_schema(&tx)?;
            mutation_ledger::migrate_add_actor_columns(&tx)?;
            recover_resource_effects(&tx)?;
            // cx-1a6: no terminal env value rests in the exactly-once receipts.
            scrubbed = receipt_env::scrub_stored_receipts(&tx, &resource_effect_pepper)?;
            initialize_resource_input_receipt_retention(&tx)?;
            initialize_resource_mutation_retention(&tx)?;
            repair_resources_at_open(&tx)?;
            // After the repair: it can tombstone terminals too.
            resource_store::prune_agent_records_of_closed_terminals_at_open(&tx)?;
            public_projection_store::prune_stale_notification_reads_at_open(&tx)?;
            terminal_keep_store::classify_legacy_terminals(&tx)?;
            // Additive: also on a registry a build before the table wrote.
            terminal_unplaced_store::create_terminal_unplaced_schema(&tx)?;
            tx.commit()?;
        }
        if scrubbed {
            // Old page images must not keep the scrubbed values (WAL, main file).
            checkpoint_and_truncate_wal(&connection)?;
        }
        timings.lap("registry.migrations.schema");
        let stored_name = required_meta(&connection, "session_name")?;
        if stored_name != session_name {
            anyhow::bail!(
                "workspace registry belongs to session {stored_name:?}, not {session_name:?}"
            );
        }
        // A registry copied from another machine gets its own ids first.
        let mut rehome = crate::startup_timings::StartupTimings::start();
        host_identity::rehome_registry(&connection, &mut rehome)?;
        timings.absorb(rehome, "registry.migrations.rehome");
        let registry_id = required_meta(&connection, "registry_id")?;
        validate_identifier("registry id", &registry_id)?;
        let session_id = SessionPublicId::parse(required_meta(&connection, "session_public_id")?)?;
        personal_store::migrate_personal_v1(&connection, &registry_id, &session_name)?;
        crate::state::store::migrate_saved_tab_groups_to_personal(&connection)?;
        crate::state::window_record_store::migrate_window_projection(&connection)?;
        // sidebar-doc-v1: once, from the old sidebar stores (which stay).
        // One transaction: a failure rolls it back and is retried at the
        // next open; it never stops the registry from opening (the old
        // stores and verbs keep working without the document).
        if let Err(error) = crate::state::sidebar_doc_store::migrate_at_open(&connection) {
            eprintln!("cmux-tui: sidebar document migration skipped ({error:#})");
        }
        timings.lap("registry.migrations");
        check_registry_integrity(&connection)?;
        timings.lap("registry.integrity_check");
        {
            let tx = connection.unchecked_transaction()?;
            initialize_compatibility_active_workspace(&tx)?;
            validate_resource_invariants(&tx)?;
            tx.commit()?;
        }
        timings.lap("registry.resource_invariants");
        let generation = try_new_uuid_v4()?;
        Ok(Self {
            connection: RegistryConnection::new(connection, database_path.as_deref()),
            database_path,
            open_timings: timings,
            registry_id,
            generation,
            session_name,
            machine_id,
            session_id,
            resource_effect_pepper,
            public_fold: None,
            resource_projection_stats: std::sync::Arc::default(),
            #[cfg(test)]
            resource_patch_failures_remaining: Cell::new(0),
            #[cfg(test)]
            topology_snapshot_failures_remaining: Cell::new(0),
            session_guard: session_guard.take(),
            lease: lease.take(),
            output_cleanup_swapped: false,
        })
    }

    pub(crate) fn session_journal_database_path(&self) -> Option<PathBuf> {
        self.database_path.clone()
    }

    /// This registry's open steps, once (later calls get none).
    pub(crate) fn take_open_timings(&mut self) -> crate::startup_timings::StartupTimings {
        std::mem::take(&mut self.open_timings)
    }

    pub(crate) fn resource_input_receipt_hmac(
        &self,
        idempotency_key: &str,
        operation: &str,
        canonical_fields: &[u8],
    ) -> [u8; 32] {
        self.resource_effect_pepper.input_receipt_hmac(idempotency_key, operation, canonical_fields)
    }
}
