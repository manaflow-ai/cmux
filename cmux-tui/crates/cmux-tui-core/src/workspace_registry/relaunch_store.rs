//! The per-terminal relaunch record (`terminal_relaunch`): the one source for
//! Reopen Closed and the daemon's L2 respawn of a terminal.
//!
//! One row per internal terminal id. It keeps what is needed to start the
//! terminal again, minus what looks like a credential:
//! - `cwd`: the launch directory, then each directory the shell reports with
//!   OSC 7 after the daemon validated it (a `file://` URL on this host, see
//!   `platform::terminal_pwd_to_local_path`). Only absolute paths are kept.
//! - `kind`: `shell` or `command`. A shell keeps its path (from the user's
//!   `SHELL` or the configured default, never from a later program); a
//!   command keeps its program basename. Shell-integration arguments and
//!   bundle paths are never stored: they go stale with every app update, and
//!   the host derives integration again from the current bundle when it
//!   starts the shell.
//! - `argv_json`: a command's argv, so a respawn by a later daemon (after a
//!   daemon crash, an update or a reboot) offers the command line like the
//!   daemon that launched it did, instead of only naming the program. This
//!   reverses the earlier rule that argv stayed in daemon memory only: losing
//!   the command after every daemon restart left command tabs with nothing to
//!   rerun. The risk that rule guarded against, argv carrying a credential, is
//!   cut down by [`stored_argv`]: an argv with a secret-named flag, a
//!   `name=value` argument with a secret name, a known token prefix, a long
//!   high-entropy value, a bearer token or URL password in a script, or a
//!   control character is not stored at all (dropping arguments would change
//!   what the command does), and neither is one over [`ARGV_CAP`] bytes. The argv is never typed or run
//!   again: the marker line only names it. It is not copied into the closed
//!   history: reopen never runs a command again, so it has no use there.
//! - `env`: values of the named keys in [`ENV_KEYS`] only, minus any key that
//!   names a secret ([`names_secret`]).
//! - `title`, `agent` (`{harness, session_id, args?, env?}`: the session
//!   the terminal's agent CLI runs, from its hooks, and how that CLI was
//!   started, see [`agent_launch`]), `updated_at_ms`.
//!
//! Rows of tombstoned terminals are removed when the registry opens. A closed
//! tab keeps its own copy in the closed history (`closed_fields`), so reopen
//! reads after the terminal row is gone.

use std::path::Path;

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Map, Value, json};

use super::WorkspaceRegistry;

mod agent_launch;
pub(crate) use agent_launch::{
    AGENT_JOB_ENV_KEYS, AgentLaunch, account_env_key, agent_launch_from_job,
    job_is_non_interactive, kept_agent_args, resumable_harness,
};

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

/// The largest argv (as JSON) a relaunch record stores; a longer one keeps
/// only its program name.
pub(crate) const ARGV_CAP: usize = 64 * 1024;

/// Prefixes of well-known tokens (OpenAI and Anthropic `sk-`, GitHub,
/// Slack `xox?-`). An argument or `name=value` value starting with one is
/// never stored.
pub(crate) const TOKEN_PREFIXES: &[&str] =
    &["sk-", "ghp_", "gho_", "ghs_", "ghu_", "github_pat_", "xox"];

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
    /// A command's argv without credential-like arguments ([`stored_argv`]).
    pub argv: Option<Vec<String>>,
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
        let (kind, shell_path, program, argv) = match argv {
            None => (RelaunchKind::Shell, Some(default_shell.to_string()), None, None),
            Some(argv) if is_interactive_shell(argv) => {
                (RelaunchKind::Shell, argv.first().cloned(), None, None)
            }
            Some(argv) => (
                RelaunchKind::Command,
                None,
                argv.first().map(|arg| basename(arg)),
                stored_argv(argv),
            ),
        };
        let mut env = env.iter().filter(|(key, _)| keeps_env_key(key)).cloned().collect::<Vec<_>>();
        env.sort();
        env.dedup_by(|later, earlier| later.0 == earlier.0);
        Self { cwd: cwd.and_then(absolute), kind, shell_path, program, argv, env }
    }
}

