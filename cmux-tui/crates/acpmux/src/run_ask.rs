//! `acpmux run-ask`: the runner side of a forum `run` ask (RFD 0087 section 9, "agents talk to
//! agents: one protocol"). One person's agent asks another person's agent to run one command on a
//! computer the asker is not on; the forum store (cmux-platform `workers/cmux-forum/src/forum/
//! asks.rs`) records the ask `{type: "run", to, repo, ref, command, limits?}` and the addressed
//! person's consent (`state: "accepted"`). This module takes that ask, checks it again with the
//! store's bounds, plans where it runs, runs it, and gives the store's `result` shape back:
//! `{exit, tail, artifacts}`. It fetches and posts nothing over HTTP: the caller hands it the ask.
//!
//! What it refuses: anything but a `run` in state `accepted`, a multi-line command, a repo that is
//! not `owner/name`, a ref that is not one plain commit or branch, limits over the store's (a day,
//! 64 vCPU), and any field the store never serves (`env`, `script`, `secret`, ...). An ask carries
//! no environment and no secret, so nothing here can add one.
//!
//! Where it runs: here when light; through the scheduler (`cmux-ci`, or `$ACPMUX_RUN_ASK_SCHEDULER`)
//! when it asks for more vCPU than this machine has or a timeout past [`LOCAL_MAX_TIMEOUT_S`].
//!
//! The environment: the fetch and a local command get only [`KEPT_ENV`] from this process (the
//! path, the home, the user, the locale, the temp folder, the Rust toolchain homes), so no token
//! or key this process holds in a variable reaches the asker's command; the command still runs as
//! this machine's user, with that user's files. The scheduler is our own tool, run with this
//! process's whole environment (its routing needs it); the command it carries runs elsewhere.

use anyhow::{Context as _, Result, anyhow};
use cmux_process::{Command, Stdio};
use serde_json::{Map, Value, json};
use std::fmt;
use std::fs::File;
use std::io::{Read as _, Seek as _, SeekFrom};
use std::path::Path;
use std::process::ExitStatus;
use std::time::Duration;

/// The store's bounds (`asks.rs`): a command, a repo or ref, a run's limits.
pub const MAX_COMMAND: usize = 2000;
pub const MAX_FIELD: usize = 500;
pub const MAX_TIMEOUT_S: u64 = 86_400;
pub const MAX_VCPU: u64 = 64;
/// The longest run kept on this machine, and a light run's timeout when the ask names none.
pub const LOCAL_MAX_TIMEOUT_S: u64 = 600;
/// The scheduler's own cap on a run (`cmux-ci test --timeout`: 3 h); a longer ask is refused.
pub const SCHEDULER_MAX_TIMEOUT_S: u64 = 10_800;
/// Time the scheduler gets past the run's timeout to queue, start and answer.
pub const SCHEDULER_GRACE_S: u64 = 1_200;
/// The bound on fetching repo@ref.
pub const FETCH_TIMEOUT_S: u64 = 600;
/// How much of the combined output the result keeps, from the end (the store keeps up to 8000
/// characters).
pub const TAIL_BYTES: usize = 4096;
/// What the reader keeps while a run writes, before the tail is cut from it.
const KEPT_BYTES: usize = 8192;
/// A run that hit its timeout exits as timeout(1) does.
pub const TIMED_OUT_EXIT: i32 = 124;
/// Names the scheduler binary in place of [`DEFAULT_SCHEDULER`] (tests, another fleet).
pub const SCHEDULER_ENV: &str = "ACPMUX_RUN_ASK_SCHEDULER";
pub const DEFAULT_SCHEDULER: &str = "cmux-ci";

/// Every field the store serves on a `run` ask (`ask_json`); anything else is refused.
const ASK_FIELDS: &[&str] = &[
    "id",
    "thread",
    "type",
    "state",
    "body",
    "asker",
    "to",
    "created_at",
    "updated_at",
    "receipt",
    "receipts",
    "repo",
    "ref",
    "command",
    "limits",
    "result",
];

