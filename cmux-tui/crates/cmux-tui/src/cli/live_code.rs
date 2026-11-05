//! `cmux live-code status|apply|undo|log`: read and repair the live code of a
//! running cmux NEXT live code build (docs/cmux-next/live-code.md).
//!
//! Everything goes through the app's live folder, never its socket or its
//! main thread, so a patch that wedged the app's UI can still be undone: a
//! new `*.dylib` applies, a new `*.rollback` undoes the newest patch, a new
//! `*.rollback-all` undoes them all, and the app's engine (an actor off the
//! main thread, CmuxNextLiveCode/LiveCode.swift) answers in `live-code.log`
//! and keeps `status.json`. The folder is `--dir`, else `CMUX_LIVE_CODE_DIR`,
//! else ~/Library/Caches/cmux-next/live-code. The same operations are MCP
//! tools (mcp/live_code_tools.rs), so an agent can repair the app it runs in.
//!
//! Exit codes: 0 done, 1 the app refused it, 2 usage, 3 no live code app
//! watches the folder, 4 the app did not answer in time (relaunch it).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// How long an apply or undo waits for the app's answer by default.
const DEFAULT_WAIT: Duration = Duration::from_secs(20);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Status { dir: Option<PathBuf> },
    Apply { dir: Option<PathBuf>, patch: PathBuf, wait: Option<Duration> },
    Undo { dir: Option<PathBuf>, all: bool, wait: Option<Duration> },
    Log { dir: Option<PathBuf>, lines: usize },
}

/// `cmux live-code …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "live-code" {
        return None;
    }
    let (rest, json) = without_json(rest);
    let output = if json { OutputMode::Json } else { global.output };
    Some(match parse(&rest) {
        Ok(invocation) => run(output, &global, invocation),
        Err(error) => super::app::failure("usage.invalid", &format!("cmux: {error}"), output, 2),
    })
}

/// `--json` after the verb, as before it.
fn without_json(rest: &[String]) -> (Vec<String>, bool) {
    let json = rest.iter().any(|arg| arg == "--json");
    (rest.iter().filter(|arg| *arg != "--json").cloned().collect(), json)
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let app = &crate::localization::catalog().app_control;
    let messages = &crate::localization::catalog().live_code;
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let Some((verb, tail)) = rest.split_first() else { return Ok(Invocation::Help) };
    let mut dir = None;
    let mut all = false;
    let mut wait = Some(DEFAULT_WAIT);
    let mut lines = 40usize;
    let mut positional = Vec::new();
    let mut args = tail.iter();
    while let Some(arg) = args.next() {
        let mut value = |flag: &str| {
            args.next()
                .cloned()
                .ok_or_else(|| UsageError::new(app.missing_value.replace("{flag}", flag)))
        };
        match arg.as_str() {
            "--dir" => dir = Some(PathBuf::from(value("--dir")?)),
            "--all" if verb == "undo" => all = true,
            "--no-wait" if verb == "apply" || verb == "undo" => wait = None,
            "--timeout" if verb == "apply" || verb == "undo" => {
                let text = value("--timeout")?;
                let seconds: u64 = text.parse().map_err(|_| {
                    UsageError::new(app.unexpected_argument.replace("{value}", &text))
                })?;
                wait = Some(Duration::from_secs(seconds.clamp(1, 600)));
            }
            "-n" | "--lines" if verb == "log" => {
                let text = value(arg)?;
                lines = text.parse().map_err(|_| {
                    UsageError::new(app.unexpected_argument.replace("{value}", &text))
                })?;
            }
            other if other.starts_with('-') => {
                return Err(UsageError::new(app.unexpected_argument.replace("{value}", other)));
            }
            other => positional.push(other.to_owned()),
        }
    }
    let extra = |count: usize| -> Result<(), UsageError> {
        match positional.get(count) {
            Some(value) => Err(UsageError::new(app.unexpected_argument.replace("{value}", value))),
            None => Ok(()),
        }
    };
    match verb.as_str() {
        "help" => Ok(Invocation::Help),
        "status" => extra(0).map(|()| Invocation::Status { dir }),
        "log" => extra(0).map(|()| Invocation::Log { dir, lines: lines.clamp(1, 10_000) }),
        "undo" => extra(0).map(|()| Invocation::Undo { dir, all, wait }),
        "apply" => {
            extra(1)?;
            let Some(patch) = positional.first() else {
                return Err(UsageError::new(messages.apply_needs_patch));
            };
            if is_pull_request(patch) {
                return Err(UsageError::new(messages.apply_pull_request.replace("{pr}", patch)));
            }
            Ok(Invocation::Apply { dir, patch: PathBuf::from(patch), wait })
        }
        other => Err(UsageError::new(messages.unknown_verb.replace("{verb}", other))),
    }
}

