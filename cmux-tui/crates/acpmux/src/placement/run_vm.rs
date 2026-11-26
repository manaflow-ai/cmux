//! Run VMs (RFD 0144 piece 3, "The agentic computer"): a heavy build or test run an agent starts
//! on a Cloud machine runs on a fork of that machine instead, its output streams back as the
//! tool call's own output, and the files it changed inside the checkout come back and are applied
//! before the call returns. The agent sees one machine: it ran `cargo test`, and the transcript
//! reads the same as if it had run here.
//!
//! On by default on an AutoCloud machine: a daemon on a Cloud machine with an id
//! ([`super::sub_fork::this_machine`]) sends heavy classes to a run VM unless the kill switch is
//! thrown (`cloud.runVms: false` in the settings file, or `CMUX_RUN_VMS=0`, [`run_vms_on`]). Leo,
//! 2026-11-25: "it doesnt work if it's not \"on by default\"". Only the heavy classes go
//! ([`heavy_class`]: builds and test runs); everything else runs here as today, and any run VM
//! that cannot be had runs the command here (the live probe is the fork itself).
//!
//! How a command gets here: Claude Code's PreToolUse hook (`bg_hook.rs`) rewrites a heavy `Bash`
//! call into `acpmux run-vm -- CMD` ([`wrap`]), alone or inside the daemon task a slow command
//! already becomes. `acpmux run-vm` ([`main`]) then:
//! 1. snapshots the checkout as a git tree ([`super::sub_fork::snapshot`]), uncommitted edits
//!    included, so the patch back is relative to the files the fork starts from;
//! 2. forks this machine (`machine.fork`, cmux-platform `POST /v1/machines/{id}/fork`); a
//!    [`super::sub_fork::ForkGuard`] deletes the fork on every exit;
//! 3. wakes it and opens one ssh stream to it (`sub_fork_run::CloudLink`), which runs
//!    `acpmux sub-fork-job` there with a [`Job`] that carries the command: `sh -c CMD` in the
//!    same directory with the agent's `PATH`, stdout and stderr streamed line by line;
//! 4. applies the fork's patch (its changes inside the checkout, `.gitignore`d outputs left out)
//!    to this checkout, whatever the command's exit;
//! 5. exits with the command's exit code.
//!
//! Anything that fails before the command's first output line (no credential, the fork refused,
//! the fork unreachable) runs the command here instead, and says why on stderr: never fail a
//! command to make a point (RFD 0144, "Where a command runs"). Each run writes one row to
//! `$ACPMUX_HOME/run-vm.jsonl` (where it ran, fork and first-output times, files back, exit,
//! the fallback's cause), which is what the RFD's thresholds are re-measured from.

use super::sub_fork::{self, ForkGuard, Machines};
use super::sub_fork_run::{ForkLink, Frame, Harness, Job};
use base64::Engine as _;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _};

/// The hidden subcommand a heavy shell call is rewritten into.
pub const SUBCOMMAND: &str = "run-vm";

/// Heavy classes: (program, the word after it or None for any, why). Builds and test runs only;
/// dev servers and other commands that outlive their call are serve VMs (piece 5), not here.
const HEAVY: &[(&str, Option<&str>, &str)] = &[
    ("cargo", Some("build"), "a Rust build"),
    ("cargo", Some("b"), "a Rust build"),
    ("cargo", Some("test"), "a Rust test run"),
    ("cargo", Some("t"), "a Rust test run"),
    ("cargo", Some("nextest"), "a Rust test run"),
    ("cargo", Some("clippy"), "a Rust lint run"),
    ("cargo", Some("bench"), "a Rust benchmark run"),
    ("swift", Some("build"), "a Swift build"),
    ("swift", Some("test"), "a Swift test run"),
    ("xcodebuild", None, "an Xcode build"),
    ("go", Some("build"), "a Go build"),
    ("go", Some("test"), "a Go test run"),
    ("pnpm", Some("test"), "a test run"),
    ("pnpm", Some("build"), "a build"),
    ("npm", Some("test"), "a test run"),
    ("bun", Some("test"), "a test run"),
    ("yarn", Some("test"), "a test run"),
    ("yarn", Some("build"), "a build"),
    ("pytest", None, "a Python test run"),
    ("gradle", Some("build"), "a Gradle build"),
    ("gradlew", Some("build"), "a Gradle build"),
    ("mvn", None, "a Maven build"),
    ("bazel", Some("build"), "a Bazel build"),
    ("bazel", Some("test"), "a Bazel test run"),
];

