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
        let mut rows =
            connection.prepare("SELECT terminal_id FROM terminal_hosts WHERE workspace_key = ?1")?;
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
