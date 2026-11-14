use super::*;

const SESSION: &str = "clone-check";
/// Columns that hold a session id as their whole value.
const SESSION_ID_COLUMNS: [&str; 2] = ["session_id", "default_session_id"];
const TERMINAL: &str = "00000000000040008000000000000001";

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-host-identity-{label}-{}", new_uuid_v4()))
}

fn as_machine(raw: Option<&str>) {
    TEST_OS_IDENTITY.with(|cell| *cell.borrow_mut() = Some(raw.map(str::to_string)));
}

/// (registry id, session public id, machine id) after an open on `root`.
fn ids(root: &Path) -> (String, String, String) {
    let registry = WorkspaceRegistry::open(root, SESSION).unwrap();
    let ids = (
        registry.registry_id().to_string(),
        registry.session_id().as_str().to_string(),
        registry.machine_id().as_str().to_string(),
    );
    drop(registry);
    ids
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            fs::copy(entry.path(), target).unwrap();
        }
    }
}

fn registry_file(root: &Path) -> PathBuf {
    persistent_session_state_dir(root, SESSION).join(WORKSPACE_REGISTRY_FILE)
}

/// Every session-id column (whole value) of a mutable table that holds
/// `needle`, as table.column.
fn session_columns_naming(root: &Path, needle: &str) -> Vec<String> {
    let connection = Connection::open(registry_file(root)).unwrap();
    let mut found = Vec::new();
    for (table, columns) in mutable_columns(&connection).unwrap() {
        for column in columns.iter().filter(|c| SESSION_ID_COLUMNS.contains(&c.as_str())) {
            let hits: i64 = connection
                .query_row(
                    &format!(
                        "SELECT COUNT(*) FROM {} WHERE {} = ?1",
                        quote_identifier(&table),
                        quote_identifier(column),
                    ),
                    [needle],
                    |row| row.get(0),
                )
                .unwrap();
            if hits > 0 {
                found.push(format!("{table}.{column}"));
            }
        }
    }
    found
}

/// Free text that holds the id (a command, a path) and a JSON record that
/// names the session, as user data and a reference would.
fn plant(root: &Path, id: &str) {
    Connection::open(registry_file(root))
        .unwrap()
        .execute_batch(&format!(
            "CREATE TABLE user_text(command TEXT, record_json TEXT);
                 INSERT INTO user_text VALUES('cd /srv/{id} && ls',
                   '{{\"command\":\"echo {id}\",\"ref\":{{\"session_id\":\"{id}\"}}}}');"
        ))
        .unwrap();
}

fn planted(root: &Path) -> (String, Value) {
    Connection::open(registry_file(root))
        .unwrap()
        .query_row("SELECT command, record_json FROM user_text", [], |row| {
            Ok((row.get(0)?, serde_json::from_str(&row.get::<_, String>(1)?).unwrap()))
        })
        .unwrap()
}