/// Words that make a listed command a quick read, not a run.
const QUICK: &[&str] = &["--help", "-h", "help", "--version", "-V", "-version", "-list", "--list"];

/// Why `command` is a heavy class that goes to a run VM, or None. A command that backgrounds
/// itself (a trailing `&`), runs acpmux itself, or is already a run-VM call stays here.
pub fn heavy_class(command: &str) -> Option<&'static str> {
    let trimmed = command.trim_end();
    if trimmed.ends_with('&') && !trimmed.ends_with("&&") {
        return None;
    }
    let mut found = None;
    let mut acpmux = false;
    crate::host_load::for_each_command(command, &mut |argv: &[&str]| {
        let Some(program) = argv.first().map(|w| w.rsplit('/').next().unwrap_or(w)) else {
            return;
        };
        if program == "acpmux" || program.starts_with("acpmux-") {
            acpmux = true;
        }
        if found.is_some() {
            return;
        }
        let rest = argv.get(1..).unwrap_or_default();
        if rest.iter().any(|w| QUICK.contains(w)) {
            return;
        }
        for (tool, next, why) in HEAVY {
            if *tool == program && next.is_none_or(|n| rest.first() == Some(&n)) {
                found = Some(*why);
                return;
            }
        }
    });
    if acpmux { None } else { found }
}

/// The kill switch's settings key: `false` keeps every command here. Unset is on.
pub const KILL_KEY: &str = "cloud.runVms";
/// The kill switch's environment variable: `0`, `false` or `off` keeps every command here.
pub const KILL_ENV: &str = "CMUX_RUN_VMS";

