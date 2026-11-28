//! Harness magic `speculative` (RFD 0158 §4), first piece: the lane's own type check after an
//! edit, run before the lane asks for it and served from that run when it does.
//!
//! What the lane will almost certainly ask for next: the check it ran last. A session's last
//! foreground check command ([`is_check`]: `cargo check`/`clippy`, `tsc --noEmit`, optionally
//! after `cd DIR &&` and piped into a read-only filter) is remembered by the daemon
//! (`hub/speculative.rs`). When the session's edit tool calls go quiet, the daemon runs that same
//! command line in the session's folder, niced and bounded, and keeps its output and exit code
//! here ([`store`]), stamped with the folder's [`fingerprint`] taken before and after (a run
//! the tree moved under is dropped).
//!
//! The Bash hook (`bg_hook.rs`) puts this binary's `spec-serve --` before a call whose folder and
//! command line have a kept run ([`has_record`]). The wrapper ([`main`]) takes the fingerprint
//! again: unchanged, it prints the kept output and exits with the kept code; anything else (a
//! change, a missing or unreadable record, no git) runs the command as asked. So a served call
//! answers what the same call would have answered at that tree, in its time to read a file.
//!
//! Off unless `agents.harnessMagic.speculative.enabled` is `true` (Leo 2026-11-26 on the
//! call-answering features: "only do it for our personal fleet situation");
//! `ACPMUX_HM_SPECULATIVE` `0` turns it off and `1` on, over the setting. Fails open.

use cmux_process::{Command, Stdio};
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

/// The subcommand the hook puts before the call.
pub const SUBCOMMAND: &str = "spec-serve";
/// The setting that turns it on (off unless `true`).
pub const SETTING_ENABLED: &str = "agents.harnessMagic.speculative.enabled";
/// The daemon's switch, over the setting.
pub const KILL_ENV: &str = "ACPMUX_HM_SPECULATIVE";
/// The feature's name in `harnessMagic` (stamp and counters).
pub const FEATURE: &str = "speculative";

/// A kept run older than this is not served.
pub(crate) const KEEP_FOR: Duration = Duration::from_secs(6 * 3600);
/// The fingerprint's `git` reads' bound.
const GIT_BOUND: Duration = Duration::from_secs(10);

/// Whether the feature is on for `doc` and the switch's value `env`.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