/// `argv` as a relaunch record keeps it, whole or not at all: None when any
/// argument looks like it carries a credential ([`carries_secret`]) or
/// holds a control character, for an empty argv, and for one over
/// [`ARGV_CAP`]. Dropping single arguments would change what the offered
/// command does (`find <path> -delete` offered as `find -delete`); without
/// an argv the marker names the program instead.
pub(crate) fn stored_argv(argv: &[String]) -> Option<Vec<String>> {
    let (_, arguments) = argv.split_first()?;
    if argv.iter().any(|argument| argument.chars().any(char::is_control))
        || arguments.iter().any(|argument| carries_secret(argument))
    {
        return None;
    }
    let size = serde_json::to_string(argv).map_or(usize::MAX, |json| json.len());
    (size <= ARGV_CAP).then(|| argv.to_vec())
}

/// Whether an argument may carry a credential: a flag whose name names a
/// secret ([`names_secret`]: `--token`, `--password`, `--api-key`, ...; its
/// value is the next argument), a `name=value` with such a name or a
/// token-like value, a token-like argument ([`looks_like_credential`]), or
/// text with a secret in it (a script for `sh -c`): a secret word next to
/// whitespace, an `Authorization`-style `Bearer`/`Basic` value, or a URL
/// with a password (`scheme://user:pass@host`).
fn carries_secret(argument: &str) -> bool {
    if argument.starts_with('-') && names_secret(argument.trim_start_matches('-')) {
        return true;
    }
    if let Some((name, value)) = argument.split_once('=')
        && (names_secret(name.trim_start_matches('-')) || looks_like_credential(value))
    {
        return true;
    }
    if looks_like_credential(argument) {
        return true;
    }
    if argument.split_whitespace().nth(1).is_some()
        && (names_secret(argument)
            || argument.split_whitespace().any(|word| word == "Bearer" || word == "Basic"))
    {
        return true;
    }
    argument.split("://").skip(1).any(|rest| {
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        authority.rsplit_once('@').is_some_and(|(user, _)| user.contains(':'))
    })
}

/// Whether `value` looks like a token: a known token prefix
/// ([`TOKEN_PREFIXES`]), or over 32 characters of token alphabet
/// (`A-Za-z0-9+=_.-`) mixing upper case, lower case and digits with at
/// least 4 bits of entropy per character. Paths (with `/`), URLs and hex
/// digests (no upper case) are not tokens.
fn looks_like_credential(value: &str) -> bool {
    if TOKEN_PREFIXES.iter().any(|prefix| value.starts_with(prefix)) {
        return true;
    }
    if value.len() <= 32
        || !value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"+=_.-".contains(&byte))
        || !value.bytes().any(|byte| byte.is_ascii_uppercase())
        || !value.bytes().any(|byte| byte.is_ascii_lowercase())
        || !value.bytes().any(|byte| byte.is_ascii_digit())
    {
        return false;
    }
    let mut counts = [0usize; 256];
    value.bytes().for_each(|byte| counts[usize::from(byte)] += 1);
    let length = value.len() as f64;
    let entropy: f64 = counts
        .iter()
        .filter(|&&count| count > 0)
        .map(|&count| {
            let share = count as f64 / length;
            -share * share.log2()
        })
        .sum();
    entropy >= 4.0
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
pub(crate) fn is_interactive_shell(argv: &[String]) -> bool {
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
    // Added after the table shipped: rows of an older daemon read no argv.
    super::mutation_ledger::add_nullable_column(transaction, "terminal_relaunch", "argv_json")?;
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
        self.connection.get().execute(
            "INSERT INTO terminal_relaunch(
               terminal_id, cwd, kind, shell_path, program, env_json, updated_at_ms, argv_json
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(terminal_id) DO NOTHING",
            params![
                terminal_id,
                record.cwd,
                record.kind.as_str(),
                record.shell_path,
                record.program,
                Value::Object(env.collect::<Map<_, _>>()).to_string(),
                now_ms()?,
                record.argv.as_ref().map(|argv| json!(argv).to_string()),
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
        self.connection.get().execute(
            "UPDATE terminal_relaunch SET cwd = ?2, updated_at_ms = ?3 WHERE terminal_id = ?1",
            params![terminal_id, cwd, now_ms()?],
        )?;
        Ok(())
    }
}

/// A terminal's stored relaunch record, as the L2 respawn reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct StoredRelaunch {
    pub cwd: Option<String>,
    pub kind: RelaunchKind,
    pub shell_path: Option<String>,
    pub program: Option<String>,
    /// A command's argv as stored, filtered again on read ([`stored_argv`]).
    pub argv: Option<Vec<String>>,
    pub env: Vec<(String, String)>,
    /// `(harness, session_id)` of the agent the terminal last ran.
    pub agent: Option<(String, String)>,
    /// How that agent's CLI was started, when it was read at its session start.
    pub agent_launch: Option<AgentLaunch>,
}

