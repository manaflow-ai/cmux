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
//!   past it sudo gets SIGTERM (it relays the signal to the command), then SIGKILL.
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
const MAX_ARGS: usize = 256;
const MAX_ARG_BYTES: usize = 4096;
const MAX_REASON_CHARS: usize = 500;
const MAX_PASSWORD_BYTES: usize = 1024;
/// fs_usage prints a lot: more than a secret's command gets.
const MAX_OUTPUT_BYTES: usize = 512 * 1024;
const SUDO: &str = "/usr/bin/sudo";

const CARD: CardKind = CardKind {
    request: "elevation_request",
    decision: "elevation_decision",
    provided: "approved",
    declined: "denied",
    signed: true,
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
        if password.len() > MAX_PASSWORD_BYTES || password.contains(['\n', '\r', '\0']) {
            return Ok(json!({"outcome": "denied", "error": "the password was not one line"}));
        }
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

/// Runs `sudo -S -k -p '' -- argv` with `password` on its stdin, then `sudo -k`. The password is
/// zeroed when this returns.
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
    command
        .args(["-S", "-k", "-p", "", "--"])
        .args(&ask.argv)
        .current_dir("/")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            return json!({"exitCode": Value::Null, "timedOut": false, "stdout": "",
                          "stderr": format!("could not start sudo: {e}")});
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        let mut line = Zeroizing::new(Vec::with_capacity(password.len() + 1));
        line.extend_from_slice(password.as_bytes());
        line.push(b'\n');
        // A sudo that exited first (a refused rule) closes the pipe: what it prints says why.
        let _ = stdin.write_all(&line).await;
        let _ = stdin.shutdown().await;
    }
    let pid = child.id();
    let cap = MAX_OUTPUT_BYTES + password.len();
    let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
    let reads =
        tokio::spawn(
            async move { tokio::join!(read_capped(stdout, cap), read_capped(stderr, cap)) },
        );
    let status = match tokio::time::timeout(ask.timeout, child.wait()).await {
        Ok(status) => Some(status),
        Err(_) => {
            signal(pid, libc::SIGTERM);
            match tokio::time::timeout(TERM_GRACE, child.wait()).await {
                Ok(_) => None,
                Err(_) => {
                    let _ = child.kill().await;
                    None
                }
            }
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
    json!({
        "exitCode": exit,
        "timedOut": status.is_none(),
        "stdout": mask_within(out, &password, MAX_OUTPUT_BYTES),
        "stderr": stderr,
    })
}

#[cfg(unix)]
fn signal(pid: Option<u32>, sig: i32) {
    if let Some(pid) = pid.and_then(|p| i32::try_from(p).ok()) {
        // SAFETY: kill has no memory preconditions; the pid is our own child, not yet reaped.
        unsafe { libc::kill(pid, sig) };
    }
}

#[cfg(not(unix))]
fn signal(_: Option<u32>, _: i32) {}

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