/// Whether the feature is on now.
pub(crate) fn enabled() -> bool {
    let doc = match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    enabled_with(doc.as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// Whether `command` is a check this feature may run on its own: one `cargo check`, `cargo
/// clippy` or `tsc --noEmit` (bare, `npx`/`bunx`/`pnpm exec`), optionally after `cd DIR &&`,
/// optionally with `2>&1` and piped into `head`, `tail`, `grep`, `rg`, `wc` or `sort`. Nothing
/// that writes a file the lane reads: no other redirect, no `;`, no other `&&`, no
/// substitution.
pub fn is_check(command: &str) -> bool {
    let c = command.trim();
    if c.is_empty()
        || c.len() > 400
        || c.contains(['`', ';', '\n', '<', '$', '(', ')', '{', '}', '\\', '\'', '"'])
    {
        return false;
    }
    let c = c.replace("2>&1", " ");
    if c.contains('>') {
        return false;
    }
    let mut parts = c.split('|').map(str::trim);
    let Some(head) = parts.next() else { return false };
    if !parts.all(|p| {
        let first = p.split_whitespace().next().unwrap_or("");
        !p.contains('&') && matches!(first, "head" | "tail" | "grep" | "rg" | "wc" | "sort")
    }) {
        return false;
    }
    let mut steps = head.split("&&").map(str::trim);
    let Some(mut step) = steps.next() else { return false };
    if let Some(rest) = step.strip_prefix("cd ") {
        if rest.split_whitespace().count() != 1 {
            return false;
        }
        let Some(next) = steps.next() else { return false };
        step = next;
    }
    if steps.next().is_some() || step.contains('&') {
        return false;
    }
    let words: Vec<&str> = step.split_whitespace().collect();
    let words = match words.as_slice() {
        ["npx" | "bunx", rest @ ..] | ["pnpm", "exec", rest @ ..] => rest,
        all => all,
    };
    match words {
        ["cargo", "check" | "clippy", ..] => true,
        ["tsc", rest @ ..] => rest.contains(&"--noEmit"),
        _ => false,
    }
}

fn dir() -> Option<PathBuf> {
    Some(dirs::cache_dir()?.join("acpmux").join("speculative"))
}

/// The record path of `command` run in `cwd`, under `dir`.
pub(crate) fn record_path(dir: &Path, cwd: &Path, command: &str) -> PathBuf {
    let key = json!([cwd.to_string_lossy(), command.trim()]).to_string();
    dir.join(format!("{}.json", crate::sha256::sha256_hex(key.as_bytes())))
}

fn git(cwd: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let mut out = tempfile::tempfile().ok()?;
    let mut child = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(out.try_clone().ok()?)
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    match child.wait_timeout(GIT_BOUND) {
        Ok(Some(s)) if s.success() => {}
        _ => return None,
    }
    use std::io::{Read, Seek};
    let mut bytes = Vec::new();
    out.rewind().ok()?;
    out.read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

/// What the tree under `cwd` holds, as one hash: its git `HEAD`, its `git status` (staged,
/// unstaged, untracked) and each changed path's size and modification time, so a second edit
/// to an already-changed file moves it too. `None` outside a git work tree or past the bound:
/// then nothing is kept or served.
pub(crate) fn fingerprint(cwd: &Path) -> Option<String> {
    let head = git(cwd, &["rev-parse", "HEAD"])?;
    let top = git(cwd, &["rev-parse", "--show-toplevel"])?;
    let top = PathBuf::from(String::from_utf8_lossy(&top).trim());
    let status = git(cwd, &["status", "--porcelain=v1", "-z", "--untracked-files=all"])?;
    let mut text = String::from_utf8_lossy(&head).into_owned();
    text.push('\0');
    text.push_str(&String::from_utf8_lossy(&status));
    for entry in status.split(|b| *b == 0) {
        // `XY path`; a rename's second path rides the next entry and is stat'ed as one too.
        let path = String::from_utf8_lossy(entry.get(3..).unwrap_or(entry));
        if path.is_empty() {
            continue;
        }
        let stamp = std::fs::metadata(top.join(path.as_ref())).ok().map(|m| {
            let t = m.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok());
            format!("{}:{}", m.len(), t.map(|d| d.as_nanos()).unwrap_or(0))
        });
        text.push_str(&format!("\0{path}={}", stamp.unwrap_or_else(|| "-".into())));
    }
    Some(crate::sha256::sha256_hex(text.as_bytes()))
}

/// A kept run, as [`store`] writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Record {
    pub fingerprint: String,
    pub exit: i32,
    pub output: String,
    pub ms: u64,
    pub at: u64,
}

fn now_s() -> u64 {
    SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Keeps `record` for `command` in `cwd` under `dir` (written whole, then renamed in).
pub(crate) fn store_in(dir: &Path, cwd: &Path, command: &str, record: &Record) -> Option<()> {
    std::fs::create_dir_all(dir).ok()?;
    let body = json!({
        "cwd": cwd.to_string_lossy(), "command": command.trim(),
        "fingerprint": record.fingerprint, "exit": record.exit,
        "output": record.output, "ms": record.ms, "at": record.at,
    });
    let mut tmp = tempfile::NamedTempFile::new_in(dir).ok()?;
    tmp.write_all(body.to_string().as_bytes()).ok()?;
    tmp.persist(record_path(dir, cwd, command)).ok()?;
    Some(())
}

/// Reads the kept run of `command` in `cwd` under `dir`, if any, younger than [`KEEP_FOR`].
pub(crate) fn load_in(dir: &Path, cwd: &Path, command: &str) -> Option<Record> {
    let raw = std::fs::read(record_path(dir, cwd, command)).ok()?;
    let v: Value = serde_json::from_slice(&raw).ok()?;
    let at = v.get("at")?.as_u64()?;
    if now_s().saturating_sub(at) > KEEP_FOR.as_secs() {
        return None;
    }
    Some(Record {
        fingerprint: v.get("fingerprint")?.as_str()?.to_owned(),
        exit: i32::try_from(v.get("exit")?.as_i64()?).ok()?,
        output: v.get("output")?.as_str()?.to_owned(),
        ms: v.get("ms").and_then(Value::as_u64).unwrap_or(0),
        at,
    })
}

/// Whether a kept run of `command` in `cwd` exists (the hook's cheap test: no `git`).
pub(crate) fn has_record(cwd: &Path, command: &str) -> bool {
    dir().is_some_and(|d| record_path(&d, cwd, command).is_file())
}

/// Runs `command` in `cwd` now, niced, in its own process group, killed past `bound`, and
/// keeps the result when the tree did not move during the run. What it kept, if anything.
pub(crate) fn prerun(cwd: &Path, command: &str, bound: Duration) -> Option<Record> {
    prerun_in(&dir()?, cwd, command, bound)
}

pub(crate) fn prerun_in(dir: &Path, cwd: &Path, command: &str, bound: Duration) -> Option<Record> {
    prerun_with_path(dir, cwd, command, bound, None)
}

/// [`prerun_in`] with the run's `PATH` set (tests: a stand-in `cargo`).
fn prerun_with_path(
    dir: &Path,
    cwd: &Path,
    command: &str,
    bound: Duration,
    path: Option<&std::ffi::OsStr>,
) -> Option<Record> {
    if !is_check(command) {
        return None;
    }
    let before = fingerprint(cwd)?;
    let out = tempfile::NamedTempFile::new().ok()?;
    let started = Instant::now();
    let mut cmd = Command::new("sh");
    cmd.args(["-c", "f=$1; shift; exec nice -n 10 sh -c \"$1\" >\"$f\" 2>&1", "sh"])
        .arg(out.path())
        .arg(command)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0);
    if let Some(path) = path {
        cmd.env("PATH", path);
    }
    let mut child = cmd.spawn().ok()?;
    let status = match child.wait_timeout(bound) {
        Ok(Some(s)) => s,
        _ => {
            // SAFETY: signals the process group this call made (`process_group(0)`); its pid is
            // not reaped yet, so the id is still this run's.
            #[cfg(unix)]
            if let Ok(pgid) = libc::pid_t::try_from(child.id()) {
                unsafe { libc::killpg(pgid, libc::SIGKILL) };
            }
            #[cfg(not(unix))]
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
    };
    let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
    if fingerprint(cwd)? != before {
        return None;
    }
    let output = String::from_utf8_lossy(&std::fs::read(out.path()).ok()?).into_owned();
    let record = Record { fingerprint: before, exit: status.code()?, output, ms, at: now_s() };
    store_in(dir, cwd, command, &record)?;
    Some(record)
}

/// `command` run through this binary's `spec-serve --` (`prefix`: its quoted words), or `None`
/// when it is not a check.
pub(crate) fn rewrite(command: &str, prefix: &str) -> Option<String> {
    if !is_check(command) || command.contains(SUBCOMMAND) {
        return None;
    }
    Some(format!("{prefix} '{}'", command.trim().replace('\'', "'\\''")))
}

/// What serving `command` in `cwd` from `dir` answers: the kept run when the tree is as it was.
pub(crate) fn serve_from(dir: &Path, cwd: &Path, command: &str) -> Option<Record> {
    let record = load_in(dir, cwd, command)?;
    (fingerprint(cwd)? == record.fingerprint).then_some(record)
}

/// `acpmux spec-serve -- COMMAND`: the kept run's output and exit code, or the command run as
/// asked.
pub fn main(words: &[String]) -> i32 {
    let command = words.join(" ");
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    if let Some(record) = dir().and_then(|d| serve_from(&d, &cwd, &command)) {
        let mut out = std::io::stdout().lock();
        let _ = out.write_all(record.output.as_bytes());
        let _ = out.flush();
        if let Some(d) = dir() {
            let line = json!({"at": now_s(), "cwd": cwd.to_string_lossy(), "msSaved": record.ms});
            if let Ok(mut f) =
                std::fs::OpenOptions::new().create(true).append(true).open(d.join("served.jsonl"))
            {
                let _ = writeln!(f, "{line}");
            }
        }
        return record.exit;
    }
    let status = Command::new("sh")
        .args(["-c", &command])
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();
    status.ok().and_then(|s| s.code()).unwrap_or(1)
}

#[cfg(test)]
#[path = "spec_exec_tests.rs"]
mod tests;
