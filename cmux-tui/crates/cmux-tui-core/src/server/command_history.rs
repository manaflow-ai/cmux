//! Raw protocol handlers for terminal command history
//! (`terminal-command-history-v1`, plans/cmux-next/history.md section 6).
//! Command lines can hold secrets: only trusted local (Unix-classified)
//! connections read, change or delete them. The rows and their worker live
//! in the workspace registry and mux/command_history.rs.

use std::sync::Arc;

use serde_json::Value;

use super::{Command, Mux};
use crate::resource::ResourceError;
use crate::workspace_registry::command_history_store::{CommandDeletion, MAX_COMMAND_LIST_LIMIT};

pub(super) fn handle(mux: &Arc<Mux>, client: u64, command: Command) -> anyhow::Result<Value> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "terminal command history requires a trusted local connection"
    );
    match command {
        Command::SetTerminalCommandHistory { enabled, retention_days } => {
            mux.set_terminal_command_history(enabled, retention_days)
        }
        Command::ListTerminalCommands { after_id, limit } => {
            let after_id = after_id.as_deref().map(decimal).transpose()?;
            let limit = limit.map_or(MAX_COMMAND_LIST_LIMIT, |limit| {
                usize::try_from(limit).unwrap_or(usize::MAX)
            });
            mux.list_terminal_commands(after_id, limit)
        }
        Command::DeleteTerminalCommands { ids, started_since_ms, all } => {
            let deletion = match (ids, started_since_ms, all) {
                (Some(ids), None, false) => CommandDeletion::Ids(
                    ids.iter().map(|id| decimal(id)).collect::<anyhow::Result<_>>()?,
                ),
                (None, Some(since), false) => CommandDeletion::StartedSince(decimal(&since)?),
                (None, None, true) => CommandDeletion::All,
                _ => anyhow::bail!("bad request: give exactly one of ids, started_since_ms or all"),
            };
            mux.delete_terminal_commands(deletion)
        }
        _ => anyhow::bail!("not a terminal command history command"),
    }
}

/// `cmux_shell` is a reserved journal producer id (development builds
/// journaled commands under it): `session.journal.append` refuses it, so no
/// client can append records that look like those.
pub(super) fn refuse_reserved_producer(
    ingress: &crate::JournalIngress,
) -> Result<(), ResourceError> {
    if ingress.producer_id == crate::shell_history::SHELL_PRODUCER_ID {
        return Err(ResourceError::validation_invalid(
            Some("event"),
            "the cmux shell producer id is reserved".to_string(),
        ));
    }
    Ok(())
}