/// `123`, `#123` or a pull request URL: a PR, which try-pr builds into a patch.
fn is_pull_request(text: &str) -> bool {
    let number = text.strip_prefix('#').unwrap_or(text);
    (!number.is_empty() && number.chars().all(|c| c.is_ascii_digit())) || text.contains("/pull/")
}

/// The live folder: `--dir`, else CMUX_LIVE_CODE_DIR, else the person's.
pub(super) fn folder(dir: Option<&Path>) -> PathBuf {
    if let Some(dir) = dir {
        return dir.to_path_buf();
    }
    if let Some(dir) = std::env::var_os("CMUX_LIVE_CODE_DIR").filter(|dir| !dir.is_empty()) {
        return PathBuf::from(dir);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    home.join("Library/Caches/cmux-next/live-code")
}

/// The app's `status.json`, with `watching`: whether its process still runs.
pub(super) fn status(folder: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(folder.join("status.json")).ok()?;
    let mut value: Value = serde_json::from_str(&text).ok()?;
    let pid = value.get("pid").and_then(Value::as_i64).unwrap_or(0);
    // The pid still runs the app that wrote this, not another process that took the pid.
    let same_app = match (value.get("executable").and_then(Value::as_str), process_executable(pid))
    {
        (Some(recorded), Some(running)) => same_file(Path::new(recorded), &running),
        _ => true,
    };
    let watching = pid > 0 && process_runs(pid) && same_app;
    if let Value::Object(map) = &mut value {
        map.insert("watching".into(), json!(watching));
    }
    Some(value)
}

fn process_runs(pid: i64) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    // Signal 0 checks the process exists; EPERM means it does, as another user's.
    // SAFETY: kill with signal 0 sends nothing; it only checks the pid.
    let sent = unsafe { libc::kill(pid, 0) == 0 };
    sent || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// The executable a process runs, where the platform says.
fn process_executable(pid: i64) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_link(format!("/proc/{pid}/exe")).ok()
    }
    #[cfg(target_os = "macos")]
    {
        let pid = libc::c_int::try_from(pid).ok()?;
        let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        // SAFETY: the buffer is PROC_PIDPATHINFO_MAXSIZE bytes, as proc_pidpath requires.
        let length =
            unsafe { libc::proc_pidpath(pid, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
        (length > 0).then(|| {
            PathBuf::from(String::from_utf8_lossy(&buffer[..length as usize]).into_owned())
        })
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = pid;
        None
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    a == b || matches!((a.canonicalize(), b.canonicalize()), (Ok(a), Ok(b)) if a == b)
}

fn now_nanos() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or_default()
}

/// Puts `patch` (and its sidecar `NAME.json`, when it has one) into the
/// folder under a new name, each moved into place in one step. Returns the
/// name the app will log.
pub(super) fn place_patch(folder: &Path, patch: &Path) -> std::io::Result<String> {
    let stem = format!("patch-cli-{}", now_nanos());
    let sidecar = patch.with_extension("json");
    if sidecar.is_file() {
        place(folder, &sidecar, &format!("{stem}.json"))?;
    }
    let name = format!("{stem}.dylib");
    place(folder, patch, &name)?;
    Ok(name)
}

fn place(folder: &Path, from: &Path, name: &str) -> std::io::Result<()> {
    let hidden = folder.join(format!(".{name}"));
    std::fs::copy(from, &hidden)?;
    std::fs::rename(&hidden, folder.join(name))
}

/// Asks the app to undo: an empty `undo-….rollback` (`.rollback-all` for all).
pub(super) fn request_undo(folder: &Path, all: bool) -> std::io::Result<String> {
    let name = format!("undo-{}.rollback{}", now_nanos(), if all { "-all" } else { "" });
    std::fs::File::create(folder.join(&name))?;
    Ok(name)
}

/// The app's answer to `name` in `live-code.log`: `Ok(line)` when it applied
/// or rolled back, `Err(line)` when it refused, `None` before it answered.
pub(super) fn answer(log: &str, name: &str) -> Option<Result<String, String>> {
    log.lines().rev().find_map(|line| {
        let line = line.trim_start_matches("live code: ");
        if line.starts_with(&format!("applied {name} "))
            || line.starts_with(&format!("rolled back {name} "))
        {
            Some(Ok(line.to_owned()))
        } else if line.starts_with(&format!("{name} refused: ")) {
            Some(Err(line.to_owned()))
        } else {
            None
        }
    })
}

fn wait_for(folder: &Path, name: &str, wait: Duration) -> Option<Result<String, String>> {
    let deadline = Instant::now() + wait;
    loop {
        let log = std::fs::read_to_string(folder.join("live-code.log")).unwrap_or_default();
        if let Some(found) = answer(&log, name) {
            return Some(found);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn print(output: OutputMode, value: &Value, human: &str) -> i32 {
    match output {
        OutputMode::Quiet => 0,
        OutputMode::Json | OutputMode::JsonLines => super::wire::print_local_success(value, output),
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(human.as_bytes());
            let _ = stdout.flush();
            0
        }
    }
}

fn not_watching(output: OutputMode, folder: &Path) -> i32 {
    let messages = &crate::localization::catalog().live_code;
    let message = messages.not_watching.replace("{dir}", &folder.display().to_string());
    super::app::failure("live_code.not_watching", &message, output, 3)
}

/// The human form of `status.json`.
pub(super) fn status_text(status: &Value) -> String {
    let field = |key: &str| status.get(key).cloned().unwrap_or(Value::Null);
    let mut text = format!(
        "live code build {} (pid {}, {}), generation {}{}\n",
        field("bundle_id").as_str().unwrap_or("?"),
        field("pid"),
        if field("watching").as_bool() == Some(true) { "running" } else { "not running" },
        field("generation"),
        if field("team_signed_only").as_bool() == Some(true) {
            ", team-signed patches only"
        } else {
            ""
        },
    );
    let patches = status.get("patches").and_then(Value::as_array).cloned().unwrap_or_default();
    if patches.is_empty() {
        text.push_str("no patch applied: the code as built\n");
    }
    for patch in &patches {
        let files = patch
            .get("files")
            .and_then(Value::as_array)
            .map(|files| files.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", "));
        text.push_str(&format!(
            "  {}  {} functions  {}  {}\n",
            patch.get("name").and_then(Value::as_str).unwrap_or("?"),
            patch.get("functions").and_then(Value::as_i64).unwrap_or(0),
            patch.get("commit").and_then(Value::as_str).unwrap_or("commit unknown"),
            files.unwrap_or_default(),
        ));
    }
    if let Some(error) = status.get("last_error").and_then(Value::as_str) {
        text.push_str(&format!("last error: {error}\n"));
    }
    text
}

pub(super) fn run(output: OutputMode, _global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().live_code;
    let (dir, wait, request) = match invocation {
        Invocation::Help => return print(OutputMode::Human, &Value::Null, messages.usage),
        Invocation::Status { dir } => {
            let folder = folder(dir.as_deref());
            return match status(&folder) {
                Some(status) => {
                    let text = status_text(&status);
                    print(output, &status, &text)
                }
                None => not_watching(output, &folder),
            };
        }
        Invocation::Log { dir, lines } => {
            let folder = folder(dir.as_deref());
            let log = std::fs::read_to_string(folder.join("live-code.log")).unwrap_or_default();
            let tail: Vec<&str> =
                log.lines().rev().take(lines).collect::<Vec<_>>().into_iter().rev().collect();
            let text = if tail.is_empty() { String::new() } else { tail.join("\n") + "\n" };
            return print(output, &json!({"folder": folder, "lines": tail}), &text);
        }
        Invocation::Apply { dir, patch, wait } => (dir, wait, Ok(patch)),
        Invocation::Undo { dir, all, wait } => (dir, wait, Err(all)),
    };
    let folder = folder(dir.as_deref());
    if status(&folder).and_then(|s| s.get("watching").and_then(Value::as_bool)) != Some(true) {
        return not_watching(output, &folder);
    }
    let placed = match &request {
        Ok(patch) => place_patch(&folder, patch),
        Err(all) => request_undo(&folder, *all),
    };
    let name = match placed {
        Ok(name) => name,
        Err(error) => {
            return super::app::failure("live_code.io", &format!("cmux: {error}"), output, 1);
        }
    };
    let Some(wait) = wait else {
        return print(output, &json!({"requested": name}), &format!("requested {name}\n"));
    };
    match wait_for(&folder, &name, wait) {
        Some(Ok(line)) => print(output, &json!({"name": name, "done": line}), &format!("{line}\n")),
        Some(Err(line)) => super::app::failure("live_code.refused", &line, output, 1),
        None => {
            let message = messages
                .no_answer
                .replace("{name}", &name)
                .replace("{seconds}", &wait.as_secs().to_string());
            super::app::failure("live_code.no_answer", &message, output, 4)
        }
    }
}

#[cfg(test)]
mod tests;
