//! Terminals of an incognito (ephemeral) workspace keep nothing on disk
//! (leo-workspace design/spaces.md "Incognito": nothing kept, never
//! restored). Their shells start with history off, the daemon writes no
//! relaunch record for them, and their screen and scrollback stay in memory:
//! no output-store snapshot and no exit replay.

use std::sync::Arc;

use serde_json::json;

use super::tests::{Session, mutate};
use crate::mux::*;

/// A new workspace, `ephemeral` or not, with `initial_content`: its public
/// id and its key.
fn workspace(mux: &Arc<Mux>, name: &str, content: &str, ephemeral: bool) -> (String, String) {
    let mut params = json!({"name": name, "initial_content": content});
    if ephemeral {
        params["ephemeral"] = json!(true);
    }
    let created = mutate(mux, "workspace.create", params, &format!("create-{name}"));
    let id = created["workspace_id"].as_str().unwrap().to_string();
    let key = mux
        .with_state(|state| {
            state
                .workspaces
                .iter()
                .find(|workspace| workspace.public_id.as_str() == id)
                .map(|workspace| workspace.key.clone())
        })
        .expect("the created workspace");
    (id, key)
}

/// The internal ids of the terminals workspace `key` created.
fn terminals_of(mux: &Arc<Mux>, key: &str) -> Vec<String> {
    mux.read_registry_state(|connection| {
        let mut rows = connection
            .prepare("SELECT terminal_id FROM terminal_hosts WHERE workspace_key = ?1")?;
        Ok(rows.query_map([key], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
    })
    .unwrap()
}

fn env_value<'a>(env: &'a [(String, String)], key: &str) -> Option<&'a str> {
    env.iter().rev().find(|(name, _)| name == key).map(|(_, value)| value.as_str())
}

/// Leak 7 of the incognito audit: the relaunch row (cwd, argv, title,
/// agent session) of an incognito terminal stayed in SQLite until the next
/// daemon start.
#[test]
fn an_incognito_terminal_leaves_no_relaunch_record() {
    let session = Session::new("incognito-relaunch");
    let mux = session.open();
    let (_, normal) = workspace(&mux, "normal", "terminal", false);
    let (_, private) = workspace(&mux, "private", "terminal", true);
    let normal = terminals_of(&mux, &normal);
    let private = terminals_of(&mux, &private);
    assert_eq!(normal.len(), 1, "{normal:?}");
    assert_eq!(private.len(), 1, "{private:?}");
    let registry = mux.workspace_registry.lock().unwrap();
    assert!(
        registry.terminal_relaunch_record(&normal[0]).unwrap().is_some(),
        "a normal terminal keeps its relaunch record"
    );
    assert!(
        registry.terminal_relaunch_record(&private[0]).unwrap().is_none(),
        "an incognito terminal must leave no relaunch record"
    );
    drop(registry);
    mux.shutdown();
}

/// Leak 2 of the incognito audit: every command typed in an incognito
/// terminal reached ~/.zsh_history, ~/.bash_history or fish history. Its
/// shell starts with history off; a normal terminal's does not.
#[test]
fn an_incognito_terminal_starts_its_shell_with_history_off() {
    let session = Session::new("incognito-history");
    let mux = session.open();
    let (_, normal) = workspace(&mux, "normal", "empty", false);
    let (_, private) = workspace(&mux, "private", "empty", true);
    let (options, _) = mux.terminal_spawn_options_in(None, None, None, &[], Some(&private));
    assert_eq!(env_value(&options.extra_env, "HISTFILE"), Some("/dev/null"));
    assert_eq!(env_value(&options.extra_env, "fish_private_mode"), Some("1"));
    assert_eq!(env_value(&options.extra_env, "CMUX_TUI_INCOGNITO"), Some("1"));
    // A caller cannot turn it back on.
    let caller = [("HISTFILE".to_string(), "/tmp/kept".to_string())];
    let (options, _) = mux.terminal_spawn_options_in(None, None, None, &caller, Some(&private));
    assert_eq!(env_value(&options.extra_env, "HISTFILE"), Some("/dev/null"));
    let (options, _) = mux.terminal_spawn_options_in(None, None, None, &[], Some(&normal));
    assert_eq!(env_value(&options.extra_env, "HISTFILE"), None);
    assert_eq!(env_value(&options.extra_env, "fish_private_mode"), None);
    assert_eq!(env_value(&options.extra_env, "CMUX_TUI_INCOGNITO"), None);
    mux.shutdown();
}

