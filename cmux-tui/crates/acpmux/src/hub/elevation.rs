//! An agent asks to run one command as root (Leo, 2026-11-07: "we should be able to have u ask
//! for it with a tool call/skill for special cases like you never see it but I enter it").
//!
//! The agent's `request_elevation` tool (`acpmux_mcp_elevation.rs`) calls
//! `_acpmux/elevation_request {sessionId, argv, reason, host, timeoutSecs}` on the unix socket,
//! which waits. The chat shows a private card from the `elevation_request` record (the exact
//! argv, the host and the reason) with a password field, Approve and Deny. The person answers
//! with `_acpmux/secret_submit` (the secret card's answer, `secrets.rs`), accepted only from the
//! person's connection (`hub/person.rs`): the agent that asked cannot answer its own card.
//!
//! - On Approve this daemon runs `sudo -S -k -p '' -- argv` itself, writes the password and a
//!   newline to sudo's stdin, closes it, and returns only the exit code, stdout and stderr. The
//!   password lives in a [`Zeroizing`] buffer in this daemon's memory for that one run, and is
//!   zeroed when it is dropped: never in a record, the store, a log, a reply or an error. What
//!   the command prints comes back with the password masked, in case a command with no password
//!   to ask (a NOPASSWD rule) reads it from its stdin.
//! - One command per approval: `-k` makes sudo ignore a cached timestamp and not make one, and
//!   `sudo -k` runs after, so no timestamp is left for anything else. The argv goes to sudo as
//!   its own arguments, never through a shell. The run has a timeout ([`MAX_TIMEOUT`] at most):
//!   sudo leads its own process group; past the timeout the group gets SIGTERM (sudo relays it to
//!   the command), then SIGKILL. A root process that ignores SIGTERM is past what this daemon (the
//!   user) can kill: the agent gets `stillRunning: true` and says so.
//! - sudo is the system's own `/usr/bin/sudo`, owned by root and setuid, never one from PATH: an
//!   agent can put a `sudo` of its own on the user's PATH, and that one would read the password.
//! - A deny is final for that request: the agent gets `denied` and the card is gone. The card
//!   closes with the turn and after [`ASK_TTL`], like a secret card.
//! - Only this daemon's own chats ask, for this host (`host` names it, or is left out): a chat
//!   on a peer is refused, as a secret is (`server/secrets.rs`), so the password never crosses a
//!   daemon link. A chat a remote device started asks for nothing.

use super::secrets::{CardKind, KEPT_ENV, mask_within, read_capped};
use super::{Hub, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use zeroize::Zeroizing;

pub(super) const ASK_TTL: Duration = Duration::from_secs(10 * 60);
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);
pub const MAX_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// How long sudo has after SIGTERM before SIGKILL.
const TERM_GRACE: Duration = Duration::from_secs(5);
/// How long the killed group may take to be reaped before it counts as still running.
const KILL_SETTLE: Duration = Duration::from_secs(2);
/// How long sudo may take to print its prompt before stdin closes with no password: past it,
/// sudo asked for none (or is stuck), and an empty stdin is what the command gets.
const PROMPT_WAIT: Duration = Duration::from_secs(if cfg!(test) { 10 } else { 20 });
const MAX_ARGS: usize = 256;
const MAX_ARG_BYTES: usize = 4096;
const MAX_REASON_CHARS: usize = 500;
/// fs_usage prints a lot: more than a secret's command gets.
const MAX_OUTPUT_BYTES: usize = 512 * 1024;
const SUDO: &str = "/usr/bin/sudo";

const CARD: CardKind = CardKind {
    request: "elevation_request",
    decision: "elevation_decision",
    provided: "approved",
    declined: "denied",
    signed: true,
    one_line: Some(1024),
};

/// The sudo this daemon runs: [`SUDO`], or in a debug build `ACPMUX_ELEVATION_SUDO`, the tests'
/// stand-in. A release build never reads the variable.
fn sudo_path() -> PathBuf {
    #[cfg(debug_assertions)]
    if let Some(path) = std::env::var_os("ACPMUX_ELEVATION_SUDO") {
        return PathBuf::from(path);
    }
    PathBuf::from(SUDO)
}

