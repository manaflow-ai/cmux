//! `cmux-tui server ensure` and `server status` as the app runs them: the
//! command line, the environment, the timeouts, the answer or its typed
//! refusal; the reap grace probe; the Chief owner's environment and the
//! diagnostic knobs; the session and tag names; the binary's resolution.

use crate::fs::Fs;
use crate::{Env, join};
use serde::{Deserialize, Serialize};

/// The environment variable that overrides the bundled binary (dev builds).
pub const BINARY_OVERRIDE_KEY: &str = "CMUX_NEXT_TUI_BIN";
/// `server ensure --terminal-reap-grace-seconds`.
pub const REAP_GRACE_OPTION: &str = "--terminal-reap-grace-seconds";
/// Hard cap on one `server ensure`: longer than the daemon's own restore
/// bound (2 minutes, then `server.restore_timeout`) plus the time to reach
/// the owner.
pub const ENSURE_RESTORE_CAP_MS: u64 = 150_000;
/// The longest a replace stays silent on stdout before its first line: the
/// 10 s identify probe, 5 s after SIGTERM and 5 s after SIGKILL, plus margin.
pub const REPLACE_SILENCE_MS: u64 = 30_000;

/// The launcher's settings that shape the command line.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Arguments {
    pub session: String,
    #[serde(default = "default_grace")]
    pub reap_grace_seconds: u32,
    /// The binary accepts `--terminal-reap-grace-seconds`.
    #[serde(default = "yes")]
    pub reap_grace: bool,
    /// The launcher hands an install key on stdin.
    #[serde(default)]
    pub install_key: bool,
    /// `--exit-with-pid` (test harnesses).
    #[serde(default)]
    pub exit_with_pid: Option<i32>,
    /// The binary reports restore progress (the bundled one).
    #[serde(default)]
    pub progress: bool,
    #[serde(default)]
    pub binary_is_bundled: bool,
    /// The page origins the owner's loopback WebSocket admits.
    #[serde(default)]
    pub page_origins: Vec<String>,
    /// "Restart cmux-tui": `--replace-unresponsive`.
    #[serde(default)]
    pub replace_unresponsive: bool,
}

fn default_grace() -> u32 {
    30
}
fn yes() -> bool {
    true
}