/// A command history id or time: a decimal string, like journal sequences.
fn decimal(value: &str) -> anyhow::Result<u64> {
    anyhow::ensure!(
        !value.is_empty() && value.len() <= 20 && value.bytes().all(|byte| byte.is_ascii_digit()),
        "bad request: expected a decimal string, got {value:?}"
    );
    value.parse().map_err(|_| anyhow::anyhow!("bad request: {value:?} is out of range"))
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use serde_json::json;

    use super::super::*;

    fn test_mux() -> Arc<Mux> {
        Mux::new_for_test("terminal-command-history", crate::SurfaceOptions::default())
    }

    fn test_writer() -> MessageWriter {
        MessageWriter::new(QueuedSink {
            outbound: Arc::new(BoundedOutbound::default()),
            control: None,
        })
    }

    fn command_history_request(value: Value) -> Command {
        serde_json::from_value(value).unwrap()
    }

    /// terminal-command-history-v1: commands are stored rows that a trusted
    /// client lists and deletes, with a retention; remote clients get none
    /// of it.
    #[test]
    fn terminal_command_history_stores_lists_and_deletes_commands() {
        let mux = test_mux();
        let unix = mux.control_clients.register(ClientTransport::Unix, test_writer());
        let remote = mux.control_clients.register(ClientTransport::WebSocket, test_writer());
        let run = |client, value: Value| {
            handle_command(&mux, client, command_history_request(value), &test_writer())
        };
        let identity = handle_command(&mux, 0, Command::Identify, &test_writer()).unwrap();
        assert!(
            identity["capabilities"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c == TERMINAL_COMMAND_HISTORY_CAPABILITY)
        );

        let set =
            run(unix, json!({"cmd": "set-terminal-command-history", "enabled": true})).unwrap();
        assert_eq!(set, json!({"enabled": true, "retention_days": 30}));
        let set = run(
            unix,
            json!({"cmd": "set-terminal-command-history", "enabled": true, "retention_days": 7}),
        )
        .unwrap();
        assert_eq!(set["retention_days"], 7);
        assert!(
            run(
                unix,
                json!({"cmd": "set-terminal-command-history", "enabled": true, "retention_days": 0})
            )
            .is_err()
        );

        let terminal = TerminalPublicId::parse("term_00000000000000000000000000000042").unwrap();
        let now = crate::workspace_registry::unix_epoch_ms().unwrap();
        let finished = |text: &str, started_at_ms| crate::shell_history::FinishedCommand {
            command: Some(text.into()),
            cwd: Some("/repo".into()),
            exit_code: Some(1),
            started_at_ms,
            duration_ms: 3,
        };
        mux.append_shell_commands(
            terminal.clone(),
            vec![finished("make test", now), finished("git push", now + 1)],
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        let listed = loop {
            let listed = run(unix, json!({"cmd": "list-terminal-commands"})).unwrap();
            if listed["commands"].as_array().unwrap().len() == 2 {
                break listed;
            }
            assert!(Instant::now() < deadline, "commands never stored: {listed}");
            std::thread::sleep(Duration::from_millis(10));
        };
        let first = &listed["commands"][0];
        assert_eq!(first["command"], "make test");
        assert_eq!(first["terminal_id"], terminal.to_string());
        assert_eq!(first["cwd"], "/repo");
        assert_eq!(first["exit_code"], 1);
        assert_eq!(first["started_at_ms"], now.to_string());
        assert_eq!(first["duration_ms"], "3");
        assert_eq!(listed["retention_days"], 7);
        assert_eq!(listed["deletions"], "0");
        assert_eq!(listed["truncated"], false);
        assert!(listed["registry_id"].is_string());
        let first_id = first["id"].as_str().unwrap().to_owned();
        let after =
            run(unix, json!({"cmd": "list-terminal-commands", "after_id": first_id})).unwrap();
        assert_eq!(after["commands"].as_array().unwrap().len(), 1);
        assert_eq!(after["commands"][0]["command"], "git push");

        // Remote clients cannot read, change or delete command history.
        for request in [
            json!({"cmd": "list-terminal-commands"}),
            json!({"cmd": "delete-terminal-commands", "all": true}),
            json!({"cmd": "set-terminal-command-history", "enabled": false}),
        ] {
            let error = run(remote, request).expect_err("remote command history request");
            assert!(error.to_string().contains("trusted local connection"), "{error}");
        }

        // A delete names exactly one selector.
        assert!(run(unix, json!({"cmd": "delete-terminal-commands"})).is_err());
        assert!(
            run(unix, json!({"cmd": "delete-terminal-commands", "all": true, "ids": ["1"]}))
                .is_err()
        );
        assert!(run(unix, json!({"cmd": "delete-terminal-commands", "ids": ["x"]})).is_err());
        let deleted =
            run(unix, json!({"cmd": "delete-terminal-commands", "ids": [first["id"]]})).unwrap();
        assert_eq!(deleted, json!({"deleted": 1}));
        let deleted = run(
            unix,
            json!({"cmd": "delete-terminal-commands", "started_since_ms": now.to_string()}),
        )
        .unwrap();
        assert_eq!(deleted, json!({"deleted": 1}));
        let listed = run(unix, json!({"cmd": "list-terminal-commands"})).unwrap();
        assert!(listed["commands"].as_array().unwrap().is_empty());
        assert_eq!(listed["deletions"], "2");

        // A command still queued when a delete arrives is deleted with the
        // rest: deletes run in queue order.
        mux.append_shell_commands(terminal.clone(), vec![finished("queued", now + 5)]);
        let deleted = run(unix, json!({"cmd": "delete-terminal-commands", "all": true})).unwrap();
        assert_eq!(deleted, json!({"deleted": 1}));
        let listed = run(unix, json!({"cmd": "list-terminal-commands"})).unwrap();
        assert!(listed["commands"].as_array().unwrap().is_empty(), "{listed}");

        // Off: nothing more is stored.
        run(unix, json!({"cmd": "set-terminal-command-history", "enabled": false})).unwrap();
        mux.append_shell_commands(terminal, vec![finished("ls", now + 2)]);
        std::thread::sleep(Duration::from_millis(50));
        let listed = run(unix, json!({"cmd": "list-terminal-commands"})).unwrap();
        assert!(listed["commands"].as_array().unwrap().is_empty());
    }
}
