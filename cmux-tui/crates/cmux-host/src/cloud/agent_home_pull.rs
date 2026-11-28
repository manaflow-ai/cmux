//! A fresh Cloud chat's agent home (hq `plans/cloud/agent-memory-follows-user.md`, step 5):
//! the agent socket line `{"agent_home_pull": {}}`, which the session host sends before it
//! spawns a harness, becomes one bounded `cmux link memory pull` as root. The pull writes the
//! person's user-wide carried files (their `~/.claude/CLAUDE.md`) into the work user's home,
//! reading the platform's `/v1/agent-home` as this machine's own `vm` install. With no
//! capability, the platform gives that bearer the user-wide entries only (cmux-platform
//! `docs/agent-home.md`).
//!
//! The caller supplies nothing. The machine picks its own origin, bearer and user, so an agent
//! on the machine cannot steer the read. The reply carries the exit and the milliseconds,
//! never the bearer or the pull's output.
//!
//! A pull that exits 1 left files the person revoked in place (`memory.rs`): the reply says
//! `refuse`, and the session host refuses the start. Any other failure (a timeout, the setting
//! off, the platform out of reach) is only noted, and the chat starts with the home it has.

use std::io::Read;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::client::{CloudClient, Http};
use super::github;
use super::github_minter::Stop;

/// The socket line's key.
pub const REQUEST_KEY: &str = "agent_home_pull";
/// How long one pull may run before it is stopped and the chat starts without it.
pub const PULL_BOUND: Duration = Duration::from_secs(5);
/// The image's `cmux` (the binary that carries `cmux link memory`).
pub const CMUX_BIN: &str = "/opt/cmux/current/bin/cmux";
/// The env var the pull reads its bearer from (never an argument, so `ps` never shows it).
pub const TOKEN_ENV: &str = "CMUX_AGENT_HOME_TOKEN";
/// The most of the pull's stderr kept for the journal line.
const STDERR_KEPT: usize = 512;

/// The `agent_home_pull` object of a socket line: it takes no fields.
pub fn check_ask(value: &Value) -> Result<(), String> {
    match value {
        Value::Null => Ok(()),
        Value::Object(fields) if fields.is_empty() => Ok(()),
        _ => {
            Err("agent_home_pull takes no fields; the machine pulls its own person's home.".into())
        }
    }
}

/// One pull, ready to run off the minter thread.
pub struct Job {
    pub origin: String,
    pub token: String,
    pub bin: PathBuf,
    pub user: String,
    pub bound: Duration,
}

/// The job for an ask, or its refusal: the bearer is minted on the minter thread (the one
/// place that holds the client), and the pull then runs on its own thread.
pub fn prepare<H: Http>(
    client: Option<&mut CloudClient<H>>,
    ask: Result<(), String>,
    now_wall_ms: u64,
) -> Result<Job, Value> {
    if let Err(why) = ask {
        return Err(github::refusal("request.invalid", &why));
    }
    let Some(client) = client else {
        return Err(github::transient_refusal(
            "vm.unbound",
            "This machine is not bound to cmux Cloud yet.",
        ));
    };
    let origin = client.bound().env.platform_origin().to_owned();
    let token = client.token(now_wall_ms).map_err(|_| {
        github::transient_refusal("auth.unavailable", "This machine has no cmux Cloud bearer now.")
    })?;
    Ok(Job {
        origin,
        token,
        bin: PathBuf::from(CMUX_BIN),
        user: crate::daemon_spec::WORK_USER.to_owned(),
        bound: PULL_BOUND,
    })
}

/// The pull's arguments (no bearer: it goes in [`TOKEN_ENV`]).
pub fn argv(job: &Job) -> Vec<String> {
    ["link", "memory", "pull", "--head", &job.origin, "--user", &job.user]
        .map(str::to_owned)
        .to_vec()
}

/// How one pull ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Exited(i32),
    /// Killed by a signal, or no exit code.
    Signaled,
    TimedOut,
    NotStarted,
}