/// The variables a fetch and a local command keep from this process; the rest are cleared.
pub const KEPT_ENV: &[&str] = &[
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "TMPDIR",
    "CARGO_HOME",
    "RUSTUP_HOME",
];

/// Why an ask is not run, in plain words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal(pub String);

impl fmt::Display for Refusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Refusal {}

fn refuse<T>(why: impl Into<String>) -> Result<T, Refusal> {
    Err(Refusal(why.into()))
}

/// A checked `run` ask: what to run and its limits.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunAsk {
    pub id: Option<i64>,
    pub repo: String,
    pub git_ref: String,
    pub command: String,
    pub timeout_s: Option<u64>,
    pub vcpu: Option<u64>,
}

/// An ask's JSON text, checked.
pub fn parse(text: &str) -> Result<RunAsk, Refusal> {
    let value: Value =
        serde_json::from_str(text).map_err(|e| Refusal(format!("the ask is not JSON: {e}")))?;
    validate(&value)
}

/// An ask as the store serves it, checked with the store's bounds and a few of its own (a ref is
/// one plain commit or branch; a repo part is not `.` or `..`).
pub fn validate(ask: &Value) -> Result<RunAsk, Refusal> {
    let Value::Object(ask) = ask else { return refuse("the ask is a JSON object") };
    if let Some(other) = ask.keys().find(|k| !ASK_FIELDS.contains(&k.as_str())) {
        return refuse(format!(
            "a run ask has no field {other}: it carries a repo, ref, command and limits only"
        ));
    }
    match ask.get("type").and_then(Value::as_str) {
        Some("run") => {}
        Some(other) => return refuse(format!("this ask is a {other}, not a run")),
        None => return refuse("the ask has no type"),
    }
    match ask.get("state").and_then(Value::as_str) {
        Some("accepted") => {}
        Some(other) => {
            return refuse(format!("this run is {other}: only a run its person accepted is run"));
        }
        None => return refuse("the ask has no state: only a run its person accepted is run"),
    }
    if ask.get("result").is_some_and(|r| !r.is_null()) {
        return refuse("this run already has a result");
    }
    match ask.get("to") {
        Some(Value::Object(to))
            if to.get("person").and_then(Value::as_str).is_some_and(valid_person) => {}
        _ => return refuse("the ask names no person it is addressed to (to.person)"),
    }
    let repo = text(ask, "repo", MAX_FIELD)?;
    if !valid_repo(&repo) {
        return refuse("repo is owner/name");
    }
    let git_ref = text(ask, "ref", MAX_FIELD)?;
    if !plain_ref(&git_ref) {
        return refuse("ref is one pushed commit or branch name");
    }
    let command = text(ask, "command", MAX_COMMAND)?;
    if command.trim().is_empty() || command.chars().any(char::is_control) {
        return refuse("command is one line");
    }
    let (timeout_s, vcpu) = match ask.get("limits") {
        None | Some(Value::Null) => (None, None),
        Some(Value::Object(limits)) => {
            if let Some(other) = limits.keys().find(|k| *k != "timeout_s" && *k != "vcpu") {
                return refuse(format!("limits are timeout_s and vcpu, not {other}"));
            }
            (bound(limits, "timeout_s", MAX_TIMEOUT_S)?, bound(limits, "vcpu", MAX_VCPU)?)
        }
        Some(_) => return refuse("limits is {timeout_s?, vcpu?}"),
    };
    let id = ask.get("id").and_then(Value::as_i64);
    Ok(RunAsk { id, repo, git_ref, command, timeout_s, vcpu })
}

fn text(ask: &Map<String, Value>, key: &str, max: usize) -> Result<String, Refusal> {
    match ask.get(key) {
        Some(Value::String(s)) if s.trim().is_empty() => refuse(format!("{key} is required")),
        Some(Value::String(s)) if s.chars().count() > max => {
            refuse(format!("{key} is at most {max} characters"))
        }
        Some(Value::String(s)) => Ok(s.clone()),
        None | Some(Value::Null) => refuse(format!("{key} is required")),
        Some(_) => refuse(format!("{key} must be a string")),
    }
}

