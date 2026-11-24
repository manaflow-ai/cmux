//! `cmux link offload`: runs one local command on a Cloud machine over this folder's view, then
//! publishes what it wrote back here (RFD 0007, build order step 7, "Offload"; Leo, 2026-11-22:
//! "being able to auto-offload shit, having things be fucking extension arms of your computer").
//!
//! No copy step and no new transport. It composes three pieces that already ship, all over the
//! one machine socket every `cmux link` command takes (`--socket`, the app's link to the machine):
//!
//! 1. **View**: the folder is projected at a mount of its own on the machine
//!    ([`super::project::start`]): a stat-only manifest goes, and a file's bytes come from here the
//!    first time the command reads it. The machine's writes land in the view's upper layer.
//! 2. **Run**: the command runs in the mount through the machine daemon's shell mode
//!    (`shell-run`, `shell-read`, `shell-runs-v1`): the person's login shell, `-l -c COMMAND`,
//!    stdout and stderr in one pipe, streamed here as it comes, and its exit code is this
//!    command's.
//! 3. **Publish**: Bring Back of the view ([`super::project_back::bring_back`]): only the files the
//!    command wrote or deleted come here, planned against the manifest it started from; a file
//!    changed here meanwhile is a named conflict, never overwritten. Then the machine frees the
//!    view and this Mac stops its server (unless `--keep`).
//!
//! ```text
//! cmux link offload --socket S [--at REMOTE] [--cwd FOLDER] [--keep] -- COMMAND [ARG]...
//! ```
//!
//! The command's output is stdout (text: the machine's shell mode reads it as UTF-8). When it
//! ends, one JSON line on stderr: `{"ok", "exit", "at", "published"|"conflicts"|"error",
//! "phases": {"view_ms", "run_ms", "publish_ms"}, "total_ms"}`. The exit code is the command's;
//! a command that exited 0 whose outputs did not come back exits 1.
//!
//! An interrupted offload (Ctrl-C here) closes the connection, which hangs the command up on the
//! machine; its view stays there, and `cmux link project back --socket S --at REMOTE FOLDER`
//! brings its writes back later.

use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context as _, bail};
use serde_json::{Map, Value, json};

use super::Back;
use super::remote::Remote;

/// The daemon capability that carries `shell-run`, `shell-read` and `shell-stop`.
const SHELL_RUNS: &str = "shell-runs-v1";
/// The shell-mode scope offloaded commands count against (its running cap is per scope).
const SCOPE: &str = "offload";
/// How long one `shell-read` waits on the machine for output (its own cap is 10 s).
const READ_WAIT_MS: u64 = 5_000;
/// Where a view is mounted when `--at` is not given: under the machine's home.
const MOUNTS: &str = ".cmux/offload";

/// What `cmux link offload` was asked.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Args {
    pub(crate) socket: PathBuf,
    pub(crate) at: Option<String>,
    pub(crate) folder: Option<PathBuf>,
    pub(crate) keep: bool,
    pub(crate) argv: Vec<String>,
}

pub(crate) const USAGE: &str =
    "usage: cmux link offload --socket S [--at REMOTE] [--cwd FOLDER] [--keep] -- COMMAND [ARG]...";

pub(crate) fn parse(args: &[String]) -> anyhow::Result<Args> {
    let split = args.iter().position(|word| word == "--").context(USAGE)?;
    let (options, rest) = args.split_at(split);
    let command = rest.get(1..).unwrap_or_default();
    let (mut socket, mut at, mut folder, mut keep) = (None, None, None, false);
    let mut words = options.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--socket" => socket = Some(PathBuf::from(words.next().context(USAGE)?)),
            "--at" => at = Some(words.next().context(USAGE)?.clone()),
            "--cwd" => folder = Some(PathBuf::from(words.next().context(USAGE)?)),
            "--keep" => keep = true,
            other => bail!("unknown option {other}\n{USAGE}"),
        }
    }
    if command.is_empty() {
        bail!("no command to run\n{USAGE}");
    }
    if let Some(at) = &at
        && !at.starts_with('/')
    {
        bail!("--at is an absolute path on the machine");
    }
    Ok(Args { socket: socket.context(USAGE)?, at, folder, keep, argv: command.to_vec() })
}