/// Whether `session_id` may be stored and offered to a resume command:
/// 1 to 128 of `[A-Za-z0-9._-]`.
pub(crate) fn resumable_session_id(session_id: &str) -> bool {
    (1..=128).contains(&session_id.len())
        && session_id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
}

impl WorkspaceRegistry {
    /// The relaunch record of terminal `terminal_id`, if one was stored.
    pub(crate) fn terminal_relaunch_record(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<StoredRelaunch>> {
        let row = self
            .connection
            .get()
            .query_row(
                "SELECT cwd, kind, shell_path, program, env_json, agent_json, argv_json
                 FROM terminal_relaunch WHERE terminal_id = ?1",
                [terminal_id],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                    ))
                },
            )
            .optional()?;
        let Some((cwd, kind, shell_path, program, env, agent, argv)) = row else {
            return Ok(None);
        };
        let kind = if kind == "command" { RelaunchKind::Command } else { RelaunchKind::Shell };
        let env: Value = serde_json::from_str(&env).context("terminal_relaunch env is not JSON")?;
        let env = env
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(key, _)| keeps_env_key(key))
            .filter_map(|(key, value)| value.as_str().map(|value| (key.clone(), value.into())))
            .collect();
        let agent = agent
            .and_then(|agent| serde_json::from_str::<Value>(&agent).ok())
            .filter(|agent| agent[NON_INTERACTIVE] != true);
        let agent_launch = agent.as_ref().and_then(stored_agent_launch);
        let agent = agent.and_then(|agent| {
            let harness = agent["harness"].as_str()?.to_string();
            let session_id = agent["session_id"].as_str()?.to_string();
            resumable_session_id(&session_id).then_some((harness, session_id))
        });
        let argv = argv
            .filter(|_| kind == RelaunchKind::Command)
            .and_then(|argv| serde_json::from_str::<Vec<String>>(&argv).ok())
            .and_then(|argv| stored_argv(&argv));
        let cwd = cwd.and_then(|cwd| absolute(&cwd));
        let agent_launch = agent_launch.filter(|_| agent.is_some());
        Ok(Some(StoredRelaunch { cwd, kind, shell_path, program, argv, env, agent, agent_launch }))
    }

    /// Record (`Some`) or forget (`None`) the agent session terminal
    /// `terminal_public_id` runs, from its agent hooks, with how its CLI was
    /// started (`launch`) when that was read: at its session start. Without
    /// one, what is already stored for the same session is kept: its launch,
    /// or that it is a non-interactive run (`AgentStart::NonInteractive`),
    /// which no respawn resumes. An id that is not resumable is never stored.
    pub(crate) fn record_terminal_relaunch_agent(
        &mut self,
        terminal_public_id: &str,
        agent: Option<(&str, &str)>,
        start: AgentStart<'_>,
    ) -> anyhow::Result<()> {
        let agent = match agent {
            Some((harness, session_id)) if resumable_session_id(session_id) => {
                // A failed lookup costs only what was stored, never the agent record.
                let stored = match start {
                    AgentStart::Unknown => {
                        self.stored_agent_of(terminal_public_id, harness, session_id).ok().flatten()
                    }
                    _ => None,
                };
                let non_interactive = matches!(start, AgentStart::NonInteractive)
                    || stored.as_ref().is_some_and(|agent| agent[NON_INTERACTIVE] == true);
                let kept = match start {
                    AgentStart::Launch(launch) => Some(launch.clone()),
                    _ => stored.as_ref().and_then(stored_agent_launch),
                };
                let mut record = json!({"harness": harness, "session_id": session_id});
                if non_interactive {
                    record[NON_INTERACTIVE] = json!(true);
                } else if let Some(launch) = kept {
                    record["args"] = json!(launch.args);
                    record["env"] = Value::Object(
                        launch.env.into_iter().map(|(key, value)| (key, json!(value))).collect(),
                    );
                }
                Some(record.to_string())
            }
            Some(_) => return Ok(()),
            None => None,
        };
        self.connection.get().execute(
            "UPDATE terminal_relaunch SET agent_json = ?2, updated_at_ms = ?3
             WHERE terminal_id = (
               SELECT terminal_id FROM resource_terminals
               WHERE public_id = ?1 AND deleted_revision IS NULL
             )",
            params![terminal_public_id, agent, now_ms()?],
        )?;
        Ok(())
    }
}