fn valid_person(p: &str) -> bool {
    !p.is_empty() && p.len() <= 200 && !p.chars().any(char::is_control)
}

/// `owner/name`, each part of letters, digits, '.', '_' or '-', and neither `.` nor `..`.
fn valid_repo(repo: &str) -> bool {
    let part = |p: &str| {
        !p.is_empty()
            && p.len() <= 100
            && p != "."
            && p != ".."
            && p.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    };
    matches!(repo.split('/').collect::<Vec<_>>().as_slice(), [owner, name] if part(owner) && part(name))
}

/// One commit or branch name, never a refspec (`a:b`, `+a`), a pattern or a revision expression:
/// git fetches it as given.
fn plain_ref(r: &str) -> bool {
    !r.starts_with(['-', '+', '/'])
        && !r.ends_with(['/', '.'])
        && !r.contains("..")
        && !r.contains("@{")
        && !r.chars().any(|c| {
            c.is_whitespace()
                || c.is_control()
                || matches!(c, ':' | '^' | '~' | '?' | '*' | '[' | '\\')
        })
}

/// A limit in `1..=max`, when the ask names it.
fn bound(limits: &Map<String, Value>, key: &str, max: u64) -> Result<Option<u64>, Refusal> {
    match limits.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_u64().filter(|n| (1..=max).contains(n)) {
            Some(n) => Ok(Some(n)),
            None => refuse(format!("{key} is 1 to {max}")),
        },
    }
}

/// Where a run goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Place {
    /// This machine, in a fresh folder.
    Local,
    /// The scheduler (`cmux-ci`).
    Scheduler,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub place: Place,
    pub timeout_s: u64,
    /// Why it goes there, in plain words.
    pub why: String,
}

/// Where ASK runs on a machine with CPUS cores: here when light, the scheduler when it needs more
/// vCPU than CPUS or longer than [`LOCAL_MAX_TIMEOUT_S`]; refused past the scheduler's cap.
pub fn plan(ask: &RunAsk, cpus: usize) -> Result<Plan, Refusal> {
    let timeout_s = ask.timeout_s.unwrap_or(LOCAL_MAX_TIMEOUT_S);
    let cpus = u64::try_from(cpus.max(1)).unwrap_or(u64::MAX);
    let heavy = match ask.vcpu {
        Some(vcpu) if vcpu > cpus => {
            Some(format!("it asks for {vcpu} vCPU and this machine has {cpus}"))
        }
        _ if timeout_s > LOCAL_MAX_TIMEOUT_S => Some(format!(
            "its timeout of {timeout_s} s is past the {LOCAL_MAX_TIMEOUT_S} s a run stays on this machine"
        )),
        _ => None,
    };
    match heavy {
        None => Ok(Plan {
            place: Place::Local,
            timeout_s,
            why: "light: it runs on this machine".into(),
        }),
        Some(_) if timeout_s > SCHEDULER_MAX_TIMEOUT_S => refuse(format!(
            "its timeout of {timeout_s} s is past this machine's {LOCAL_MAX_TIMEOUT_S} s and the scheduler's {SCHEDULER_MAX_TIMEOUT_S} s"
        )),
        Some(why) => Ok(Plan { place: Place::Scheduler, timeout_s, why: format!("heavy: {why}") }),
    }
}

/// The scheduler binary: `$ACPMUX_RUN_ASK_SCHEDULER`, else `cmux-ci`.
pub fn scheduler_bin() -> String {
    std::env::var(SCHEDULER_ENV)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_SCHEDULER.into())
}

/// The scheduler's argv for "run COMMAND at SHA". `cmux-ci` has no general form for a repo and
/// ref of anyone's: the closest is `cmux-ci test --at SHA --timeout S -- sh -c COMMAND`, run in a
/// checkout of the repo, which runs at SHA on the fleet and needs SHA to be the head of an open
/// pull request there. It has no vCPU flag; the fleet picks the runner.
pub fn scheduler_argv(bin: &str, sha: &str, timeout_s: u64, command: &str) -> Vec<String> {
    let timeout = timeout_s.min(SCHEDULER_MAX_TIMEOUT_S).to_string();
    [bin, "test", "--at", sha, "--timeout", &timeout, "--", "sh", "-c", command]
        .map(str::to_owned)
        .to_vec()
}