/// The `server ensure` command line.
pub fn ensure_arguments(a: &Arguments) -> Vec<String> {
    let mut args: Vec<String> = ["--session", &a.session, "--json", "server", "ensure"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    if a.reap_grace {
        args.push(REAP_GRACE_OPTION.into());
        args.push(a.reap_grace_seconds.to_string());
    }
    if a.install_key {
        args.push("--install-key-stdin".into());
    }
    if let Some(pid) = a.exit_with_pid {
        args.push("--exit-with-pid".into());
        args.push(pid.to_string());
    }
    if a.progress {
        args.push("--restore-progress".into());
    }
    args.extend(page_listener_arguments(a));
    if a.replace_unresponsive {
        args.push("--replace-unresponsive".into());
    }
    args
}

/// `--ws-loopback --ws-allow-origin <origins>` for the bundled binary with
/// page origins; an external binary may lack the option, so never.
pub fn page_listener_arguments(a: &Arguments) -> Vec<String> {
    if !a.binary_is_bundled || a.page_origins.is_empty() {
        return Vec::new();
    }
    vec!["--ws-loopback".into(), "--ws-allow-origin".into(), a.page_origins.join(",")]
}

/// `server status`'s command line.
pub fn status_arguments(session: &str) -> Vec<String> {
    ["--session", session, "--json", "server", "status"].iter().map(|s| s.to_string()).collect()
}

/// The help commands probed for the reap grace option, in order (older
/// clients list it in root help, current ones in `help start`).
pub fn reap_grace_probes() -> Vec<Vec<String>> {
    vec![vec!["--help".into()], vec!["help".into(), "start".into()]]
}

/// True when a help text lists `--terminal-reap-grace-seconds` as a line's
/// first word.
pub fn lists_reap_grace(help: &str) -> bool {
    split_lines(help).any(|line| line.split_whitespace().next() == Some(REAP_GRACE_OPTION))
}

/// The environment's inputs.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentInput {
    /// The provider's environment (`ensure`) or the process's (`status`).
    pub base: Env,
    #[serde(default)]
    pub state_directory: Option<String>,
    #[serde(default)]
    pub config_file: Option<String>,
    pub runtime_base: String,
    /// For `server status`: no Cloud launcher authority.
    #[serde(default)]
    pub for_status: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentOutput {
    pub environment: Env,
    /// The launch is authoritative for the Cloud backend: skip the `server
    /// status` fast path so `ensure` can replace a daemon the last launch left.
    pub skips_status: bool,
}

/// The environment for `server ensure` (or `status`): the base, plus the
/// state directory, the config file and a fixed runtime base (`TMPDIR`, with
/// `XDG_RUNTIME_DIR` removed, since it would win in cmux-tui's socket lookup).
pub fn environment(input: &EnvironmentInput) -> EnvironmentOutput {
    let mut env = input.base.clone();
    // The marker is this call's own, never inherited: a base that already
    // carries it would skip the status fast path and hand it to a status call.
    env.remove("CMUX_NEXT_CLOUD_LAUNCHER");
    // Only for the app launcher's ensure: the daemon strips it before it
    // spawns the owner, so terminals never switch a shared owner's backend.
    if !input.for_status && env.get("CMUX_NEXT_CLOUD_RUNTIME").map(String::as_str) == Some("1") {
        env.insert("CMUX_NEXT_CLOUD_LAUNCHER".into(), "1".into());
    }
    if let Some(dir) = &input.state_directory {
        env.insert("CMUX_TUI_STATE_DIR".into(), dir.clone());
    }
    if let Some(config) = &input.config_file {
        env.insert("CMUX_TUI_CONFIG".into(), config.clone());
    }
    env.remove("XDG_RUNTIME_DIR");
    env.insert("TMPDIR".into(), input.runtime_base.clone());
    let skips_status = env.get("CMUX_NEXT_CLOUD_LAUNCHER").map(String::as_str) == Some("1");
    EnvironmentOutput { environment: env, skips_status }
}

/// One ensure's process bounds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Timing {
    /// `--restore-progress` (the bundled binary).
    pub progress: bool,
    pub timeout_ms: u64,
    /// The child fails when stdout stays silent this long.
    pub progress_idle_ms: Option<u64>,
}

/// The bounds of `server ensure` (or its `--replace-unresponsive` run): the
/// bundled binary reports restore progress, so it waits while the owner
/// restores and gives up when progress stops for `ensure_timeout_ms`; an
/// external binary is bounded by the restore cap.
pub fn timing(binary_is_bundled: bool, ensure_timeout_ms: u64, replace: bool) -> Timing {
    let progress = binary_is_bundled;
    if replace {
        return Timing {
            progress,
            timeout_ms: ENSURE_RESTORE_CAP_MS + REPLACE_SILENCE_MS,
            progress_idle_ms: progress.then_some(REPLACE_SILENCE_MS),
        };
    }
    Timing {
        progress,
        timeout_ms: if progress {
            ENSURE_RESTORE_CAP_MS
        } else {
            ensure_timeout_ms.max(ENSURE_RESTORE_CAP_MS)
        },
        progress_idle_ms: progress.then_some(ensure_timeout_ms),
    }
}

/// `server ensure --json` (or `status`) output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ensured {
    /// `running`, `started` or `replaced`.
    pub status: String,
    pub session: String,
    pub socket: String,
    pub pid: i32,
    pub generation: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// The JSON error of a failed ensure on stderr.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Failure {
    pub code: String,
    #[serde(default)]
    pub message: Option<String>,
}