/// The reply line for an outcome after `ms`.
pub fn reply_for(outcome: &Outcome, ms: u64) -> Value {
    match outcome {
        Outcome::Exited(0) => json!({"ok": true, "exit": 0, "ms": ms}),
        Outcome::Exited(1) => json!({
            "ok": false, "exit": 1, "ms": ms, "refuse": true,
            "code": "agent_home.not_cleared",
            "message": "Files the person revoked could not be cleared from this machine's agent home.",
        }),
        Outcome::Exited(code) => json!({
            "ok": false, "exit": code, "ms": ms, "refuse": false,
            "code": "agent_home.pull_failed", "message": "The agent home pull failed; the chat starts without it.",
        }),
        Outcome::Signaled => json!({
            "ok": false, "ms": ms, "refuse": false,
            "code": "agent_home.pull_failed", "message": "The agent home pull was stopped.",
        }),
        Outcome::TimedOut => json!({
            "ok": false, "ms": ms, "refuse": false,
            "code": "agent_home.timeout", "message": "The agent home pull ran past its bound; the chat starts without it.",
        }),
        Outcome::NotStarted => json!({
            "ok": false, "ms": ms, "refuse": false,
            "code": "agent_home.unavailable", "message": "This machine could not run the agent home pull.",
        }),
    }
}

/// Runs one pull to its end or its bound. The pull leads its own process group, and its
/// [`cmux_process::Child`] owns it: past the bound, dropping it ends the group and reaps it.
pub fn run(job: &Job) -> (Outcome, u64, String) {
    let started = Instant::now();
    let child = cmux_process::Command::new(&job.bin)
        .args(argv(job))
        .env(TOKEN_ENV, &job.token)
        .env_remove("CMUX_AGENT_HOME_CAPABILITY")
        .process_group(0)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::piped())
        .spawn();
    let Ok(mut child) = child else {
        return (Outcome::NotStarted, elapsed_ms(started), String::new());
    };
    let stderr = child.stderr.take().and_then(|mut pipe| {
        std::thread::Builder::new()
            .name("cmux-host-agent-home-err".into())
            .stack_size(64 * 1024)
            .spawn(move || {
                let mut kept = Vec::new();
                let mut chunk = [0u8; 4096];
                while let Ok(n) = pipe.read(&mut chunk) {
                    if n == 0 {
                        break;
                    }
                    kept.extend_from_slice(&chunk[..n]);
                    if kept.len() > STDERR_KEPT {
                        kept.drain(..kept.len() - STDERR_KEPT);
                    }
                }
                String::from_utf8_lossy(&kept).into_owned()
            })
            .ok()
    });
    let outcome = match child.wait_timeout(job.bound) {
        Ok(Some(status)) => status.code().map_or(Outcome::Signaled, Outcome::Exited),
        Ok(None) => Outcome::TimedOut,
        Err(_) => Outcome::Signaled,
    };
    // Still running (a timeout or a failed wait): the drop ends its group and reaps it.
    drop(child);
    // A pull stopped at its bound may leave a process holding the pipe: its tail is not waited for.
    let tail = match (&outcome, stderr) {
        (Outcome::TimedOut, _) | (_, None) => String::new(),
        (_, Some(reader)) => reader.join().unwrap_or_default(),
    };
    (outcome, elapsed_ms(started), tail)
}

fn elapsed_ms(since: Instant) -> u64 {
    u64::try_from(since.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The journal line for one pull: outcome and ms, and the pull's stderr tail with anything
/// that looks like a credential dropped.
pub fn note_for(outcome: &Outcome, ms: u64, tail: &str) -> String {
    let tail: String = tail
        .lines()
        .filter(|line| !super::github_status::looks_secret(line))
        .collect::<Vec<_>>()
        .join(" | ");
    format!(
        "agent_home_pull: {outcome:?} in {ms} ms{}",
        if tail.is_empty() { String::new() } else { format!(": {tail}") }
    )
}

/// Runs the pull on its own thread and writes its one reply line: the minter goes on with
/// other asks meanwhile. As the minter's replies, none is written once `stop` is set.
pub fn spawn(
    job: Job,
    mut stream: UnixStream,
    stop: Arc<Stop>,
    log: fn(&str),
    write: fn(&mut UnixStream, &Value) -> std::io::Result<()>,
) {
    let started =
        std::thread::Builder::new().name("cmux-host-agent-home".into()).spawn(move || {
            let (outcome, ms, tail) = run(&job);
            log(&note_for(&outcome, ms, &tail));
            let stopped = stop.lock();
            let reply = if *stopped {
                github::refusal("vm.agent_stopping", "the Cloud agent is stopping")
            } else {
                reply_for(&outcome, ms)
            };
            let _ = write(&mut stream, &reply);
            drop(stopped);
        });
    if started.is_err() {
        log("agent_home_pull: could not start its thread");
    }
}