/// Whether `path` is a sudo only root could have put there: owned by root and setuid.
#[cfg(unix)]
fn trusted_sudo(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    #[cfg(debug_assertions)]
    if std::env::var_os("ACPMUX_ELEVATION_SUDO").is_some() {
        return path.is_file();
    }
    std::fs::symlink_metadata(path)
        .is_ok_and(|m| m.is_file() && m.uid() == 0 && m.mode() & 0o4000 != 0)
}

#[cfg(not(unix))]
fn trusted_sudo(_: &Path) -> bool {
    false
}

/// The checked request.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Ask {
    pub argv: Vec<String>,
    pub reason: String,
    pub timeout: Duration,
}

/// The names this host answers to: its label, and its first DNS label.
fn names_this_host(host: &str) -> bool {
    let host = host.trim().to_ascii_lowercase();
    let host = host.strip_suffix(".local").unwrap_or(&host);
    let label = super::start_gate::host_label().to_ascii_lowercase();
    let short = |n: &str| n.split('.').next().unwrap_or(n).to_owned();
    matches!(host, "" | "local" | "localhost" | "this machine")
        || host == label
        || short(host) == short(&label)
}

/// Checks the request's fields. `host` must name this machine: sudo runs where the daemon runs.
pub(super) fn check(params: &Value) -> Result<Ask, RpcError> {
    let argv = params.get("argv").and_then(Value::as_array).ok_or_else(|| {
        RpcError::invalid_params("argv must be a list of strings: the command and its arguments")
    })?;
    if argv.is_empty() || argv.len() > MAX_ARGS {
        return Err(RpcError::invalid_params(format!("argv must hold 1 to {MAX_ARGS} strings")));
    }
    let argv: Vec<String> = argv
        .iter()
        .map(|a| match a.as_str() {
            Some(s) if !s.contains('\0') && s.len() <= MAX_ARG_BYTES => Ok(s.to_owned()),
            _ => Err(RpcError::invalid_params(format!(
                "each argv entry is a string of at most {MAX_ARG_BYTES} bytes, without NUL"
            ))),
        })
        .collect::<Result<_, _>>()?;
    if argv[0].is_empty() || argv[0].starts_with('-') {
        return Err(RpcError::invalid_params("argv[0] must name the command, not an option"));
    }
    let reason = params.get("reason").and_then(Value::as_str).map(str::trim).unwrap_or_default();
    if reason.is_empty() {
        return Err(RpcError::invalid_params("reason is required: one sentence the card shows"));
    }
    let reason: String = reason.chars().take(MAX_REASON_CHARS).collect();
    let host = params.get("host").and_then(Value::as_str).unwrap_or_default();
    if !names_this_host(host) {
        return Err(RpcError::invalid_params(format!(
            "this chat runs on {}, so sudo runs there; to run as root on {host}, ask from a chat on {host}",
            super::start_gate::host_label()
        )));
    }
    let timeout = match params.get("timeoutSecs") {
        None | Some(Value::Null) => DEFAULT_TIMEOUT,
        Some(v) => match v.as_u64() {
            Some(s) if (1..=MAX_TIMEOUT.as_secs()).contains(&s) => Duration::from_secs(s),
            _ => {
                return Err(RpcError::invalid_params(format!(
                    "timeoutSecs must be 1 to {}",
                    MAX_TIMEOUT.as_secs()
                )));
            }
        },
    };
    Ok(Ask { argv, reason, timeout })
}

impl Hub {
    /// The agent's ask: shows the card, waits for the person, and on Approve runs the command
    /// with sudo. Returns `{outcome}` (`approved`, `denied`, `cancelled`) and, once it ran,
    /// `exitCode`, `stdout`, `stderr` and `timedOut`.
    pub async fn request_elevation(
        &self,
        session: &Session,
        params: &Value,
    ) -> Result<Value, RpcError> {
        let ask = check(params)?;
        if session.meta().remote_origin {
            return Err(RpcError::invalid_params(
                "a chat a remote device started runs nothing as root",
            ));
        }
        let sudo = sudo_path();
        if !trusted_sudo(&sudo) {
            return Err(RpcError::invalid_params(format!(
                "{SUDO} is missing, or is not root's setuid sudo: nothing asked"
            )));
        }
        let card = json!({
            "argv": ask.argv,
            "reason": ask.reason,
            "host": super::start_gate::host_label(),
            "timeoutSecs": ask.timeout.as_secs(),
        });
        let (outcome, password) = self.ask_person(session, CARD, card, ASK_TTL).await;
        let Some(password) = password else {
            return Ok(json!({"outcome": outcome}));
        };
        let mut result = run(&sudo, &ask, password).await;
        cmux_json::JsonSet::set(&mut result, "outcome", json!("approved"));
        self.append(
            session,
            "mux",
            "elevation_run",
            json!({"argv": ask.argv, "exitCode": result["exitCode"], "timedOut": result["timedOut"]}),
        );
        Ok(result)
    }
}