/// How an ensure ended.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Parsed {
    Ok(Ensured),
    /// The owner is alive but still restoring past the daemon's bound.
    RestoreTimeout(String),
    /// Any other failure: `exit <status>: <stderr, else stdout>`.
    LaunchFailed(String),
    /// `--replace-unresponsive` refused (`server.replace_*`): the owner was not stopped.
    ReplaceRefusal(Failure),
}

/// Swift's `isNewline` separators (a `\r\n` pair splits once: the empty
/// piece between is dropped).
fn is_newline(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The non-empty lines of `text`.
pub(crate) fn split_lines(text: &str) -> impl DoubleEndedIterator<Item = &str> {
    text.split(is_newline).filter(|line| !line.is_empty())
}

/// Trims spaces and tabs (Swift `.whitespaces`, no newlines).
fn trim_spaces(line: &str) -> &str {
    line.trim_matches(|c: char| c.is_whitespace() && !is_newline(c))
}

/// The last stderr line that is a JSON error object.
pub fn failure(stderr: &str) -> Option<Failure> {
    let line = split_lines(stderr).rev().find(|line| trim_spaces(line).starts_with('{'))?;
    serde_json::from_str(line.trim()).ok()
}

/// Reads one ensure's result: the last stdout line that is a JSON object on
/// exit 0, else the typed failure. `replace`: a `--replace-unresponsive` run.
pub fn parse(status: i32, stdout: &str, stderr: &str, replace: bool) -> Parsed {
    if replace
        && status != 0
        && let Some(failure) = failure(stderr).filter(|f| f.code.starts_with("server.replace_"))
    {
        return Parsed::ReplaceRefusal(failure);
    }
    let last = split_lines(stdout).map(trim_spaces).rfind(|line| line.starts_with('{'));
    if status == 0
        && let Some(ensured) = last.and_then(|line| serde_json::from_str::<Ensured>(line).ok())
    {
        return Parsed::Ok(ensured);
    }
    if let Some(failure) = failure(stderr).filter(|f| f.code == "server.restore_timeout") {
        return Parsed::RestoreTimeout(failure.message.unwrap_or_default());
    }
    let stderr = stderr.trim();
    let stdout = stdout.trim();
    Parsed::LaunchFailed(format!(
        "exit {status}: {}",
        if stderr.is_empty() { stdout } else { stderr }
    ))
}

/// The variables the Chief owner's `server ensure` keeps from its base: the
/// user's basics, never a build's `CMUX_*` identity; the brain's tools
/// socket and what the owner needs to run the other Chiefs' brains.
const CHIEF_KEPT: [&str; 9] = [
    "HOME",
    "USER",
    "LOGNAME",
    "PATH",
    "LANG",
    "LC_ALL",
    "SHELL",
    "CMUX_TUI_CHIEF_TOOLS_SOCKET",
    "CMUX_TUI_CHIEF_BRAINS",
];

/// App launch knob to daemon variable (the app strips every inherited
/// `CMUX*` but its own `CMUX_NEXT_*` knobs, so the daemon gets its names
/// from these): flow marks, debug spans, the terminal host model and the
/// R-DAEMON-STATE input lane switch.
pub const KNOBS: [(&str, &str); 4] = [
    ("CMUX_NEXT_TRACE_FLOWS", "CMUX_TRACE_FLOWS"),
    ("CMUX_NEXT_TUI_DEBUG_SPANS", "CMUX_TUI_DEBUG_SPANS"),
    ("CMUX_NEXT_TUI_TERMINAL_HOST_MODEL", "CMUX_TUI_TERMINAL_HOST_MODEL"),
    ("CMUX_NEXT_TUI_RDS_INPUT", INPUT_LANE),
];

/// The R-DAEMON-STATE stage S1 input lane switch under the daemon's name.
const INPUT_LANE: &str = "CMUX_TUI_RDS_INPUT";
/// The switches the Chief owner gets too: it follows the app daemon's rules,
/// so each switch's off value must reach it.
const CHIEF_KNOBS: [&str; 1] = [INPUT_LANE];

/// The daemon variables of the knobs present and non-empty in `environment`.
pub fn diagnostic_knobs(environment: &Env) -> Env {
    KNOBS
        .iter()
        .filter_map(|(app, daemon)| {
            environment.get(*app).filter(|v| !v.is_empty()).map(|v| (daemon.to_string(), v.clone()))
        })
        .collect()
}

/// The Chief owner's `server ensure` environment.
pub fn chief_environment(base: &Env) -> Env {
    let mut env: Env = base
        .iter()
        .filter(|(k, _)| CHIEF_KEPT.contains(&k.as_str()))
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let knobs = diagnostic_knobs(base);
    for name in CHIEF_KNOBS {
        if let Some(value) = knobs.get(name) {
            env.insert(name.into(), value.clone());
        }
    }
    env
}

/// The untagged channel builds (bundle id, channel), each with its own
/// daemon session and state (cmux-tui `app_identity.rs` `CHANNELS`). Release
/// (`com.cmuxterm.app`) keeps `cmux-app`.
pub const CHANNEL_BUNDLE_IDS: [(&str, &str); 3] = [
    ("com.cmuxterm.app.nightly", "nightly"),
    ("com.cmuxterm.app.rc", "rc"),
    ("com.cmuxterm.app.staging", "staging"),
];

/// `cmux-app`, or `cmux-app-<tag>` with the tag cut to one safe path
/// component; none when nothing of the tag is left.
pub fn session_name(tag: Option<&str>) -> Option<String> {
    let Some(tag) = tag else { return Some("cmux-app".into()) };
    let cleaned: String = tag
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '-' })
        .collect();
    let cleaned = cleaned.trim_matches(|c| c == '-' || c == '.');
    (!cleaned.is_empty()).then(|| format!("cmux-app-{cleaned}"))
}

