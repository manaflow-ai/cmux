//! The per-terminal relaunch record (`terminal_relaunch`): the one source for
//! Reopen Closed and the daemon's L2 respawn of a terminal.
//!
//! One row per internal terminal id. It keeps what is needed to start the
//! terminal again and nothing that can carry a credential:
//! - `cwd`: the launch directory, then each directory the shell reports with
//!   OSC 7 after the daemon validated it (a `file://` URL on this host, see
//!   `platform::terminal_pwd_to_local_path`). Only absolute paths are kept.
//! - `kind`: `shell` or `command`. A shell keeps its path (from the user's
//!   `SHELL` or the configured default, never from a later program); a
//!   command keeps only its program basename. The full argv stays in daemon
//!   memory. Shell-integration arguments and bundle paths are never stored:
//!   they go stale with every app update, and the host derives integration
//!   again from the current bundle when it starts the shell.
//! - `env`: values of the named keys in [`ENV_KEYS`] only, minus any key that
//!   names a secret ([`names_secret`]).
//! - `title`, `agent` (`{harness, session_id}`), `updated_at_ms`.
//!
//! Rows of tombstoned terminals are removed when the registry opens. A closed
//! tab keeps its own copy in the closed history (`closed_fields`), so reopen
//! reads after the terminal row is gone.

use std::path::Path;

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, Value, json};

use super::WorkspaceRegistry;

/// The environment keys a relaunch record keeps, by exact name.
///
/// - `TERM`, `TERMINFO`, `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`:
///   the terminal identity the app gave the shell, so programs see the same
///   terminal after reopen (`TERM` is replayed only with a usable `TERMINFO`).
/// - `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, `CMUX_TAG`: which app owns the
///   terminal, so the `cmux` CLI in the reopened shell talks to that app.
///
/// Per-terminal identities (`CMUX_SURFACE_ID`, `CMUX_TAB_ID`, `CMUX_PANEL_ID`,
/// `CMUX_PANE_ID`, `CMUX_WORKSPACE_ID`) are left out: a reopened terminal gets
/// new ids and its creator sets them again; a stale id would point the CLI at
/// the wrong surface.
pub(crate) const ENV_KEYS: &[&str] = &[
    "TERM",
    "TERMINFO",
    "COLORTERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
    "CMUX_SOCKET_PATH",
    "CMUX_BUNDLE_ID",
    "CMUX_TAG",
];

/// Words that mark a key as a secret, matched case-insensitively anywhere in
/// the key. A matching key is never stored, even when it is allowlisted.
const SECRET_WORDS: &[&str] =
    &["TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "COOKIE", "CREDENTIAL"];

/// Shells whose argv may still be "the user's shell" with integration flags.
const SHELLS: &[&str] = &["bash", "zsh", "fish", "nu", "elvish", "sh", "dash", "ksh", "tcsh"];

pub(crate) fn names_secret(key: &str) -> bool {
    let key = key.to_ascii_uppercase();
    SECRET_WORDS.iter().any(|word| key.contains(word))
}

fn keeps_env_key(key: &str) -> bool {
    ENV_KEYS.contains(&key) && !names_secret(key)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RelaunchKind {
    Shell,
    Command,
}

impl RelaunchKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Shell => "shell",
            Self::Command => "command",
        }
    }
}

/// What a terminal's launch contributes to its relaunch record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RelaunchRecord {
    pub cwd: Option<String>,
    pub kind: RelaunchKind,
    pub shell_path: Option<String>,
    pub program: Option<String>,
    pub env: Vec<(String, String)>,
}

impl RelaunchRecord {
    /// The record of a terminal launched in `cwd` running `argv` (None: the
    /// default shell `default_shell`) with environment `env`.
    pub(crate) fn from_launch(
        cwd: Option<&str>,
        argv: Option<&[String]>,
        default_shell: &str,
        env: &[(String, String)],
    ) -> Self {
        let (kind, shell_path, program) = match argv {
            None => (RelaunchKind::Shell, Some(default_shell.to_string()), None),
            Some(argv) if is_interactive_shell(argv) => {
                (RelaunchKind::Shell, argv.first().cloned(), None)
            }
            Some(argv) => (RelaunchKind::Command, None, argv.first().map(|arg| basename(arg))),
        };
        let mut env = env.iter().filter(|(key, _)| keeps_env_key(key)).cloned().collect::<Vec<_>>();
        env.sort();
        env.dedup_by(|later, earlier| later.0 == earlier.0);
        Self { cwd: cwd.and_then(absolute), kind, shell_path, program, env }
    }
}

fn basename(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map_or_else(|| path.to_string(), |name| name.to_string_lossy().into_owned())
}

fn absolute(path: &str) -> Option<String> {
    Path::new(path).is_absolute().then(|| path.to_string())
}