/// Runs `sudo -S -k -p MARKER -- argv`, answers sudo's own prompt with `password`, then runs
/// `sudo -k`. The password is zeroed when this returns.
///
/// The password goes to stdin only once sudo has printed `MARKER`, a prompt unique to this run,
/// on stderr (`answer_prompt`). A sudo that asks for none (a `NOPASSWD` rule) prints no prompt and
/// hands its stdin to the command, which then reads an empty stdin, never the password.
async fn run(sudo: &Path, ask: &Ask, password: Zeroizing<String>) -> Value {
    let mut command = tokio::process::Command::new(sudo);
    command.env_clear();
    for key in KEPT_ENV {
        if let Some(v) = std::env::var_os(key) {
            command.env(key, v);
        }
    }
    // A fixed PATH: sudo's own secure_path decides the command's; this one is only sudo's.
    command.env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    let marker = prompt_marker();
    command
        .args(["-S", "-k", "-p", &marker, "--"])
        .args(&ask.argv)
        .current_dir("/")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    // Its own process group: a timeout signals sudo and everything the command started that
    // stayed in the group, not only sudo (`run_with_secret` does the same).
    #[cfg(unix)]
    command.process_group(0);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            return json!({"exitCode": Value::Null, "timedOut": false, "stdout": "",
                          "stderr": format!("could not start sudo: {e}")});
        }
    };
    let pid = child.id();
    let cap = MAX_OUTPUT_BYTES + password.len() + marker.len();
    let (stdin, stdout, stderr) = (child.stdin.take(), child.stdout.take(), child.stderr.take());
    let answer = password.clone();
    let reads = tokio::spawn(async move {
        tokio::join!(
            read_capped(stdout, cap),
            answer_prompt(stderr, stdin, marker.into_bytes(), answer, cap)
        )
    });
    let mut left_running = false;
    let status = match tokio::time::timeout(ask.timeout, child.wait()).await {
        Ok(status) => Some(status),
        Err(_) => {
            // SIGTERM to the group: sudo relays it to the command, which runs as root.
            signal_group(pid, libc::SIGTERM);
            let _ = tokio::time::timeout(TERM_GRACE, child.wait()).await;
            // Then SIGKILL to the whole group: sudo and every process of the group this daemon
            // may signal. A root process that ignored SIGTERM is past what a user's daemon can
            // kill; the agent is told so.
            signal_group(pid, libc::SIGKILL);
            let _ = child.kill().await;
            left_running = group_left_after(pid, KILL_SETTLE).await;
            None
        }
    };
    let (out, err) = match tokio::time::timeout(TERM_GRACE, reads).await {
        Ok(Ok(read)) => read,
        _ => ((Vec::new(), false), (Vec::new(), false)),
    };
    forget_timestamp(sudo).await;
    let exit = match &status {
        Some(Ok(s)) => json!(s.code()),
        _ => Value::Null,
    };
    let mut stderr = mask_within(err, &password, MAX_OUTPUT_BYTES);
    if let Some(Err(e)) = &status {
        stderr.push_str(&format!("\nwaiting for sudo: {e}"));
    }
    if left_running {
        stderr.push_str(
            "\nacpmux: the command ignored SIGTERM past its timeout and still runs as root; \
             this daemon cannot kill a root process. Tell the person.",
        );
    }
    json!({
        "exitCode": exit,
        "timedOut": status.is_none(),
        "stillRunning": left_running,
        "stdout": mask_within(out, &password, MAX_OUTPUT_BYTES),
        "stderr": stderr,
    })
}

/// A prompt no command prints by chance: sudo's `-p`, so its appearance on stderr means sudo
/// itself waits for the password.
fn prompt_marker() -> String {
    let mut bytes = [0u8; 16];
    // A clock-derived marker still works if the OS has no randomness: it only has to be one no
    // command prints by chance.
    if getrandom::fill(&mut bytes).is_err() {
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH);
        bytes = now.map(|d| d.as_nanos()).unwrap_or_default().to_le_bytes();
    }
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("[acpmux-sudo-{hex}]")
}