/// `<applicationSupport>/cmux/tags/<tag>/tui`.
pub fn tag_state_directory(tag: &str, application_support: &str) -> String {
    let component = session_name(Some(tag))
        .and_then(|s| s.strip_prefix("cmux-app-").map(str::to_string))
        .unwrap_or_else(|| "default".into());
    join(application_support, &format!("cmux/tags/{component}/tui"))
}

/// `CMUX_NEXT_TUI_BIN` when executable, then `<Resources>/bin/cmux-tui`;
/// `Err` lists what was searched.
pub fn resolve_binary(
    override_path: Option<&str>,
    resources: Option<&str>,
    fs: &Fs,
) -> Result<String, Vec<String>> {
    let mut searched = Vec::new();
    if let Some(path) = override_path.filter(|p| !p.is_empty()) {
        searched.push(path.to_string());
        if fs.is_executable(path) {
            return Ok(path.to_string());
        }
    }
    if let Some(resources) = resources {
        let bundled = join(resources, "bin/cmux-tui");
        searched.push(bundled.clone());
        if fs.is_executable(&bundled) {
            return Ok(bundled);
        }
    }
    Err(searched)
}

/// `<Resources>/bin/<name>`, or the override when one is set: the app's
/// bundled executables (`CMUX_NEXT_TUI_BIN` runs in place of `cmux`).
pub fn bundled_executable(
    resources: Option<&str>,
    name: &str,
    override_path: Option<&str>,
) -> Option<String> {
    if let Some(path) = override_path.filter(|p| !p.is_empty()) {
        return Some(path.to_string());
    }
    resources.map(|r| join(&join(r, "bin"), name))
}

/// The last-opened-app pointer is written only by a person's own launch:
/// an isolated agent launch (`CMUX_NEXT_NO_ACTIVATE=1`) never takes over the
/// user's `cmux`.
pub fn last_app_cli_publishes(environment: &Env) -> bool {
    environment.get("CMUX_NEXT_NO_ACTIVATE").map(String::as_str) != Some("1")
}
