use super::*;

struct Registry {
    registry: WorkspaceRegistry,
    root: std::path::PathBuf,
}

impl Drop for Registry {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn open(label: &str) -> Registry {
    let root =
        std::env::temp_dir().join(format!("cmux-archive-{label}-{}", super::super::new_uuid_v4()));
    let registry = WorkspaceRegistry::open(&root, "archive").expect("open the registry");
    Registry { registry, root }
}

fn terminal(index: usize) -> String {
    format!("term_{index:032x}")
}

/// A closed group whose tab records name `terminals`.
fn close_group(registry: &WorkspaceRegistry, closed_id: &str, terminals: &[String]) {
    let tabs = terminals
        .iter()
        .map(|id| serde_json::json!({"kind": "terminal", "terminal_id": id}))
        .collect::<Vec<_>>();
    let record = serde_json::json!({
        "id": closed_id,
        "kind": "tab",
        "members": [{"kind": "tab", "screens": [{"tabs": tabs}]}],
    });
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO closed_groups(closed_id, kind, closed_at_ms, record_json)
             VALUES(?1, 'tab', 1, ?2)",
            params![closed_id, serde_json::to_string(&record).unwrap()],
        )
        .unwrap();
}

fn archive(registry: &mut WorkspaceRegistry, terminal_id: &str, at: u64) {
    registry
        .put_terminal_archives(
            &[ArchiveRow {
                terminal_id,
                generation: "g1",
                program: Some("sleep"),
                cols: 80,
                rows: 24,
                screen: Some(b"old screen"),
            }],
            at,
            ARCHIVE_BLOB_BUDGET_BYTES,
        )
        .unwrap();
}

fn count(registry: &WorkspaceRegistry) -> usize {
    registry
        .connection
        .get()
        .query_row("SELECT COUNT(*) FROM terminal_archives", [], |row| row.get::<_, i64>(0))
        .map(|count| usize::try_from(count).unwrap())
        .unwrap()
}

#[test]
fn an_archive_round_trips_its_screen_and_program() {
    let mut registry = open("round-trip");
    let id = terminal(1);
    close_group(&registry.registry, "closed_a", std::slice::from_ref(&id));
    archive(&mut registry.registry, &id, 1);
    let stored = registry.registry.terminal_archive(&id).unwrap().expect("stored");
    assert_eq!(stored.screen.as_deref(), Some(&b"old screen"[..]));
    assert_eq!(stored.program.as_deref(), Some("sleep"));
    assert_eq!((stored.cols, stored.rows), (80, 24));
}

/// The budget: archiving one terminal more than the limit keeps the newest
/// MAX_ARCHIVES archives and drops the oldest.
#[test]
fn archives_past_the_limit_drop_the_oldest() {
    let mut registry = open("limit");
    let all = (0..=MAX_ARCHIVES).map(terminal).collect::<Vec<_>>();
    close_group(&registry.registry, "closed_all", &all);
    for index in 0..=MAX_ARCHIVES {
        archive(&mut registry.registry, &terminal(index), u64::try_from(index).unwrap() + 1);
    }
    assert_eq!(count(&registry.registry), MAX_ARCHIVES);
    assert!(registry.registry.terminal_archive(&terminal(0)).unwrap().is_none());
    assert!(registry.registry.terminal_archive(&terminal(MAX_ARCHIVES)).unwrap().is_some());
}

/// An archive goes with the last closed group that names its terminal: a
/// reopen (the group deleted or rewritten without the member) or a delete.
#[test]
fn an_archive_goes_with_its_closed_group() {
    let mut registry = open("group");
    let (first, second) = (terminal(1), terminal(2));
    close_group(&registry.registry, "closed_a", &[first.clone(), second.clone()]);
    archive(&mut registry.registry, &first, 1);
    archive(&mut registry.registry, &second, 2);

    // Partial reopen of `first`: the group keeps only `second`.
    let kept = serde_json::json!({"kind":"tab","screens":[{"tabs":[{"terminal_id": second}]}]});
    registry
        .registry
        .connection
        .get()
        .execute(
            "UPDATE closed_groups SET record_json = ?1 WHERE closed_id = 'closed_a'",
            [serde_json::to_string(&kept).unwrap()],
        )
        .unwrap();
    assert!(registry.registry.terminal_archive(&first).unwrap().is_none());
    assert!(registry.registry.terminal_archive(&second).unwrap().is_some());

    registry
        .registry
        .connection
        .get()
        .execute("DELETE FROM closed_groups WHERE closed_id = 'closed_a'", [])
        .unwrap();
    assert_eq!(count(&registry.registry), 0);
}