/// What a session-start hook read of how the agent's CLI was started.
#[derive(Debug, Clone, Copy)]
pub(crate) enum AgentStart<'a> {
    /// Not read (a later hook, or the process could not be read).
    Unknown,
    /// An interactive session, started like this.
    Launch(&'a AgentLaunch),
    /// A non-interactive run (`claude -p`, `codex exec`): nothing to resume.
    NonInteractive,
}

/// The agent record field that marks a non-interactive run's session.
const NON_INTERACTIVE: &str = "non_interactive";

impl WorkspaceRegistry {
    /// The agent record stored for `harness` session `session_id` of terminal
    /// `terminal_public_id`, if that is the session its record names.
    fn stored_agent_of(
        &self,
        terminal_public_id: &str,
        harness: &str,
        session_id: &str,
    ) -> anyhow::Result<Option<Value>> {
        let stored = self
            .connection
            .get()
            .query_row(
                "SELECT r.agent_json FROM terminal_relaunch r
                 JOIN resource_terminals t ON t.terminal_id = r.terminal_id
                 WHERE t.public_id = ?1 AND t.deleted_revision IS NULL",
                [terminal_public_id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten()
            .and_then(|agent| serde_json::from_str::<Value>(&agent).ok());
        Ok(stored.filter(|agent| agent["harness"] == harness && agent["session_id"] == session_id))
    }
}

/// The launch in a stored agent record, filtered again as on write: its
/// arguments only when none looks like a credential, its environment only the
/// harness's account directory.
fn stored_agent_launch(agent: &Value) -> Option<AgentLaunch> {
    let harness = agent["harness"].as_str()?;
    let args = agent.get("args")?.as_array()?;
    let args =
        args.iter().map(|arg| arg.as_str().map(str::to_string)).collect::<Option<Vec<_>>>()?;
    if !resumable_harness(harness) {
        return None;
    }
    let args = kept_agent_args(harness, &args);
    let env = account_env_key(harness)
        .and_then(|key| Some((key, agent["env"][key].as_str()?)))
        .filter(|(_, dir)| Path::new(dir).is_absolute() && !dir.chars().any(char::is_control))
        .map(|(key, dir)| vec![(key.to_string(), dir.to_string())])
        .unwrap_or_default();
    Some(AgentLaunch { args, env })
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