/// Leak 4 of the incognito audit: the output store wrote each terminal's
/// screen and scrollback to disk about every 30 s and at quit, and the exit
/// latch stored its final screen in SQLite. An incognito terminal's stay in
/// memory; a normal terminal's are still written.
#[cfg(unix)]
#[test]
fn an_incognito_terminal_screen_never_reaches_the_disk() {
    const NORMAL: &str = "00000000000040008000000000000a01";
    const PRIVATE: &str = "00000000000040008000000000000a02";
    const INCARNATIONS: [&str; 2] =
        ["10000000000040008000000000000a01", "10000000000040008000000000000a02"];
    let session = Session::new("incognito-scrollback");
    let mux = session.open();
    let directory = mux.output_store.directory().expect("a persistent session").to_path_buf();
    let (_, normal_key) = workspace(&mux, "normal", "empty", false);
    let (_, private_key) = workspace(&mux, "private", "empty", true);
    let mut ids = Vec::new();
    for ((terminal, key), incarnation) in
        [(NORMAL, &normal_key), (PRIVATE, &private_key)].into_iter().zip(INCARNATIONS)
    {
        let surface = mux.seed_running_terminal_for_test(terminal, incarnation, key).unwrap();
        let public = mux
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id(terminal)
            .unwrap()
            .expect("a public terminal id");
        let bytes = format!("secret output of {terminal}\r\n").into_bytes();
        mux.surface(surface).unwrap().apply_stream_output_for_test(&bytes).unwrap();
        mux.output_store.append(&public, &Arc::from(incarnation), &bytes, None);
        ids.push((surface, public));
    }
    mux.output_store.write_now(&mux);
    let files = || {
        std::fs::read_dir(&directory)
            .map(|entries| {
                entries.flatten().map(|entry| entry.file_name().to_string_lossy().into_owned())
            })
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
    };
    let (normal, private) = (&ids[0].1, &ids[1].1);
    assert!(
        files().iter().any(|file| file.starts_with(normal.as_str())),
        "a normal terminal's snapshot is written: {:?}",
        files()
    );
    assert!(
        !files().iter().any(|file| file.starts_with(private.as_str())),
        "an incognito terminal's screen must stay in memory: {:?}",
        files()
    );
    // Its exit stores no final screen either.
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1,
    };
    for (_, public) in &ids {
        assert!(mux.persist_terminal_exit_for_test(public, &exit).unwrap());
    }
    let registry = mux.workspace_registry.lock().unwrap();
    assert!(registry.terminal_exit_snapshot(normal.as_str()).unwrap().is_some());
    assert!(
        registry.terminal_exit_snapshot(private.as_str()).unwrap().is_none(),
        "an incognito terminal's exit must store no screen"
    );
    drop(registry);
    mux.shutdown();
}