/// Whether run VMs are on: on unless the kill switch is thrown in the environment or settings.
pub fn run_vms_on() -> bool {
    use crate::user_settings::{self, Settings};
    let doc = match user_settings::read() {
        Settings::Parsed(doc) => Some(doc),
        _ => None,
    };
    on_in(doc.as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// [`run_vms_on`] over a parsed settings document and the environment variable's value.
pub fn on_in(doc: Option<&serde_json::Value>, env: Option<&str>) -> bool {
    let killed_env = env
        .map(|v| v.trim().to_ascii_lowercase())
        .is_some_and(|v| matches!(v.as_str(), "0" | "false" | "off" | "no"));
    let killed_key = doc.and_then(|d| crate::user_settings::value(d, KILL_KEY))
        == Some(serde_json::Value::Bool(false));
    !(killed_env || killed_key)
}

/// Whether a heavy `command` goes to a run VM now: run VMs `on`, a Cloud `machine`, a heavy class.
pub fn goes(on: bool, machine: Option<&str>, command: &str) -> Option<&'static str> {
    machine.map(str::trim).filter(|m| !m.is_empty())?;
    if !on {
        return None;
    }
    heavy_class(command)
}

/// The shell text that runs `command` through `acpmux run-vm` with this binary (`exe` and its
/// fixed `args`): what the hook puts in place of a heavy call.
pub fn wrap(words: &[String], command: &str) -> String {
    let mut all = words.to_vec();
    all.extend([SUBCOMMAND.to_owned(), "--".to_owned(), command.to_owned()]);
    crate::agent_tools::quoted(&all)
}

/// The fork's end for a command job: `sh -c CMD` in the job's directory, stdout and stderr as
/// one stream of lines, the exit code (a signal is 128 + its number).
pub struct ShellHarness;

impl Harness for ShellHarness {
    async fn run(&self, job: &Job, out: &mut (dyn FnMut(&str) + Send)) -> Result<i32, String> {
        let command = job.command.as_deref().ok_or("no command")?;
        let mut cmd = cmux_process::Command::new("/bin/sh");
        // One stream: stderr joins stdout in the shell itself, so their order is kept.
        cmd.arg("-c").arg(format!("exec 2>&1\n{command}"));
        cmd.current_dir(job.cwd.as_deref().unwrap_or(&job.checkout));
        if let Some(path) = job.path.as_deref().filter(|p| !p.is_empty()) {
            cmd.env("PATH", path);
        }
        // Its own group: dropped mid-run (the stream gone), the child ends the whole command.
        cmd.process_group(0)
            .stdin(cmux_process::Stdio::null())
            .stdout(cmux_process::Stdio::piped())
            .stderr(cmux_process::Stdio::null());
        let mut child = cmd.spawn().map_err(|e| format!("sh: {e}"))?;
        let stdout = child.stdout.take().ok_or("sh: no stdout")?;
        // A blocking reader hands lines over; the child stays here, so a drop ends it.
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let reader = tokio::task::spawn_blocking(move || {
            use std::io::BufRead as _;
            for line in std::io::BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        while let Some(l) = rx.recv().await {
            out(&l);
        }
        let _ = reader.await;
        // Its stdout closed: the shell is ending, so this wait is short.
        let status = child.wait().map_err(|e| format!("sh: {e}"))?;
        Ok(exit_code(status))
    }
}

fn exit_code(status: std::process::ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt as _;
        if let Some(sig) = status.signal() {
            return 128 + sig;
        }
    }
    status.code().unwrap_or(1)
}

/// Where a run ended up, one row of `run-vm.jsonl`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub class: String,
    /// `fork` when it ran on a run VM, `here` when it fell back.
    pub ran: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fork: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fork_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub first_output_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wall_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub files: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fork_deleted: Option<bool>,
    /// Why it ran here instead, or why its files did not come back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cause: Option<String>,
}

/// How a run on a fork ended.
#[derive(Debug)]
pub enum Ran {
    /// The command ran on the fork; its exit, and the files applied back (or why they were not).
    Done { exit: i32, row: Row },
    /// Nothing ran there (the step and why): run it here instead.
    Here { row: Row },
}

/// Run `command` on a fork of `machine`: snapshot, fork, wake, stream, apply back, delete.
/// `out` gets each output line as it comes.
#[allow(clippy::too_many_arguments)]
pub async fn on_fork<M: Machines, L: ForkLink>(
    machines: Arc<M>,
    link: &L,
    machine: &str,
    class: &str,
    command: &str,
    cwd: &Path,
    path: Option<String>,
    out: &mut (dyn FnMut(&str) + Send),
) -> Ran {
    let began = Instant::now();
    let mut row = Row {
        class: class.to_owned(),
        ran: "here",
        fork: None,
        fork_ms: None,
        start_ms: None,
        first_output_ms: None,
        wall_ms: None,
        files: None,
        exit: None,
        fork_deleted: None,
        cause: None,
    };
    let here = |mut row: Row, cause: String| {
        row.cause = Some(cause);
        Ran::Here { row }
    };
    let checkout = match toplevel(cwd) {
        Ok(c) => c,
        Err(e) => return here(row, format!("snapshot: {e}")),
    };
    let base = match sub_fork::snapshot(&checkout) {
        Ok(b) => b,
        Err(e) => return here(row, format!("snapshot: {e}")),
    };
    let key = format!("run-vm-{}-{}", std::process::id(), began.elapsed().as_nanos());
    let fork_began = Instant::now();
    let fork = match machines.fork(machine, &key).await {
        Ok(id) => id,
        Err(e) => return here(row, format!("fork: {e}")),
    };
    row.fork_ms = Some(fork_began.elapsed().as_millis() as u64);
    row.fork = Some(fork.clone());
    let guard = ForkGuard::new(machines, fork.clone());
    let ran =
        stream(link, &fork, &checkout, &base, command, cwd, path, &began, &mut row, out).await;
    row.fork_deleted = Some(guard.delete().await);
    row.wall_ms = Some(began.elapsed().as_millis() as u64);
    match ran {
        Ok(exit) => {
            row.ran = "fork";
            row.exit = Some(exit);
            Ran::Done { exit, row }
        }
        Err((false, cause)) => here(row, cause),
        Err((true, cause)) => {
            // It started there and broke mid-run: not rerun here (it may not be idempotent).
            row.ran = "fork";
            row.exit = Some(255);
            out(&format!("[run-vm] the run VM failed mid-command: {cause}"));
            row.cause = Some(cause);
            Ran::Done { exit: 255, row }
        }
    }
}

/// The stream half of [`on_fork`]: `Err((started, why))`, `started` once output was seen.
#[allow(clippy::too_many_arguments)]
async fn stream<L: ForkLink>(
    link: &L,
    fork: &str,
    checkout: &Path,
    base: &str,
    command: &str,
    cwd: &Path,
    path: Option<String>,
    began: &Instant,
    row: &mut Row,
    out: &mut (dyn FnMut(&str) + Send),
) -> Result<i32, (bool, String)> {
    let woke = Instant::now();
    link.start(fork).await.map_err(|e| (false, format!("waking the fork: {e}")))?;
    row.start_ms = Some(woke.elapsed().as_millis() as u64);
    let job = Job {
        checkout: checkout.to_owned(),
        sync_patch: String::new(),
        prompt: String::new(),
        name: String::new(),
        model: None,
        command: Some(command.to_owned()),
        cwd: Some(cwd.to_owned()),
        path,
    };
    let mut lines =
        link.open(fork, &job).await.map_err(|e| (false, format!("reaching the fork: {e}")))?;
    let mut started = false;
    let mut line = String::new();
    loop {
        line.clear();
        let n = lines
            .read_line(&mut line)
            .await
            .map_err(|e| (started, format!("the fork's stream: {e}")))?;
        if n == 0 {
            return Err((started, "the fork's stream ended before the command did".into()));
        }
        let Ok(frame) = serde_json::from_str::<Frame>(line.trim_end()) else { continue };
        match frame {
            Frame::Base(fork_base) => {
                if fork_base != base {
                    return Err((false, "the fork's files are not the snapshot's".into()));
                }
            }
            Frame::Out(text) => {
                if !started {
                    started = true;
                    row.first_output_ms = Some(began.elapsed().as_millis() as u64);
                }
                out(&text);
            }
            Frame::Error(e) => return Err((started, format!("on the fork: {e}"))),
            Frame::Done { exit, patch } => {
                let patch = base64::engine::general_purpose::STANDARD
                    .decode(patch.as_bytes())
                    .map_err(|e| (true, format!("the fork's patch: {e}")))?;
                match sub_fork::apply(checkout, &patch) {
                    Ok(files) => row.files = Some(files),
                    Err(e) => {
                        out(&format!("[run-vm] its file changes did not apply here: {e}"));
                        row.cause = Some(format!("apply: {e}"));
                        return Ok(if exit == 0 { 1 } else { exit });
                    }
                }
                return Ok(exit);
            }
        }
    }
}

/// The git checkout `cwd` is in.
fn toplevel(cwd: &Path) -> Result<PathBuf, String> {
    let out = cmux_process::Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if !out.status.success() {
        return Err("not a git checkout".into());
    }
    Ok(PathBuf::from(String::from_utf8_lossy(&out.stdout).trim()))
}

/// The rows file: `$ACPMUX_HOME/run-vm.jsonl`.
pub fn rows_path() -> PathBuf {
    crate::config::home().join("run-vm.jsonl")
}

fn write_row(row: &Row) {
    let mut v = serde_json::to_value(row).unwrap_or_default();
    if let Some(o) = v.as_object_mut() {
        o.insert("at".into(), serde_json::json!(chrono::Utc::now().to_rfc3339()));
    }
    let path = rows_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = std::io::Write::write_all(&mut f, format!("{v}\n").as_bytes());
    }
}

