//! cmux#38186: a command clear the app queued while the daemon was away
//! carries its click time, so a command that started after the click stays
//! when the clear arrives later.

use crate::shell_history::FinishedCommand;
use crate::state::command_history_store::CommandDeletion;
use crate::workspace_registry::WorkspaceRegistry;

fn finished(command: &str, started_at_ms: u64) -> FinishedCommand {
    FinishedCommand {
        command: Some(command.to_owned()),
        cwd: None,
        exit_code: Some(0),
        started_at_ms,
        duration_ms: 1,
    }
}

#[test]
fn a_delayed_command_clear_keeps_a_command_started_after_its_click() {
    let root = std::env::temp_dir()
        .join(format!("cmux-command-clear-until-{}", crate::workspace_registry::new_uuid_v4()));
    let mut registry = WorkspaceRegistry::open(&root, "command-clear-until").unwrap();
    let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap();
    let click_ms = now_ms - 60_000;
    let commands = [
        ("term_a".to_owned(), finished("before", click_ms - 1_000)),
        ("term_a".to_owned(), finished("after", click_ms + 1_000)),
    ];
    registry.append_terminal_commands(&commands, now_ms).unwrap();
    let deleted =
        registry.delete_terminal_commands(&CommandDeletion::StartedWithin(0, click_ms)).unwrap();
    assert_eq!(deleted, 1);
    let page = registry.list_terminal_commands(None, 10, now_ms).unwrap();
    let left: Vec<_> = page.commands.iter().filter_map(|row| row.command.clone()).collect();
    assert_eq!(
        left,
        vec!["after".to_owned()],
        "the delayed clear took a command started after the click"
    );
    drop(registry);
    let _ = std::fs::remove_dir_all(&root);
}