/// When the registry cannot tell whether a terminal is incognito, it is
/// treated as incognito (its screen does not reach the disk), its bytes
/// wait for an answer instead of being dropped, and a known answer is
/// kept, so the write pass does not ask SQLite again for every terminal.
#[cfg(unix)]
#[test]
fn an_unknown_terminal_keeps_its_screen_off_the_disk_until_the_registry_answers() {
    const TERMINAL: &str = "00000000000040008000000000000b01";
    const INCARNATION: &str = "10000000000040008000000000000b01";
    let session = Session::new("incognito-fail-closed");
    let mux = session.open();
    let directory = mux.output_store.directory().expect("a persistent session").to_path_buf();
    let (_, key) = workspace(&mux, "normal", "empty", false);
    let surface = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &key).unwrap();
    let public = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(TERMINAL)
        .unwrap()
        .expect("a public terminal id");
    let written = || {
        std::fs::read_dir(&directory)
            .map(|entries| {
                entries
                    .flatten()
                    .any(|entry| entry.file_name().to_string_lossy().starts_with(public.as_str()))
            })
            .unwrap_or(false)
    };
    let set_broken = |broken: bool| {
        let (from, to) = if broken {
            ("resource_terminals", "resource_terminals_broken")
        } else {
            ("resource_terminals_broken", "resource_terminals")
        };
        let (workspaces_from, workspaces_to) = if broken {
            ("resource_workspaces", "resource_workspaces_broken")
        } else {
            ("resource_workspaces_broken", "resource_workspaces")
        };
        mux.read_registry_state(|connection| {
            connection.execute_batch(&format!(
                "ALTER TABLE {from} RENAME TO {to}; ALTER TABLE {workspaces_from} RENAME TO {workspaces_to};"
            ))?;
            Ok(())
        })
        .unwrap();
    };
    // The registry cannot answer: fail closed.
    set_broken(true);
    assert!(mux.output_store.is_private(&mux, &public), "an unknown terminal reads as incognito");
    assert!(!mux.output_store.keeps_screen(&mux, &public));
    assert!(mux.workspace_key_is_ephemeral(&key), "an unknown workspace reads as incognito");
    let bytes = b"output while the registry is unreadable\r\n".to_vec();
    mux.surface(surface).unwrap().apply_stream_output_for_test(&bytes).unwrap();
    mux.output_store.append(&public, &Arc::from(INCARNATION), &bytes, None);
    mux.output_store.write_now(&mux);
    assert!(!written(), "nothing reaches the disk while the answer is unknown");
    // The registry answers: a normal terminal, and its output is written.
    set_broken(false);
    assert!(!mux.output_store.is_private(&mux, &public));
    assert!(!mux.workspace_key_is_ephemeral(&key));
    mux.output_store.write_now(&mux);
    assert!(written(), "the waiting output is written once the terminal is known normal");
    // The answer is kept: no registry read for it again.
    set_broken(true);
    assert!(!mux.output_store.is_private(&mux, &public), "a known normal terminal stays normal");
    set_broken(false);
    mux.shutdown();
}

/// The daemon's command history (`terminal-command-history-v1`, when on)
/// stored an incognito terminal's commands in SQLite.
#[cfg(unix)]
#[test]
fn an_incognito_terminal_commands_stay_out_of_the_command_history() {
    const NORMAL: &str = "00000000000040008000000000000c01";
    const PRIVATE: &str = "00000000000040008000000000000c02";
    const INCARNATIONS: [&str; 2] =
        ["10000000000040008000000000000c01", "10000000000040008000000000000c02"];
    let session = Session::new("incognito-command-history");
    let mux = session.open();
    mux.set_terminal_command_history(true, None).unwrap();
    let (_, normal_key) = workspace(&mux, "normal", "empty", false);
    let (_, private_key) = workspace(&mux, "private", "empty", true);
    let mut ids = Vec::new();
    for ((terminal, key), incarnation) in
        [(NORMAL, &normal_key), (PRIVATE, &private_key)].into_iter().zip(INCARNATIONS)
    {
        mux.seed_running_terminal_for_test(terminal, incarnation, key).unwrap();
        let public = mux
            .workspace_registry
            .lock()
            .unwrap()
            .terminal_resource_id(terminal)
            .unwrap()
            .expect("a public terminal id");
        mux.append_shell_commands(
            public.clone(),
            vec![crate::shell_history::FinishedCommand {
                command: Some(format!("echo secret-of-{terminal}")),
                cwd: None,
                exit_code: Some(0),
                // Now: an older row is past the retention and hidden.
                started_at_ms: crate::workspace_registry::unix_epoch_ms().unwrap(),
                duration_ms: 1,
            }],
        );
        ids.push(public);
    }
    // The worker runs a delete after every command queued before it.
    mux.delete_terminal_commands(
        crate::state::command_history_store::CommandDeletion::StartedSince(u64::MAX),
    )
    .unwrap();
    let listed = mux.list_terminal_commands(None, 100).unwrap();
    let terminals = listed["commands"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["terminal_id"].as_str().unwrap_or_default().to_string())
        .collect::<Vec<_>>();
    assert!(
        terminals.contains(&ids[0].to_string()),
        "a normal terminal's command is kept: {listed}"
    );
    assert!(
        !terminals.contains(&ids[1].to_string()),
        "an incognito terminal's command must not be kept: {listed}"
    );
    mux.shutdown();
}