/// A customised sidebar on `session`'s machine section: renamed, with a
/// group holding the workspace's item. Returns the group's id.
fn customize_sidebar(root: &Path, session: &str) -> String {
    use cmux_layout_reducer::sidebar_doc::{
        Body, NewItem, Op, Patch, SectionPatch, Target, WorkspaceRef, machine_section_id, reduce,
    };
    let connection = Connection::open(registry_file(root)).unwrap();
    let tx = connection.unchecked_transaction().unwrap();
    let section = machine_section_id(session);
    let workspace: String = tx
        .query_row(
            "SELECT public_id FROM resource_workspaces WHERE workspace_key = 'one'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let group = "itm_custom_group".to_string();
    crate::state::sidebar_doc_store::with_doc_mut(&tx, |doc| {
        assert!(doc.section(&section).is_some(), "the machine section exists");
        let placed = doc.items_unordered().find_map(|item| match &item.body {
            Body::Workspace { reference } if reference.session_id == session => {
                Some(item.id.clone())
            }
            _ => None,
        });
        let mut ops = Vec::new();
        let item = placed.unwrap_or_else(|| {
            let id = format!("itm_w_{session}_{workspace}");
            ops.push(Op::ItemAdd {
                item: NewItem {
                    id: Some(id.clone()),
                    body: Body::Workspace { reference: WorkspaceRef::new(session, &workspace) },
                    shows_label: true,
                    span: None,
                    extra: Default::default(),
                },
                to: Target::end(&section),
            });
            id
        });
        ops.push(Op::SectionUpdate {
            id: section.clone(),
            patch: SectionPatch { title: Patch::Set("Renamed".into()), ..Default::default() },
        });
        ops.push(Op::GroupCreate {
            id: Some(group.clone()),
            name: "Custom".into(),
            color: None,
            icon: None,
            profile: None,
            items: vec![item],
            to: Some(Target::end(&section)),
        });
        let previous = doc.revision;
        let applied =
            reduce::apply_in_place(doc, &ops, &mut crate::state::sidebar_doc_legacy::mint_item_id)
                .map_err(|refusal| anyhow::anyhow!("{}", refusal.as_str()))?;
        crate::state::sidebar_doc_store::write_changes(
            &tx,
            previous,
            doc.revision,
            &applied.changes,
            None,
        )?;
        Ok(())
    })
    .unwrap();
    tx.commit().unwrap();
    group
}

/// The machine section of `session` after an open: (title, the group's
/// section, the sessions of the workspaces under the group).
fn sidebar_of(root: &Path, session: &str, group: &str) -> (Option<String>, String, Vec<String>) {
    use cmux_layout_reducer::sidebar_doc::machine_section_id;
    drop(WorkspaceRegistry::open(root, SESSION).unwrap());
    let connection = Connection::open(registry_file(root)).unwrap();
    crate::state::sidebar_doc_store::with_doc(&connection, |doc| {
        let section = doc
            .section(&machine_section_id(session))
            .unwrap_or_else(|| panic!("no machine section for {session}"));
        let group_item = doc
            .items_unordered()
            .find(|item| item.id == group)
            .unwrap_or_else(|| panic!("group {group} is gone"));
        let members = doc
            .items_unordered()
            .filter(|item| item.parent.as_deref() == Some(group))
            .filter_map(|item| item.body.workspace().map(|r| r.session_id.clone()))
            .collect();
        Ok((section.title.clone(), group_item.section.clone(), members))
    })
    .unwrap()
}

/// A registry in use: a workspace and a terminal, so the session journal
/// and its append-only triggers hold rows naming the session.
fn seed(root: &Path) {
    let mut registry = WorkspaceRegistry::open(root, SESSION).unwrap();
    super::super::tests::seed_workspace(&mut registry, "one");
    super::super::tests::reserve_terminal(&mut registry, TERMINAL, 0);
    drop(registry);
}

fn own_session_row(root: &Path, registry_id: &str) -> bool {
    Connection::open(registry_file(root))
        .unwrap()
        .prepare("SELECT 1 FROM sessions WHERE session_id = ?1")
        .unwrap()
        .exists([registry_id])
        .unwrap()
}

#[test]
fn a_home_copied_to_another_machine_mints_new_registry_and_machine_ids_and_the_same_machine_keeps_them()
 {
    let first = "0123456789abcdef0123456789abcdef";
    let second = "fedcba9876543210fedcba9876543210";
    let original = temp_root("original");
    as_machine(Some(first));
    seed(&original);
    let made = ids(&original);
    plant(&original, &made.0);
    let group = customize_sidebar(&original, &made.0);
    let (title, _, members) = sidebar_of(&original, &made.0, &group);
    assert_eq!(title.as_deref(), Some("Renamed"));
    assert_eq!(members.len(), 1, "the group holds the workspace");
    assert_eq!(ids(&original), made, "the same machine keeps its ids");

    // VMs made from one image: the whole state root, under another machine id.
    let clone = temp_root("clone");
    copy_tree(&original, &clone);
    as_machine(Some(second));
    let cloned = ids(&clone);
    assert_ne!(cloned.0, made.0, "registry id");
    assert_eq!(cloned.1, made.1, "the session public id stays: the journal records it");
    assert_ne!(cloned.2, made.2, "machine id");
    let stale = session_columns_naming(&clone, &made.0);
    assert!(stale.is_empty(), "session columns still name the copied id: {stale:?}");
    let (command, record) = planted(&clone);
    assert_eq!(command, format!("cd /srv/{} && ls", made.0), "free text is kept");
    assert_eq!(record["command"], format!("echo {}", made.0), "free text in JSON is kept");
    assert_eq!(record["ref"]["session_id"], cloned.0, "a JSON session ref moves");
    // The customised sidebar survives the rehome and the open's repair.
    let (title, group_section, members) = sidebar_of(&clone, &cloned.0, &group);
    assert_eq!(title.as_deref(), Some("Renamed"), "the section keeps its name");
    assert_eq!(
        group_section,
        cmux_layout_reducer::sidebar_doc::machine_section_id(&cloned.0),
        "the group stays in the machine section"
    );
    assert_eq!(members, vec![cloned.0.clone()], "the placement moves with the session");
    let reopened = WorkspaceRegistry::open(&clone, SESSION).unwrap();
    assert_eq!(reopened.snapshot().unwrap().workspaces[0].key, "one", "the workspaces stay");
    drop(reopened);
    assert!(own_session_row(&clone, &cloned.0), "the own personal session moved to the new id");
    assert_eq!(ids(&clone), cloned, "minted once: the clone keeps its new ids");

    // The machine the image was made of is untouched.
    as_machine(Some(first));
    assert_eq!(ids(&original), made);
    for root in [original, clone] {
        fs::remove_dir_all(root).unwrap();
    }
}

fn bound_at(at: Option<SystemTime>) {
    TEST_IDENTITY_BOUND_AT.with(|cell| *cell.borrow_mut() = at);
}

/// The Freestyle lane template was made before the stamp existed: its
/// forks kept its registry id and stamped it as their own, so twelve lane
/// VMs answered with one id (2026-11-02/03). A cmux Cloud machine whose
/// instance id was bound after its unstamped home was made mints new ids;
/// one bound before keeps them.
#[test]
fn an_unstamped_home_made_before_this_cloud_machine_was_bound_mints_new_ids() {
    let template = temp_root("template");
    as_machine(None);
    seed(&template);
    let made = ids(&template);
    assert!(!template.join(HOST_STAMP_FILE).exists(), "made before the stamp");
    let registry = File::open(registry_file(&template)).unwrap();
    if file_birth::birth_ns(&registry).is_none() {
        eprintln!("skipped: this file system records no creation time");
        fs::remove_dir_all(template).unwrap();
        return;
    }

    // A fork: the supervisor binds its new instance id after the files it inherited.
    let fork = temp_root("fork");
    copy_tree(&template, &fork);
    as_machine(Some("cmux-instance:i-fork"));
    bound_at(Some(SystemTime::now() + std::time::Duration::from_secs(3_600)));
    let forked = ids(&fork);
    assert_ne!(forked.0, made.0, "registry id");
    assert_ne!(forked.2, made.2, "machine id");
    assert!(own_session_row(&fork, &forked.0), "the own personal session moved");
    assert_eq!(ids(&fork), forked, "minted once: the fork is stamped now");

    // A machine bound before its home was made is the machine that made it.
    let own = temp_root("bound-first");
    copy_tree(&template, &own);
    as_machine(Some("cmux-instance:i-own"));
    bound_at(Some(SystemTime::UNIX_EPOCH));
    assert_eq!(ids(&own), made);
    for root in [template, fork, own] {
        fs::remove_dir_all(root).unwrap();
    }
}

/// A journal hook whose id happens to be the registry id, with a
/// delivery: the rehome leaves the deliveries (journal history) alone,
/// so it must leave the hook too, or the delivery's foreign key names a
/// hook that is gone and the copied registry does not open.
#[test]
fn a_hook_named_like_the_registry_keeps_its_deliveries_after_a_rehome() {
    let root = temp_root("rehome-hook");
    as_machine(Some("0123456789abcdef0123456789abcdef"));
    let copied = ids(&root).0;
    {
        let connection = Connection::open(registry_file(&root)).unwrap();
        connection
            .execute(
                "INSERT INTO journal_hooks(
                       hook_id, manifest_version, manifest_json, enabled, cursor_sequence,
                       installed_at_ms
                     ) VALUES(?1, 1, json_object('id', ?1), 0, 0, 1)",
                [&copied],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO journal_hook_deliveries(
                       hook_id, manifest_version, event_id, event_sequence, attempt, state,
                       next_attempt_at_ms, scheduled_at_ms
                     ) VALUES(?1, 1, 'event_hooked', 1, 1, 'completed', 0, 1)",
                [&copied],
            )
            .unwrap();
    }
    as_machine(Some("fedcba9876543210fedcba9876543210"));
    let rehomed = ids(&root).0;
    assert_ne!(rehomed, copied, "rehomed");
    let connection = Connection::open(registry_file(&root)).unwrap();
    let hook: String = connection
        .query_row(
            "SELECT hooks.hook_id FROM journal_hook_deliveries AS deliveries
                 JOIN journal_hooks AS hooks USING(hook_id, manifest_version)",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(hook, copied, "the hook keeps the id its deliveries name");
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

/// An idempotency key is the client's opaque string, and the resource
/// ledger the rehome leaves as stored is joined on it: a creation
/// receipt and an input completion whose key happens to be the registry
/// id keep naming the effect receipt they belong to after a rehome.
#[test]
fn a_receipt_keyed_like_the_registry_keeps_its_joins_after_a_rehome() {
    let root = temp_root("rehome-keys");
    as_machine(Some("0123456789abcdef0123456789abcdef"));
    let copied = ids(&root).0;
    {
        let connection = Connection::open(registry_file(&root)).unwrap();
        connection
            .execute(
                "INSERT INTO resource_effect_receipts(
                       idempotency_key, operation, fingerprint, intent_json, state
                     ) VALUES(?1, 'notification.create', '{}', '{}', 'pending')",
                [&copied],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO resource_creation_receipts(
                       correlation_key, operation, fingerprint, idempotency_key, intent_json,
                       execution_kind, attempt, state
                     ) VALUES('correlated', 'notification.create', '{}', ?1, '{}', 'effect', 1,
                       'prepared')",
                [&copied],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO resource_input_receipt_completions(idempotency_key) VALUES(?1)",
                [&copied],
            )
            .unwrap();
    }
    as_machine(Some("fedcba9876543210fedcba9876543210"));
    assert_ne!(ids(&root).0, copied, "rehomed");
    let connection = Connection::open(registry_file(&root)).unwrap();
    let joined = |table: &str| -> i64 {
        connection
            .query_row(
                &format!(
                    "SELECT COUNT(*) FROM {table} AS keyed
                         JOIN resource_effect_receipts AS effect USING(idempotency_key)"
                ),
                [],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert_eq!(joined("resource_creation_receipts"), 1, "the creation receipt's effect");
    assert_eq!(joined("resource_input_receipt_completions"), 1, "the completion's effect");
    drop(connection);
    fs::remove_dir_all(root).unwrap();
}

/// Mutation receipts and the events they recorded, `count` of each kind,
/// and the resource ledger's receipts (results of a few kilobytes, as a
/// real ledger's are): what a long-lived registry accumulates, none
/// naming the registry id.
fn seed_receipts(root: &Path, count: usize) {
    let connection = Connection::open(registry_file(root)).unwrap();
    let tx = connection.unchecked_transaction().unwrap();
    for index in 0..count {
        let id = format!("mutation_{index:08}");
        let result = serde_json::json!({"workspace_key": format!("ws_{index:032x}"), "ok": true})
            .to_string();
        tx.execute(
                "INSERT INTO mutations(origin, mutation_id, fingerprint, result_json, committed_revision)
                 VALUES('client', ?1, '{}', ?2, ?3)",
                params![id, result, index as i64 + 1],
            )
            .unwrap();
        tx.execute(
                "INSERT INTO workspace_events(revision, kind, workspace_key, origin, mutation_id, result_json)
                 VALUES(?3 + 1000000, 'workspace.update', 'one', 'client', ?1, ?2)",
                params![id, result, index as i64],
            )
            .unwrap();
        tx.execute(
                "INSERT INTO terminal_mutations(origin, mutation_id, fingerprint, result_json, committed_revision)
                 VALUES('client', ?1, '{}', ?2, ?3)",
                params![id, result, index as i64 + 1],
            )
            .unwrap();
        tx.execute(
                "INSERT INTO terminal_events(revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json)
                 VALUES(?3 + 1000000, 'terminal.update', ?1, 'one', 'client', ?1, ?2)",
                params![id, result, index as i64],
            )
            .unwrap();
        tx.execute(
            "INSERT INTO projection_mutations(origin, mutation_id, fingerprint, result_json)
                 VALUES('client', ?1, '{}', ?2)",
            params![id, result],
        )
        .unwrap();
        let large = serde_json::json!({
            "workspace_key": format!("ws_{index:032x}"),
            "screen": "x".repeat(4096),
        })
        .to_string();
        tx.execute(
            "INSERT INTO resource_mutations(
                   origin, idempotency_key, operation, fingerprint, result_json, committed_revision
                 ) VALUES('client', ?1, 'workspace.update', '{}', ?2, ?3)",
            params![id, large, index as i64 + 1],
        )
        .unwrap();
        let outcome = serde_json::json!({"kind": "success", "value": {"id": id, "body": large}});
        tx.execute(
            "INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state, outcome_json,
                   committed_revision
                 ) VALUES(?1, 'notification.create', '{}', ?2, 'committed', ?3, ?4)",
            params![id, large, outcome.to_string(), index as i64 + 1],
        )
        .unwrap();
    }
    tx.commit().unwrap();
}

/// SQLite VM steps the rehome of a registry with `records` journal
/// records and `receipts` of each mutation receipt takes, after a copy
/// to another machine.
fn rehome_steps(records: usize, receipts: usize) -> u64 {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::super::session_journal::kind_read_tests::TestJournalRecord;
    let root = temp_root("rehome-cost");
    as_machine(Some("0123456789abcdef0123456789abcdef"));
    let registry = WorkspaceRegistry::open(&root, SESSION).unwrap();
    let copied = registry.registry_id().to_string();
    let records = (0..records)
        .map(|index| TestJournalRecord {
            kind: "personal.session.put".into(),
            producer: JournalProducer { kind: "presentation".into(), id: "cmux-tui".into() },
            subjects: vec![JournalSubject {
                kind: "session".into(),
                id: format!("sess_{:032x}", index % 64),
            }],
            payload: serde_json::json!({"index": index}),
        })
        .collect::<Vec<_>>();
    registry.append_journal_records_for_test(&records);
    drop(registry);
    seed_receipts(&root, receipts);
    as_machine(Some("fedcba9876543210fedcba9876543210"));
    let connection = Connection::open(registry_file(&root)).unwrap();
    let steps = std::sync::Arc::new(AtomicU64::new(0));
    let counter = std::sync::Arc::clone(&steps);
    connection
        .progress_handler(
            16,
            Some(move || {
                counter.fetch_add(16, Ordering::Relaxed);
                false
            }),
        )
        .unwrap();
    rehome_registry(&connection, &mut crate::startup_timings::StartupTimings::start()).unwrap();
    connection.progress_handler(0, None::<fn() -> bool>).unwrap();
    assert_ne!(required_meta(&connection, "registry_id").unwrap(), copied, "rehomed");
    drop(connection);
    fs::remove_dir_all(root).unwrap();
    steps.load(Ordering::Relaxed)
}

/// The rehome costs the registry's state, not its history: 10x the
/// journal records adds less than one VM step each. It used to scan
/// every text column of the journal's event index (a row per record)
/// and took 5.5 s of a 7.4 s first start of a 58.7 GB registry on its
/// new machine (2026-11-09).
#[test]
fn the_rehome_cost_does_not_grow_with_the_journal() {
    let sizes = [2_000, 20_000];
    let steps = sizes.map(|records| rehome_steps(records, 0));
    let per_record = steps[1].saturating_sub(steps[0]) / (sizes[1] - sizes[0]) as u64;
    assert!(
        per_record < 1,
        "the rehome costs {per_record} VM steps per journal record ({} at {}, {} at {})",
        steps[0],
        sizes[0],
        steps[1],
        sizes[1]
    );
}

/// Mutation receipts and their events grow with every change; the
/// rehome leaves them as stored and they are read with the new id
/// (`StoredIds`). Scanning them took 1.9 s of a 4.2 s first start of a
/// 58.7 GB registry on its new machine, and the resource ledger's
/// (`resource_mutations`, `resource_effect_receipts`) 1.27 s of a later
/// one (2026-11-09).
#[test]
fn the_rehome_cost_does_not_grow_with_mutation_receipts() {
    let sizes = [500, 5_000];
    let steps = sizes.map(|receipts| rehome_steps(0, receipts));
    let per_receipt = steps[1].saturating_sub(steps[0]) / (sizes[1] - sizes[0]) as u64;
    assert!(
        per_receipt < 1,
        "the rehome costs {per_receipt} VM steps per receipt ({} at {}, {} at {})",
        steps[0],
        sizes[0],
        steps[1],
        sizes[1]
    );
}

/// A receipt or event stored before the move, naming the copied id, is
/// served naming the new one: a retried mutation's result, a
/// subscriber's catch-up, a terminal mutation's replay, a resource
/// patch's replay and a resource effect's committed outcome.
#[test]
fn receipts_stored_before_a_move_are_served_with_the_new_id() {
    let root = temp_root("rehome-receipts");
    as_machine(Some("0123456789abcdef0123456789abcdef"));
    let copied = ids(&root).0;
    let result = serde_json::json!({
        "ref": {"session_id": copied},
        "placement": format!("{copied}/one"),
        "note": format!("echo {copied}"),
    });
    let fingerprint = serde_json::json!({"session": copied});
    {
        let connection = Connection::open(registry_file(&root)).unwrap();
        for table in ["mutations", "terminal_mutations"] {
            connection
                    .execute(
                        &format!(
                            "INSERT INTO {table}(origin, mutation_id, fingerprint, result_json, committed_revision)
                             VALUES('client', 'moved', ?1, ?2, 7)"
                        ),
                        params![
                            canonical_json(&fingerprint).unwrap(),
                            result.to_string()
                        ],
                    )
                    .unwrap();
        }
        connection
                .execute(
                    "INSERT INTO workspace_events(revision, kind, workspace_key, origin, mutation_id, result_json)
                     VALUES(1000000, 'workspace.update', 'one', 'client', 'moved', ?1)",
                    [result.to_string()],
                )
                .unwrap();
        connection
                .execute(
                    "INSERT INTO terminal_events(revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json)
                     VALUES(1000000, 'terminal.update', 'moved', 'one', 'client', 'moved', ?1)",
                    [result.to_string()],
                )
                .unwrap();
        connection
                .execute(
                    "INSERT INTO resource_mutations(
                       origin, idempotency_key, operation, fingerprint, result_json, committed_revision
                     ) VALUES('client', 'moved', 'workspace.update', ?1, ?2, 7)",
                    params![canonical_json(&fingerprint).unwrap(), result.to_string()],
                )
                .unwrap();
        connection
            .execute(
                "INSERT INTO resource_effect_receipts(
                       idempotency_key, operation, fingerprint, intent_json, state, outcome_json,
                       committed_revision
                     ) VALUES('moved', 'notification.create', ?1, ?2, 'committed', ?3, 7)",
                params![
                    canonical_json(&fingerprint).unwrap(),
                    result.to_string(),
                    serde_json::json!({"kind": "success", "value": result}).to_string()
                ],
            )
            .unwrap();
    }
    as_machine(Some("fedcba9876543210fedcba9876543210"));
    let registry = WorkspaceRegistry::open(&root, SESSION).unwrap();
    let rehomed = registry.registry_id().to_string();
    assert_ne!(rehomed, copied);
    let expected = |served: &Value| {
        assert_eq!(served["ref"]["session_id"], rehomed, "{served}");
        assert_eq!(served["placement"], format!("{rehomed}/one"), "{served}");
        assert_eq!(served["note"], format!("echo {copied}"), "free text is kept: {served}");
    };
    let moved_fingerprint = serde_json::json!({"session": rehomed});
    let mutation = WorkspaceMutation::daemon("moved", "client").unwrap();
    let replayed = registry.replay(&mutation, &moved_fingerprint).unwrap().unwrap();
    expected(&replayed.result);
    let event = registry.events_after(999_999).unwrap().pop().unwrap();
    expected(&event.result);
    let terminal_event = registry.terminal_events_after(999_999).unwrap().pop().unwrap();
    expected(&terminal_event.result);
    let terminal = terminal_replay(
        &registry.connection.get(),
        &mutation,
        &canonical_json(&moved_fingerprint).unwrap(),
    )
    .unwrap()
    .unwrap();
    expected(&terminal.result);
    let resource = resource_store::resource_patch_replay(
        &registry.connection.get(),
        &mutation,
        "workspace.update",
        &canonical_json(&moved_fingerprint).unwrap(),
    )
    .unwrap()
    .unwrap();
    expected(&resource.result);
    match registry
        .lookup_resource_effect("moved", "notification.create", &moved_fingerprint)
        .unwrap()
    {
        Some(ResourceEffectPreparation::Committed {
            outcome: ResourceEffectOutcome::Success(value),
            ..
        }) => expected(&value),
        other => panic!("the effect's outcome is not served: {other:?}"),
    }
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