/// Whether `argv` starts the user's interactive shell: a known shell with
/// only flags (`--posix`, `-l`, ...) and nushell's integration `--execute
/// 'use ghostty *'`. A command flag (`-c`, `-lc`, `--command`) or a script
/// argument makes it a command.
fn is_interactive_shell(argv: &[String]) -> bool {
    let Some((program, arguments)) = argv.split_first() else { return false };
    if !SHELLS.contains(&basename(program).as_str()) {
        return false;
    }
    let mut arguments = arguments.iter();
    while let Some(argument) = arguments.next() {
        if argument == "--execute" {
            match arguments.next() {
                Some(code) if code.starts_with("use ghostty") => continue,
                _ => return false,
            }
        }
        let short_command =
            argument.starts_with('-') && !argument.starts_with("--") && argument.contains('c');
        if !argument.starts_with('-') || short_command || argument == "--command" {
            return false;
        }
    }
    true
}

pub(super) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_relaunch (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           cwd TEXT,
           kind TEXT NOT NULL CHECK(kind IN ('shell','command')),
           shell_path TEXT,
           program TEXT,
           env_json TEXT NOT NULL DEFAULT '{}',
           title TEXT,
           agent_json TEXT,
           updated_at_ms INTEGER NOT NULL
         );
         DELETE FROM terminal_relaunch WHERE terminal_id IN (
           SELECT terminal_id FROM terminal_hosts WHERE lifecycle = 'tombstoned'
         );",
    )?;
    Ok(())
}

fn now_ms() -> anyhow::Result<i64> {
    Ok(i64::try_from(super::session_journal::unix_epoch_ms()?)?)
}

impl WorkspaceRegistry {
    /// Record a launched terminal. A replayed launch of the same id keeps the
    /// existing row, so a directory reported since is not lost.
    pub(crate) fn record_terminal_relaunch(
        &mut self,
        terminal_id: &str,
        record: &RelaunchRecord,
    ) -> anyhow::Result<()> {
        let env = record.env.iter().map(|(key, value)| (key.clone(), json!(value)));
        self.connection.execute(
            "INSERT INTO terminal_relaunch(
               terminal_id, cwd, kind, shell_path, program, env_json, updated_at_ms
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(terminal_id) DO NOTHING",
            params![
                terminal_id,
                record.cwd,
                record.kind.as_str(),
                record.shell_path,
                record.program,
                Value::Object(env.collect::<Map<_, _>>()).to_string(),
                now_ms()?,
            ],
        )?;
        Ok(())
    }

    /// The shell reported `cwd` (already validated as a local directory). A
    /// cleared report keeps the last directory.
    pub(crate) fn record_terminal_relaunch_cwd(
        &mut self,
        terminal_id: &str,
        cwd: Option<&str>,
    ) -> anyhow::Result<()> {
        let Some(cwd) = cwd.and_then(absolute) else { return Ok(()) };
        self.connection.execute(
            "UPDATE terminal_relaunch SET cwd = ?2, updated_at_ms = ?3 WHERE terminal_id = ?1",
            params![terminal_id, cwd, now_ms()?],
        )?;
        Ok(())
    }
}

/// The relaunch fields a closed tab keeps for the terminal `terminal_public_id`.
pub(crate) fn closed_fields(
    connection: &Connection,
    terminal_public_id: &str,
) -> anyhow::Result<Option<Value>> {
    let row = connection
        .query_row(
            "SELECT r.cwd, r.kind, r.shell_path, r.program, r.env_json
             FROM resource_terminals AS t JOIN terminal_relaunch AS r
               ON r.terminal_id = t.terminal_id
             WHERE t.public_id = ?1",
            [terminal_public_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .optional()?;
    let Some((cwd, kind, shell_path, program, env)) = row else { return Ok(None) };
    let env: Value = serde_json::from_str(&env).context("terminal_relaunch env is not JSON")?;
    Ok(Some(json!({
        "cwd": cwd, "kind": kind, "shell_path": shell_path, "program": program, "env": env,
    })))
}

/// How reopen starts a closed terminal tab: its directory when that is still
/// an absolute directory (else the default), and its allowlisted environment.
/// Both kinds start the default shell, which the host integrates; a command
/// is never run again.
pub(crate) fn replay(tab: &Value) -> (Option<String>, Vec<(String, String)>) {
    let cwd = tab["cwd"].as_str().and_then(absolute).filter(|path| Path::new(path).is_dir());
    let env = tab["relaunch"]["env"].as_object().cloned().unwrap_or_default();
    let terminfo_usable =
        env.get("TERMINFO").and_then(Value::as_str).is_none_or(|path| Path::new(path).is_dir());
    let env = env
        .into_iter()
        .filter(|(key, _)| keeps_env_key(key))
        .filter(|(key, _)| key != "TERMINFO" || terminfo_usable)
        .filter(|(key, _)| key != "TERM" || terminfo_usable)
        .filter_map(|(key, value)| value.as_str().map(|value| (key, value.to_string())))
        .collect();
    (cwd, env)
}

#[cfg(test)]
#[path = "relaunch_store_tests.rs"]
mod tests;