/// A daemon that starts again adopts the terminals of the incognito
/// workspaces an earlier run left, then closes those workspaces (which
/// drops their flag) before it ends the terminals: their exit stored the
/// final screen, because nothing had marked the adopted terminals private.
#[cfg(unix)]
#[test]
fn an_adopted_incognito_terminal_closed_at_start_stores_no_screen() {
    const TERMINAL: &str = "00000000000040008000000000000d01";
    const INCARNATION: &str = "10000000000040008000000000000d01";
    let session = Session::new("incognito-adopted");
    let mux = session.open();
    let (_, key) = workspace(&mux, "private", "empty", true);
    let surface = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &key).unwrap();
    let public = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(TERMINAL)
        .unwrap()
        .expect("a public terminal id");
    // A fresh daemon's output store: the adopted terminal is not marked.
    mux.output_store.forget(&public);
    let bytes = b"secret output of an adopted terminal\r\n".to_vec();
    mux.surface(surface).unwrap().apply_stream_output_for_test(&bytes).unwrap();
    mux.close_ephemeral_workspaces().unwrap();
    assert!(
        mux.output_store.is_private(&mux, &public),
        "an adopted incognito terminal is private once its workspace closes"
    );
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1,
    };
    // Its exit, when one is still recorded after the close, keeps no screen.
    let _ = mux.persist_terminal_exit_for_test(&public, &exit);
    let registry = mux.workspace_registry.lock().unwrap();
    assert!(
        registry.terminal_exit_snapshot(public.as_str()).ok().flatten().is_none(),
        "an adopted incognito terminal's exit must store no screen"
    );
    drop(registry);
    mux.shutdown();
}

/// A terminal the registry has no row for (yet) is not known normal: it
/// reads as incognito, so its screen stays off the disk until the registry
/// knows it.
#[test]
fn a_terminal_with_no_registry_row_reads_as_incognito() {
    let session = Session::new("incognito-no-row");
    let mux = session.open();
    let unknown = crate::resource::TerminalPublicId::parse(format!("term_{:032x}", 0xb02)).unwrap();
    assert!(
        mux.output_store.is_private(&mux, &unknown),
        "an unclassified terminal reads as incognito"
    );
    assert!(!mux.output_store.keeps_screen(&mux, &unknown));
    mux.shutdown();
}

/// A normal terminal is known normal from its spawn, before its registry row
/// is committed: its first commands and output are kept even while the
/// registry cannot answer.
#[test]
fn a_normal_terminal_is_known_normal_from_its_spawn() {
    let session = Session::new("incognito-known-normal");
    let mux = session.open();
    let (_, key) = workspace(&mux, "normal", "terminal", false);
    let terminal = terminals_of(&mux, &key).pop().expect("a terminal");
    let public = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_resource_id(&terminal)
        .unwrap()
        .expect("a public terminal id");
    // The registry cannot answer, as before the row is committed.
    mux.read_registry_state(|connection| {
        connection
            .execute_batch("ALTER TABLE resource_terminals RENAME TO resource_terminals_hidden;")?;
        Ok(())
    })
    .unwrap();
    assert!(
        !mux.output_store.is_private(&mux, &public),
        "a spawned normal terminal is known normal"
    );
    mux.read_registry_state(|connection| {
        connection
            .execute_batch("ALTER TABLE resource_terminals_hidden RENAME TO resource_terminals;")?;
        Ok(())
    })
    .unwrap();
    mux.shutdown();
}