#[test]
fn an_oversized_screen_is_not_stored_and_a_program_name_is_cleaned() {
    let mut registry = open("clean");
    let id = terminal(3);
    close_group(&registry.registry, "closed_c", std::slice::from_ref(&id));
    let huge = vec![b'x'; ARCHIVE_MAX_SCREEN_BYTES + 1];
    registry
        .registry
        .put_terminal_archives(
            &[ArchiveRow {
                terminal_id: &id,
                generation: "g1",
                program: Some("sl\u{1b}e\u{202E}ep"),
                cols: 80,
                rows: 24,
                screen: Some(&huge),
            }],
            1,
            ARCHIVE_BLOB_BUDGET_BYTES,
        )
        .unwrap();
    let stored = registry.registry.terminal_archive(&id).unwrap().expect("stored");
    assert_eq!(stored.screen, None);
    assert_eq!(stored.program.as_deref(), Some("sleep"));
    assert_eq!(clean_program("\u{7}"), None);
}

/// A reopen that committed before the archive was stored leaves no group:
/// the archive is not stored.
#[test]
fn an_archive_without_a_closed_group_is_not_stored() {
    let mut registry = open("no-group");
    archive(&mut registry.registry, &terminal(7), 1);
    assert_eq!(count(&registry.registry), 0);
    assert!(!registry.registry.closed_history_mentions_terminal(&terminal(7)).unwrap());
}

/// The byte budget across archives: past it the oldest archive loses its
/// screen (the reopened tab keeps its program line), and its closed-history
/// row says the scrollback was not kept.
#[test]
fn archives_past_the_byte_budget_lose_the_oldest_screen() {
    let mut registry = open("budget");
    let (old, new) = (terminal(1), terminal(2));
    close_group(&registry.registry, "closed_old", std::slice::from_ref(&old));
    close_group(&registry.registry, "closed_new", std::slice::from_ref(&new));
    // Noise does not compress: each gzip screen is just over 4 KiB.
    let mut seed = 1_u32;
    let screen = (0..4096)
        .map(|_| {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            seed.to_be_bytes()[0]
        })
        .collect::<Vec<_>>();
    for (id, at) in [(&old, 1), (&new, 2)] {
        let row = ArchiveRow {
            terminal_id: id,
            generation: "g1",
            program: Some("sleep"),
            cols: 80,
            rows: 24,
            screen: Some(&screen),
        };
        registry.registry.put_terminal_archives(&[row], at, 6 * 1024).unwrap();
    }

    let evicted = registry.registry.terminal_archive(&old).unwrap().expect("the row stays");
    assert_eq!(evicted.screen, None, "the oldest screen goes first");
    assert_eq!(evicted.program.as_deref(), Some("sleep"));
    let kept = registry.registry.terminal_archive(&new).unwrap().expect("kept");
    assert_eq!(kept.screen.as_deref(), Some(&screen[..]));

    let items = crate::state::closed_history_query::closed_items_in(
        &registry.registry.connection.get(),
        None,
        10,
    )
    .unwrap();
    let not_kept = |closed_id: &str| {
        let item = items.iter().find(|item| item["id"] == closed_id).expect("listed");
        item["members"][0]["screens"][0]["tabs"][0]["scrollback_not_kept"].clone()
    };
    assert_eq!(not_kept("closed_old"), serde_json::json!(true));
    assert_eq!(not_kept("closed_new"), serde_json::Value::Null);
}

#[test]
fn an_archive_older_than_the_age_limit_is_dropped() {
    let mut registry = open("age");
    let (old, new) = (terminal(1), terminal(2));
    close_group(&registry.registry, "closed_a", &[old.clone(), new.clone()]);
    archive(&mut registry.registry, &old, 1);
    archive(&mut registry.registry, &new, MAX_ARCHIVE_AGE_MS + 2);
    assert!(registry.registry.terminal_archive(&old).unwrap().is_none());
    assert!(registry.registry.terminal_archive(&new).unwrap().is_some());
}

/// Groups written before the index existed are indexed when it is created.
#[test]
fn the_group_index_is_filled_from_older_groups() {
    let root =
        std::env::temp_dir().join(format!("cmux-archive-backfill-{}", super::super::new_uuid_v4()));
    let id = terminal(9);
    {
        let registry = WorkspaceRegistry::open(&root, "archive").expect("open the registry");
        registry
            .connection
            .get()
            .execute_batch(
                "DROP TRIGGER closed_groups_insert_names_terminals_v1;
                 DROP TRIGGER closed_groups_update_names_terminals_v1;
                 DROP TRIGGER closed_groups_delete_names_terminals_v1;
                 DROP TABLE closed_group_terminals;",
            )
            .unwrap();
        close_group(&registry, "closed_old", std::slice::from_ref(&id));
    }
    let reopened = WorkspaceRegistry::open(&root, "archive").expect("reopen the registry");
    assert!(reopened.closed_history_mentions_terminal(&id).unwrap());
    drop(reopened);
    let _ = std::fs::remove_dir_all(&root);
}