/// `acpmux run-vm -- CMD`: run `CMD` on a run VM when it goes there, else here, and exit with
/// its exit code.
pub async fn main(command: &str) -> anyhow::Result<i32> {
    let machine = sub_fork::this_machine();
    let class = goes(run_vms_on(), machine.as_deref(), command);
    let (Some(machine), Some(class)) = (machine, class) else { return run_here(command).await };
    // The fork backend (cmux-cloud-api) is unix-only: elsewhere every command runs here.
    #[cfg(not(unix))]
    {
        let _ = (machine, class);
        eprintln!("[run-vm] ran here: Cloud forks need a unix build of acpmux");
        return run_here(command).await;
    }
    #[cfg(unix)]
    on_cloud(command, machine, class).await
}

/// `main` once the command goes to a run VM: fork this machine on cmux Cloud and run it there.
#[cfg(unix)]
async fn on_cloud(command: &str, machine: String, class: &'static str) -> anyhow::Result<i32> {
    let machines = match sub_fork::CloudMachines::from_env(|k| std::env::var(k).ok()) {
        Ok(m) => Arc::new(m),
        Err(e) => {
            eprintln!("[run-vm] ran here: {e}");
            return run_here(command).await;
        }
    };
    let link = super::sub_fork_run::CloudLink::new(machines.request.clone());
    let cwd = std::env::current_dir()?;
    eprintln!("[run-vm] {class}: running on a fork of this machine");
    let mut stdout = tokio::io::stdout();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let mut push = move |l: &str| {
        let _ = tx.send(l.to_owned());
    };
    let run = on_fork(
        machines,
        &link,
        &machine,
        class,
        command,
        &cwd,
        std::env::var("PATH").ok(),
        &mut push,
    );
    tokio::pin!(run);
    let ran = loop {
        tokio::select! {
            biased;
            Some(l) = rx.recv() => {
                stdout.write_all(format!("{l}\n").as_bytes()).await?;
                stdout.flush().await?;
            }
            ran = &mut run => break ran,
        }
    };
    while let Ok(l) = rx.try_recv() {
        stdout.write_all(format!("{l}\n").as_bytes()).await?;
    }
    stdout.flush().await?;
    match ran {
        Ran::Done { exit, row } => {
            write_row(&row);
            eprintln!(
                "[run-vm] ran on a run VM: exit {exit}, {} file(s) back, {} s",
                row.files.unwrap_or(0),
                row.wall_ms.unwrap_or(0) / 1000
            );
            Ok(exit)
        }
        Ran::Here { row } => {
            eprintln!("[run-vm] ran here: {}", row.cause.as_deref().unwrap_or("no run VM"));
            write_row(&row);
            run_here(command).await
        }
    }
}

/// Run `command` here with this process's stdio, as the shell call would have.
async fn run_here(command: &str) -> anyhow::Result<i32> {
    let command = command.to_owned();
    // The command's own terminal streams: it runs here exactly as the agent asked.
    let status = tokio::task::spawn_blocking(move || {
        cmux_process::Command::new("/bin/sh").arg("-c").arg(command).status()
    })
    .await??;
    Ok(exit_code(status))
}

// The fork and move tests use exec bits and Unix sockets; Windows builds none of them.
#[cfg(all(test, unix))]
#[path = "run_vm_tests.rs"]
mod tests;