/// `argv` as one POSIX shell command line: each word single-quoted unless it is plainly safe.
pub(crate) fn shell_line(argv: &[String]) -> String {
    argv.iter()
        .map(|word| {
            let plain = !word.is_empty()
                && word
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_./=:,+@%".contains(&byte));
            if plain { word.clone() } else { format!("'{}'", word.replace('\'', r"'\''")) }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A key of this offload's own: its projection is `chat-<key>` and its mount ends in it, so two
/// offloads of one folder never share an upper layer.
fn new_key() -> String {
    let mut random = [0u8; 8];
    let _ = getrandom::fill(&mut random);
    format!("offload-{:016x}", u64::from_le_bytes(random))
}

/// The run id the machine is asked to use (`run_` and 32 lowercase hex digits).
fn new_run_id() -> String {
    let mut random = [0u8; 16];
    let _ = getrandom::fill(&mut random);
    format!("run_{:032x}", u128::from_le_bytes(random))
}

/// The default mount for `folder` under the machine's `home`: `<home>/.cmux/offload/<name>-<key>`.
pub(crate) fn default_at(home: &str, folder: &Path, key: &str) -> String {
    let name: String = folder
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .take(40)
        .collect();
    let name = if name.is_empty() { "folder".to_owned() } else { name };
    format!("{}/{MOUNTS}/{name}-{}", home.trim_end_matches('/'), key.trim_start_matches("offload-"))
}

fn ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// `cmux link offload ...`: the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    let started = Instant::now();
    let parsed = match parse(args) {
        Ok(parsed) => parsed,
        Err(error) => {
            eprintln!(
                "{}",
                json!({"ok": false, "error": format!("{error:#}"), "error_code": "usage"})
            );
            return 64;
        }
    };
    match offload(&parsed, started) {
        Ok((code, line)) => {
            eprintln!("{line}");
            code
        }
        Err(error) => {
            eprintln!(
                "{}",
                json!({"ok": false, "error": format!("{error:#}"), "error_code": "offload_failed"})
            );
            1
        }
    }
}

/// The offload itself: the command's exit code and the summary line.
fn offload(parsed: &Args, started: Instant) -> anyhow::Result<(i32, Value)> {
    let folder = match &parsed.folder {
        Some(folder) => folder.clone(),
        None => std::env::current_dir().context("no working directory")?,
    };
    let folder = std::fs::canonicalize(&folder)
        .with_context(|| format!("cannot open {}", folder.display()))?;
    let socket = parsed.socket.as_path();
    let mut machine = Remote::connect(socket)?;
    let identity = machine.call("identify", json!({}))?;
    let serves = |name: &str| {
        identity
            .get("capabilities")
            .and_then(Value::as_array)
            .is_some_and(|all| all.iter().any(|c| c == name))
    };
    if !serves(SHELL_RUNS) {
        bail!("the machine runs no commands for this link ({SHELL_RUNS}); update it");
    }
    let key = new_key();
    let at = match &parsed.at {
        Some(at) => at.clone(),
        None => default_at(&machine_home(&mut machine)?, &folder, &key),
    };

    let view_started = Instant::now();
    match super::project::start(socket, &folder, &at, &key)? {
        Ok(_) => {}
        Err(super::project::NotProjected::Off) => bail!(
            "projected folders are off here (`cmux link project enable`, or CMUX_PROJECTED_FOLDERS=1)"
        ),
        Err(super::project::NotProjected::Unserved) => {
            bail!("the machine mounts no projected folders (projection-v1); update it")
        }
        Err(super::project::NotProjected::Small) => bail!("the machine refused the view"),
    }
    let view_ms = ms(view_started);

    let run_started = Instant::now();
    let ran = run_there(&mut machine, &parsed.argv, &at);
    drop(machine);
    let run_ms = ms(run_started);

    let publish_started = Instant::now();
    let found = super::project_back::recorded(&folder, &at)
        .context("this Mac kept no record of the view to publish from")?;
    let back = super::project_back::bring_back(socket, &found, parsed.keep);
    let publish_ms = ms(publish_started);

    let exit = match &ran {
        Ok(code) => json!(code),
        Err(_) => Value::Null,
    };
    let mut line = Map::new();
    line.insert("ok".into(), json!(false));
    line.insert("exit".into(), exit);
    line.insert("at".into(), json!(at));
    line.insert(
        "phases".into(),
        json!({"view_ms": view_ms, "run_ms": run_ms, "publish_ms": publish_ms}),
    );
    let published = match back {
        Back::Done(summary) => {
            line.insert("published".into(), summary);
            true
        }
        Back::Conflict(conflicts, reasons) => {
            line.insert("error_code".into(), json!("sync_conflict"));
            let error = format!(
                "{}: nothing was brought back ({})",
                conflicts.join(", "),
                reasons.join("; ")
            );
            line.insert("error".into(), json!(error));
            line.insert("conflicts".into(), json!(conflicts));
            false
        }
        Back::Failed { code, error } => {
            line.insert("error_code".into(), json!(code));
            line.insert("error".into(), json!(error));
            false
        }
    };
    let code = match ran {
        Ok(code) => code,
        Err(error) => {
            line.insert("error_code".into(), json!("run_failed"));
            line.insert("error".into(), json!(format!("{error:#}")));
            1
        }
    };
    line.insert("ok".into(), json!(published && code == 0));
    line.insert("total_ms".into(), json!(ms(started)));
    let code = if code == 0 && !published { 1 } else { code };
    Ok((code, Value::Object(line)))
}

/// The machine's home: the last line its login shell prints for `$HOME` (a profile may print
/// before it).
fn machine_home(machine: &mut Remote) -> anyhow::Result<String> {
    let mut out = Vec::new();
    let code = shell(machine, "printf '\\n%s\\n' \"$HOME\"", "~", &mut out)?;
    let text = String::from_utf8_lossy(&out);
    let home = text.lines().rev().find(|line| !line.trim().is_empty()).unwrap_or_default().trim();
    if code != 0 || !home.starts_with('/') {
        bail!("cannot read the machine's home (exit {code}); give --at");
    }
    Ok(home.to_owned())
}

/// Runs `argv` in `at` on the machine, its output to stdout as it comes; its exit code.
fn run_there(machine: &mut Remote, argv: &[String], at: &str) -> anyhow::Result<i32> {
    let mut stdout = std::io::stdout();
    shell(machine, &shell_line(argv), at, &mut stdout)
}

/// One `shell-run` of `command` in `cwd`, read to its end into `out`: its exit code (128 plus
/// the signal for one a signal ended).
fn shell(
    machine: &mut Remote,
    command: &str,
    cwd: &str,
    out: &mut dyn std::io::Write,
) -> anyhow::Result<i32> {
    let run = new_run_id();
    let answer = machine
        .call("shell-run", json!({"command": command, "cwd": cwd, "scope": SCOPE, "run": run}))?;
    if let Some(refused) = answer.get("refused").and_then(Value::as_str) {
        bail!("the machine refused the command: {refused}");
    }
    let mut after = 0u64;
    loop {
        let chunk = machine
            .call("shell-read", json!({"run": run, "after": after, "wait_ms": READ_WAIT_MS}))?;
        if let Some(refused) = chunk.get("refused").and_then(Value::as_str) {
            if refused == "busy" {
                continue;
            }
            bail!("the machine stopped answering for the command: {refused}");
        }
        if let Some(text) = chunk.get("output").and_then(Value::as_str)
            && !text.is_empty()
        {
            out.write_all(text.as_bytes())?;
            out.flush()?;
        }
        if chunk.get("truncated").and_then(Value::as_bool) == Some(true) {
            eprintln!(
                "cmux link offload: some output was dropped on the machine (over 1 MiB unread)"
            );
        }
        after = chunk.get("next").and_then(Value::as_u64).unwrap_or(after);
        if let Some(exit) = chunk.get("exit") {
            if let Some(code) = exit.get("code").and_then(Value::as_i64) {
                return Ok(i32::try_from(code).unwrap_or(1));
            }
            let signal = exit.get("signal").and_then(Value::as_i64).unwrap_or(0);
            return Ok(128 + i32::try_from(signal).unwrap_or(0));
        }
    }
}

#[cfg(test)]
#[path = "offload_tests.rs"]
mod tests;