/// The open's startup laps name each table the rehome rewrote and the
/// rows it changed (`registry.migrations.rehome.<table>`), so a slow
/// first start on another machine names the table that cost it: the
/// rehome still took 1.7 s of a 3.9 s first start of a 58.7 GB registry
/// after the journal and receipts left its scan (2026-11-09).
#[test]
fn the_rehome_laps_name_the_tables_it_rewrote() {
    let root = temp_root("rehome-laps");
    as_machine(Some("0123456789abcdef0123456789abcdef"));
    let copied = ids(&root).0;
    plant(&root, &copied);
    as_machine(Some("fedcba9876543210fedcba9876543210"));
    let mut registry = WorkspaceRegistry::open(&root, SESSION).unwrap();
    let line = registry.take_open_timings().to_line(1, 1);
    let steps = line["steps"].as_array().unwrap();
    let lap = |name: &str| steps.iter().find(|step| step["step"] == name).cloned();
    let planted = lap("registry.migrations.rehome.user_text")
        .unwrap_or_else(|| panic!("no lap for the planted table in {steps:?}"));
    assert_eq!(planted["rows"], 1, "{planted}");
    let sessions = lap("registry.migrations.rehome.sessions")
        .unwrap_or_else(|| panic!("no lap for the session rows in {steps:?}"));
    assert!(sessions["rows"].as_u64().unwrap() >= 1, "{sessions}");
    assert!(lap("registry.migrations.rehome").is_some(), "the rest keeps its lap: {steps:?}");
    let names: Vec<_> = steps.iter().filter_map(|step| step["step"].as_str()).collect();
    assert!(
        !names.iter().any(|name| name.starts_with("registry.migrations.rehome.journal_")),
        "skipped tables have no lap: {names:?}"
    );
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ids_written_before_the_stamp_or_without_an_os_identity_are_kept() {
    let root = temp_root("unstamped");
    as_machine(None);
    let made = ids(&root);
    assert!(!root.join(HOST_STAMP_FILE).exists(), "no OS identity: nothing stamped");
    // The first open with an OS identity stamps the ids as they are.
    as_machine(Some("00000000000000000000000000000001"));
    assert_eq!(ids(&root), made);
    assert!(root.join(HOST_STAMP_FILE).exists());
    // A copy made with no OS identity on either side keeps them too.
    as_machine(None);
    assert_eq!(ids(&root), made);
    fs::remove_dir_all(root).unwrap();
}