/// Reads sudo's stderr. When sudo's prompt (`marker`) shows, the password line goes to its stdin
/// once and stdin closes, so a second prompt (a wrong password) reads end of file and sudo gives
/// up. When no prompt shows within `PROMPT_WAIT`, stdin closes with nothing written: sudo asked
/// for no password, and the command gets an empty stdin. Returns stderr, capped, without the
/// marker.
async fn answer_prompt(
    stderr: Option<tokio::process::ChildStderr>,
    mut stdin: Option<tokio::process::ChildStdin>,
    marker: Vec<u8>,
    password: Zeroizing<String>,
    cap: usize,
) -> (Vec<u8>, bool) {
    use tokio::io::AsyncReadExt;
    let (mut kept, mut cut) = (Vec::new(), false);
    let Some(mut stderr) = stderr else { return (kept, cut) };
    let deadline = tokio::time::Instant::now() + PROMPT_WAIT;
    let mut chunk = [0u8; 8192];
    loop {
        let read = if stdin.is_some() {
            tokio::select! {
                read = stderr.read(&mut chunk) => read,
                () = tokio::time::sleep_until(deadline) => {
                    stdin = None;
                    continue;
                }
            }
        } else {
            stderr.read(&mut chunk).await
        };
        let n = match read {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        let room = cap - kept.len();
        cut |= n > room;
        // Only the new bytes and the marker's length before them can complete it.
        let from = kept.len().saturating_sub(marker.len());
        kept.extend_from_slice(&chunk[..n.min(room)]);
        let prompted = kept[from..].windows(marker.len()).any(|w| w == marker.as_slice());
        if let Some(mut pipe) = stdin.take_if(|_| prompted) {
            let mut line = Zeroizing::new(Vec::with_capacity(password.len() + 1));
            line.extend_from_slice(password.as_bytes());
            line.push(b'\n');
            // A sudo that exited first closes the pipe: what it printed says why.
            let _ = pipe.write_all(&line).await;
            let _ = pipe.shutdown().await;
        }
    }
    let mut clean = Vec::with_capacity(kept.len());
    let mut rest = kept.as_slice();
    while let Some(at) = rest.windows(marker.len()).position(|w| w == marker.as_slice()) {
        clean.extend_from_slice(&rest[..at]);
        rest = &rest[at + marker.len()..];
    }
    clean.extend_from_slice(rest);
    (clean, cut)
}

/// Sends `sig` to the process group sudo leads (its pid, `process_group(0)`).
#[cfg(unix)]
fn signal_group(pid: Option<u32>, sig: i32) {
    if let Some(pid) = pid.and_then(|p| i32::try_from(p).ok()).filter(|p| *p > 1) {
        // SAFETY: killpg has no memory preconditions; the group is the child's own.
        unsafe { libc::killpg(pid, sig) };
    }
}

#[cfg(not(unix))]
fn signal_group(_: Option<u32>, _: i32) {}

/// Whether sudo's group is still there after `settle`: the killed processes the daemon did not
/// spawn are reaped by init a moment after SIGKILL, so the group is checked a few times before it
/// counts as left running. Bounded by `settle`.
async fn group_left_after(pid: Option<u32>, settle: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + settle;
    while group_alive(pid) {
        if tokio::time::Instant::now() >= deadline {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

/// Whether any process of sudo's group is left: one this daemon may not signal (a root
/// process) answers EPERM, which still means it runs.
#[cfg(unix)]
fn group_alive(pid: Option<u32>) -> bool {
    let Some(pid) = pid.and_then(|p| i32::try_from(p).ok()).filter(|p| *p > 1) else {
        return false;
    };
    // SAFETY: signal 0 checks for the group and sends nothing.
    let rc = unsafe { libc::killpg(pid, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn group_alive(_: Option<u32>) -> bool {
    false
}

/// `sudo -k`: no cached timestamp is left behind (`-k` on the run already made none).
async fn forget_timestamp(sudo: &Path) {
    let forget = tokio::process::Command::new(sudo)
        .arg("-k")
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
    let _ = tokio::time::timeout(Duration::from_secs(10), forget).await;
}

#[cfg(test)]
#[path = "elevation_tests.rs"]
mod tests;
