use super::*;

const NOW: u64 = 100 * DAY_MS;

fn temp_root(label: &str) -> std::path::PathBuf {
    std::env::temp_dir()
        .join(format!("cmux-command-history-{label}-{}", crate::workspace_registry::new_uuid_v4()))
}

fn command(text: &str, started_at_ms: u64) -> FinishedCommand {
    FinishedCommand {
        command: Some(text.into()),
        cwd: Some("/repo".into()),
        exit_code: Some(0),
        started_at_ms,
        duration_ms: 5,
    }
}

fn terminal() -> String {
    "term_00000000000000000000000000000001".into()
}

fn texts(page: &CommandHistoryPage) -> Vec<String> {
    page.commands.iter().map(|row| row.command.clone().unwrap_or_default()).collect()
}

#[test]
fn command_history_lists_the_newest_rows_after_a_cursor_in_order() {
    let mut registry = WorkspaceRegistry::in_memory("command-history-list").unwrap();
    let rows: Vec<_> =
        (0..5).map(|step| (terminal(), command(&format!("c{step}"), NOW + step))).collect();
    registry.append_terminal_commands(&rows, NOW).unwrap();

    let page = registry.list_terminal_commands(None, 10, NOW).unwrap();
    assert_eq!(texts(&page), ["c0", "c1", "c2", "c3", "c4"]);
    assert_eq!(page.retention_days, DEFAULT_COMMAND_RETENTION_DAYS);
    assert_eq!(page.deletions, 0);
    let first = &page.commands[0];
    assert_eq!(first.terminal_id, terminal());
    assert_eq!(first.cwd.as_deref(), Some("/repo"));
    assert_eq!(first.exit_code, Some(0));
    assert_eq!(first.started_at_ms, NOW);
    assert_eq!(first.duration_ms, 5);

    assert!(!page.truncated);
    assert_eq!(page.registry_id, registry.registry_id());

    let newest = registry.list_terminal_commands(None, 2, NOW).unwrap();
    assert_eq!(texts(&newest), ["c3", "c4"], "a limit keeps the newest rows");
    assert!(newest.truncated, "older rows were left out");
    let after = registry.list_terminal_commands(Some(page.commands[2].id), 10, NOW).unwrap();
    assert_eq!(texts(&after), ["c3", "c4"]);
    assert!(!after.truncated);
    let gap = registry.list_terminal_commands(Some(page.commands[0].id), 2, NOW).unwrap();
    assert_eq!(texts(&gap), ["c3", "c4"]);
    assert!(gap.truncated, "a reader after c0 missed c1 and c2");
}

#[test]
fn command_history_deletes_by_id_by_start_time_and_all() {
    let mut registry = WorkspaceRegistry::in_memory("command-history-delete").unwrap();
    let rows: Vec<_> =
        (0..4).map(|step| (terminal(), command(&format!("c{step}"), NOW + step))).collect();
    registry.append_terminal_commands(&rows, NOW).unwrap();
    let ids: Vec<u64> = registry
        .list_terminal_commands(None, 10, NOW)
        .unwrap()
        .commands
        .iter()
        .map(|r| r.id)
        .collect();

    assert_eq!(registry.delete_terminal_commands(&CommandDeletion::Ids(vec![ids[1]])).unwrap(), 1);
    let page = registry.list_terminal_commands(None, 10, NOW).unwrap();
    assert_eq!(texts(&page), ["c0", "c2", "c3"]);
    assert_eq!(page.deletions, 1);

    assert_eq!(
        registry.delete_terminal_commands(&CommandDeletion::StartedSince(NOW + 2)).unwrap(),
        2
    );
    assert_eq!(texts(&registry.list_terminal_commands(None, 10, NOW).unwrap()), ["c0"]);

    // A delete that removes nothing does not count.
    assert_eq!(registry.delete_terminal_commands(&CommandDeletion::Ids(vec![ids[1]])).unwrap(), 0);
    assert_eq!(registry.list_terminal_commands(None, 10, NOW).unwrap().deletions, 2);

    assert_eq!(registry.delete_terminal_commands(&CommandDeletion::All).unwrap(), 1);
    let empty = registry.list_terminal_commands(None, 10, NOW).unwrap();
    assert!(empty.commands.is_empty());
    assert_eq!(empty.deletions, 3);

    // Ids are never reused after a delete.
    registry.append_terminal_commands(&[(terminal(), command("next", NOW))], NOW).unwrap();
    let next = registry.list_terminal_commands(None, 10, NOW).unwrap();
    assert!(next.commands[0].id > ids[3]);
}