/// The remote a repo is fetched from.
pub fn github_url(repo: &str) -> String {
    format!("https://github.com/{repo}.git")
}

/// What a run came back with, in the store's `result` shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunResult {
    pub exit: i32,
    pub tail: String,
    pub artifacts: Vec<String>,
}

impl RunResult {
    pub fn to_json(&self) -> Value {
        json!({ "exit": self.exit, "tail": self.tail, "artifacts": self.artifacts })
    }
}

/// The last MAX bytes of BYTES as text: it starts on a whole character, and bytes that are not
/// UTF-8 read as U+FFFD.
pub fn tail(bytes: &[u8], max: usize) -> String {
    let start = bytes.len().saturating_sub(max);
    let rest = bytes.get(start..).unwrap_or_default();
    // A cut inside a character skips its continuation bytes (at most three).
    let skip =
        if start == 0 { 0 } else { rest.iter().take(3).take_while(|b| *b & 0xC0 == 0x80).count() };
    String::from_utf8_lossy(rest.get(skip..).unwrap_or_default()).into_owned()
}

/// Run ASK as PLAN says: fetch REMOTE at its ref into a fresh temp folder (removed afterwards,
/// and only it), then run the command there under the timeout, or hand it to SCHEDULER.
pub fn execute(ask: &RunAsk, plan: &Plan, remote: &str, scheduler: &str) -> Result<RunResult> {
    let temp = tempfile::Builder::new().prefix("acpmux-run-ask-").tempdir()?;
    let src = temp.path().join("src");
    let sha = fetch(remote, &ask.git_ref, &src)
        .with_context(|| format!("could not fetch {}@{}", ask.repo, ask.git_ref))?;
    let result = match plan.place {
        Place::Local => {
            let mut cmd = Command::new("sh");
            cmd.arg("-c").arg(&ask.command);
            kept_env(&mut cmd);
            run_bounded(cmd, &src, plan.timeout_s)
        }
        Place::Scheduler => {
            let argv = scheduler_argv(scheduler, &sha, plan.timeout_s, &ask.command);
            let (bin, args) = argv.split_first().ok_or_else(|| anyhow!("no scheduler argv"))?;
            let mut cmd = Command::new(bin);
            cmd.args(args);
            run_bounded(cmd, &src, plan.timeout_s.saturating_add(SCHEDULER_GRACE_S))
        }
    };
    drop(temp);
    result
}

fn kept_env(cmd: &mut Command) {
    cmd.env_clear();
    for name in KEPT_ENV {
        if let Some(value) = std::env::var_os(name) {
            cmd.env(name, value);
        }
    }
}

/// `git init` DEST with REMOTE as `origin` (the scheduler reads the repo from it), fetch REF into
/// it, check it out detached; the commit it names.
fn fetch(remote: &str, git_ref: &str, dest: &Path) -> Result<String> {
    std::fs::create_dir(dest)?;
    git(dest, &["init", "-q"])?;
    git(dest, &["remote", "add", "origin", remote])?;
    git(
        dest,
        &["fetch", "-q", "--depth", "1", "--no-tags", "--no-recurse-submodules", "origin", git_ref],
    )?;
    git(dest, &["checkout", "-q", "--detach", "FETCH_HEAD"])?;
    Ok(git(dest, &["rev-parse", "HEAD"])?.trim().to_owned())
}

fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let mut out = tempfile::tempfile()?;
    let mut err = tempfile::tempfile()?;
    let mut cmd = Command::new("git");
    cmd.args(args).current_dir(dir).stdout(out.try_clone()?).stderr(err.try_clone()?);
    kept_env(&mut cmd);
    cmd.env("GIT_TERMINAL_PROMPT", "0");
    let verb = args.first().copied().unwrap_or_default();
    let status = wait_bounded(&mut cmd, Duration::from_secs(FETCH_TIMEOUT_S))?
        .ok_or_else(|| anyhow!("git {verb}: no answer in {FETCH_TIMEOUT_S} s"))?;
    if !status.success() {
        let why = tail(&last_bytes(&mut err, 1000)?, 1000);
        return Err(anyhow!("git {verb}: {}", why.trim()));
    }
    let mut bytes = Vec::new();
    out.rewind()?;
    out.read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Start CMD in its own process group with no stdin and wait at most LIMIT: its status, or `None`
/// when it still ran. The child is a `cmux_process::Child`: dropped while it runs (the `None`
/// case), it and its group are ended.
fn wait_bounded(cmd: &mut Command, limit: Duration) -> std::io::Result<Option<ExitStatus>> {
    cmd.stdin(Stdio::null()).process_group(0);
    let mut child = cmd.spawn()?;
    child.wait_timeout(limit)
}

/// The last N bytes of FILE.
fn last_bytes(file: &mut File, n: u64) -> std::io::Result<Vec<u8>> {
    let len = file.metadata()?.len();
    file.seek(SeekFrom::Start(len.saturating_sub(n)))?;
    let mut bytes = Vec::new();
    file.take(n).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Run CMD in DIR with stdout and stderr in one unnamed file, for at most TIMEOUT_S; its exit and
/// the last [`TAIL_BYTES`] of what it wrote. Memory stays at the tail's size however much it
/// writes; the file goes with this call.
fn run_bounded(mut cmd: Command, dir: &Path, timeout_s: u64) -> Result<RunResult> {
    let mut out = tempfile::tempfile()?;
    cmd.current_dir(dir).stdout(out.try_clone()?).stderr(out.try_clone()?);
    let exit = match wait_bounded(&mut cmd, Duration::from_secs(timeout_s))? {
        Some(status) => exit_code(status),
        None => TIMED_OUT_EXIT,
    };
    let kept = last_bytes(&mut out, u64::try_from(KEPT_BYTES).unwrap_or(u64::MAX))?;
    let mut text = tail(&kept, TAIL_BYTES);
    if exit == TIMED_OUT_EXIT && text.len() < TAIL_BYTES {
        text.push_str(&format!("\n[run-ask: timed out after {timeout_s} s]"));
    }
    Ok(RunResult { exit, tail: text, artifacts: Vec::new() })
}

/// A status as the store's `exit` (-255 to 255): the code, or 128 + the signal that ended it.
fn exit_code(status: ExitStatus) -> i32 {
    #[cfg(unix)]
    if let Some(signal) = std::os::unix::process::ExitStatusExt::signal(&status) {
        return 128_i32.saturating_add(signal);
    }
    status.code().unwrap_or(1).clamp(-255, 255)
}

/// `acpmux run-ask FILE|-`: read the ask, run it, print the result JSON. A refused ask is an
/// error with its reason; a command that ran exits 0 here whatever its own exit, which the result
/// carries.
pub async fn run_cli(file: String) -> Result<()> {
    use crate::cli::errors::{AppError, Code};
    let text = if file == "-" {
        let mut text = String::new();
        std::io::stdin().read_to_string(&mut text)?;
        text
    } else {
        std::fs::read_to_string(&file).with_context(|| format!("could not read {file}"))?
    };
    let refused =
        |r: Refusal| AppError::new(Code::Refused, "run_ask_refused", format!("not run: {r}"));
    let ask = parse(&text).map_err(refused)?;
    let cpus = std::thread::available_parallelism().map_or(1, usize::from);
    let plan = plan(&ask, cpus).map_err(refused)?;
    let remote = github_url(&ask.repo);
    let scheduler = scheduler_bin();
    let result =
        tokio::task::spawn_blocking(move || execute(&ask, &plan, &remote, &scheduler)).await??;
    crate::cli::output::print_json(&result.to_json());
    Ok(())
}

#[cfg(all(test, unix))]
#[path = "run_ask_tests.rs"]
mod tests;