#[test]
fn command_history_expires_rows_after_the_retention_period() {
    let mut registry = WorkspaceRegistry::in_memory("command-history-expiry").unwrap();
    let old = NOW - 31 * DAY_MS;
    let recent = NOW - 29 * DAY_MS;
    let stored = registry
        .append_terminal_commands(
            &[(terminal(), command("old", old)), (terminal(), command("recent", recent))],
            NOW,
        )
        .unwrap();
    // The append deleted the expired row and reports the next expiry.
    let next = recent + 30 * DAY_MS;
    assert_eq!(stored, CommandExpiry { deleted: 1, next_ms: Some(next) });
    let page = registry.list_terminal_commands(None, 10, NOW).unwrap();
    assert_eq!(texts(&page), ["recent"]);
    assert_eq!(page.deletions, 0, "expiry is not a client delete");

    // At the next expiry time the row goes, and nothing is left to wait for.
    assert_eq!(
        registry.expire_terminal_commands(next - 1).unwrap(),
        CommandExpiry { deleted: 0, next_ms: Some(next) }
    );
    assert_eq!(
        registry.expire_terminal_commands(next).unwrap(),
        CommandExpiry { deleted: 1, next_ms: None }
    );
    assert!(registry.list_terminal_commands(None, 10, NOW).unwrap().commands.is_empty());
}

#[test]
fn command_history_list_never_returns_an_expired_row() {
    let mut registry = WorkspaceRegistry::in_memory("command-history-list-expiry").unwrap();
    registry.append_terminal_commands(&[(terminal(), command("a", NOW))], NOW).unwrap();
    let later = NOW + 30 * DAY_MS;
    assert!(registry.list_terminal_commands(None, 10, later).unwrap().commands.is_empty());
    assert_eq!(registry.list_terminal_commands(None, 10, later - 1).unwrap().commands.len(), 1);
}

#[test]
fn command_history_retention_is_validated_persisted_and_applied_at_once() {
    let root = temp_root("retention");
    {
        let mut registry = WorkspaceRegistry::open(&root, "retention").unwrap();
        assert_eq!(registry.terminal_command_retention_days().unwrap(), 30);
        registry
            .append_terminal_commands(
                &[
                    (terminal(), command("ten days", NOW - 10 * DAY_MS)),
                    (terminal(), command("two days", NOW - 2 * DAY_MS)),
                ],
                NOW,
            )
            .unwrap();
        assert!(registry.set_terminal_command_retention_days(0).is_err());
        assert!(
            registry.set_terminal_command_retention_days(MAX_COMMAND_RETENTION_DAYS + 1).is_err()
        );
        registry.set_terminal_command_retention_days(7).unwrap();
        // Hidden from lists at once, deleted on the next pass.
        assert_eq!(texts(&registry.list_terminal_commands(None, 10, NOW).unwrap()), ["two days"]);
        assert_eq!(
            registry.expire_terminal_commands(NOW).unwrap(),
            CommandExpiry { deleted: 1, next_ms: Some(NOW - 2 * DAY_MS + 7 * DAY_MS) }
        );
    }
    let registry = WorkspaceRegistry::open(&root, "retention").unwrap();
    assert_eq!(registry.terminal_command_retention_days().unwrap(), 7);
    drop(registry);
    let _ = std::fs::remove_dir_all(root);
}

/// A deleted command line must not stay readable in the database file.
#[test]
fn command_history_delete_zeroes_the_deleted_text_on_disk() {
    let root = temp_root("secure-delete");
    let secret = "export TOKEN=cmux-secret-4f1c9e";
    let path = {
        let mut registry = WorkspaceRegistry::open(&root, "secure-delete").unwrap();
        registry.append_terminal_commands(&[(terminal(), command(secret, NOW))], NOW).unwrap();
        assert_eq!(registry.delete_terminal_commands(&CommandDeletion::All).unwrap(), 1);
        assert!(registry.checkpoint_terminal_command_deletes().unwrap());
        registry.session_journal_database_path().unwrap()
    };
    let mut bytes = std::fs::read(&path).unwrap();
    if let Ok(wal) = std::fs::read(path.with_extension("sqlite3-wal")) {
        bytes.extend(wal);
    }
    let needle = b"cmux-secret-4f1c9e";
    assert!(
        !bytes.windows(needle.len()).any(|window| window == needle),
        "deleted command text is still in the database file"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn command_history_rejects_oversized_requests() {
    let mut registry = WorkspaceRegistry::in_memory("command-history-limits").unwrap();
    assert!(registry.list_terminal_commands(None, 0, NOW).is_err());
    assert!(registry.list_terminal_commands(None, MAX_COMMAND_LIST_LIMIT + 1, NOW).is_err());
    let ids = (1..=MAX_COMMAND_DELETE_IDS as u64 + 1).collect();
    assert!(registry.delete_terminal_commands(&CommandDeletion::Ids(ids)).is_err());
    assert!(registry.delete_terminal_commands(&CommandDeletion::Ids(Vec::new())).is_err());
}
