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
//!    same directory with the caller's environment (`run_vm_env.rs` names the few variables held
//!    back), stdout and stderr streamed as raw bytes and replayed each to its own fd here (one
//!    pipe on the fork when they are one file here, so their order holds: `run_vm_shell.rs`);
//! 4. applies the fork's patch (its changes inside the checkout, `.gitignore`d outputs left out)
//!    to this checkout, whatever the command's exit, then what a patch cannot carry: empty
//!    folders and exact modes (`run_vm_tree.rs`);
//! 5. exits with the command's exit code.
//!
//! Anything that fails before the command's first output line (no credential, the fork refused,
//! the fork unreachable) runs the command here instead, and says why on stderr: never fail a
//! command to make a point (RFD 0144, "Where a command runs"). Each run writes one row to
//! `$ACPMUX_HOME/run-vm.jsonl` (where it ran, fork and first-output times, files back, exit,
//! the fallback's cause), which is what the RFD's thresholds are re-measured from.

use super::command_shadow::{Predicted, workload_shape};
use super::sub_fork::{self, ForkGuard, Machines};
use super::sub_fork_run::{ForkLink, Frame, Job};
use super::sub_fork_wire::B64;
use base64::Engine as _;
use std::ffi::OsString;
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
    super::exec_router::route(on, machine, command, super::exec_router::Force::Auto)
}

/// The programs the heavy table names, each once (the exec router's shims, `exec_router.rs`).
pub fn heavy_programs() -> Vec<&'static str> {
    let mut all: Vec<&'static str> = Vec::new();
    for (program, _, _) in HEAVY {
        if !all.contains(program) {
            all.push(program);
        }
    }
    all
}

/// The shell text that runs `command` through `acpmux run-vm` with this binary (`exe` and its
/// fixed `args`): what the hook puts in place of a heavy call.
pub fn wrap(words: &[String], command: &str) -> String {
    let mut all = words.to_vec();
    all.extend([SUBCOMMAND.to_owned(), "--".to_owned(), command.to_owned()]);
    crate::agent_tools::quoted(&all)
}

pub use super::run_vm_rows::{
    ROWS_MAX_BYTES, Row, bound_rows, program_of, rows_path, write_forced_here, write_row,
};
pub use super::run_vm_shell::{ShellHarness, exit_code};

/// The fork sizes a run VM can start at, smallest first: (name, vCPU, GiB), the platform's chat
/// ladder (cmux-platform `Sizes.ts`). A fork never starts smaller than its source.
const LADDER: &[(&str, f64, f64)] = &[
    ("sm", 2.0, 4.0),
    ("md", 4.0, 8.0),
    ("lg", 8.0, 16.0),
    ("xl", 16.0, 32.0),
    ("2xl", 32.0, 64.0),
];

/// The size a run VM starts at (RFD 0144 piece 8): the smallest ladder size that covers the
/// predicted shape, the largest when none does, or none when the source's `sm` already covers it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sizing {
    pub size: &'static str,
    pub vcpu: f64,
    pub mem_gib: f64,
    /// How many of this repository's past runs predicted it; 0 is the class default.
    pub runs: usize,
}

/// The run VM's size for what the rows file predicts, when it is above the smallest.
pub fn sizing(predicted: &Predicted) -> Option<Sizing> {
    let need = workload_shape(predicted.need?);
    let (size, vcpu, mem_gib) = LADDER
        .iter()
        .find(|(_, vcpu, mem)| *vcpu >= need.vcpu && *mem >= need.mem_gib)
        .or(LADDER.last())
        .copied()?;
    (size != LADDER[0].0).then_some(Sizing { size, vcpu, mem_gib, runs: predicted.runs })
}

/// The notice row for a sized run VM: what it starts at and why, in place of an ask.
pub fn sizing_notice(class: &str, sizing: &Sizing) -> String {
    let from = match sizing.runs {
        0 => "the usual need of the class".to_owned(),
        1 => "its last run here".to_owned(),
        n => format!("its last {n} runs here"),
    };
    format!(
        "[run-vm] {class}: running on a {} vCPU, {} GiB run VM, sized from {from}",
        sizing.vcpu, sizing.mem_gib
    )
}

/// How a run on a fork ended.
#[derive(Debug)]
pub enum Ran {
    /// The command ran on the fork; its exit, and the files applied back (or why they were not).
    Done { exit: i32, row: Row },
    /// Nothing ran there (the step and why): run it here instead.
    Here { row: Row },
}

/// One command a caller hands to a run VM.
#[derive(Debug, Clone)]
pub struct Call<'a> {
    pub class: &'a str,
    pub command: &'a str,
    pub cwd: &'a Path,
    /// The caller's whole environment: [`super::run_vm_env::forward`] decides what goes.
    pub env: Vec<(OsString, OsString)>,
    /// The caller's stdout and stderr are one file ([`super::run_vm_shell::same_file`]).
    pub merged: bool,
    /// The ladder size to start the run VM at ([`sizing`]); None is the source's size.
    pub size: Option<&'a str>,
}

/// What a run's output is handed to: the fd it belongs on (1 or 2) and its raw bytes.
pub type Out<'a> = &'a mut (dyn FnMut(u8, &[u8]) + Send);

/// Run `call` on a fork of `machine`: snapshot, fork, wake, stream, apply back, delete. `out`
/// gets the command's output as it comes, and this router's own words on fd 2.
pub async fn on_fork<M: Machines, L: ForkLink>(
    machines: Arc<M>,
    link: &L,
    machine: &str,
    call: &Call<'_>,
    out: Out<'_>,
) -> Ran {
    let (command, cwd) = (call.command, call.cwd);
    let began = Instant::now();
    let mut row = Row {
        class: call.class.to_owned(),
        size: call.size.map(str::to_owned),
        ran: "here",
        via: None,
        program: program_of(command),
        ..Row::default()
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
    let fork = match machines.fork_sized(machine, &key, call.size).await {
        Ok(id) => id,
        Err(e) => return here(row, format!("fork: {e}")),
    };
    row.fork_ms = Some(fork_began.elapsed().as_millis() as u64);
    row.fork = Some(fork.clone());
    let guard = ForkGuard::new(machines, fork.clone());
    let ran = stream(link, &fork, &checkout, &base, call, &began, &mut row, out).await;
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
            out(2, format!("[run-vm] the run VM failed mid-command: {cause}\n").as_bytes());
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
    call: &Call<'_>,
    began: &Instant,
    row: &mut Row,
    out: Out<'_>,
) -> Result<i32, (bool, String)> {
    let woke = Instant::now();
    link.start(fork).await.map_err(|e| (false, format!("waking the fork: {e}")))?;
    row.start_ms = Some(woke.elapsed().as_millis() as u64);
    let (env, env_held) = super::run_vm_env::forward(call.env.iter().cloned());
    let job = Job {
        checkout: checkout.to_owned(),
        sync_patch: String::new(),
        prompt: String::new(),
        name: String::new(),
        model: None,
        command: Some(call.command.to_owned()),
        cwd: Some(call.cwd.to_owned()),
        // A fork whose acpmux predates `env` still finds the caller's tools.
        path: call.env.iter().find(|(k, _)| k == "PATH").map(|(_, v)| v.to_string_lossy().into()),
        env: env.into_iter().map(B64).collect(),
        env_held,
        merged: call.merged,
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
            Frame::Out(_) | Frame::Bytes { .. } => {
                let (fd, data) = match frame {
                    Frame::Bytes { fd, data } => (fd, data.0),
                    Frame::Out(text) => (1, format!("{text}\n").into_bytes()),
                    _ => continue,
                };
                *row.out_bytes.get_or_insert(0) += data.len();
                if !started {
                    started = true;
                    row.first_output_ms = Some(began.elapsed().as_millis() as u64);
                }
                out(fd, &data);
            }
            Frame::Error(e) => return Err((started, format!("on the fork: {e}"))),
            Frame::Done { exit, patch, tree } => {
                let patch = base64::engine::general_purpose::STANDARD
                    .decode(patch.as_bytes())
                    .map_err(|e| (true, format!("the fork's patch: {e}")))?;
                row.patch_bytes = Some(patch.len());
                let applied = sub_fork::apply(checkout, &patch).and_then(|files| {
                    super::run_vm_tree::apply(checkout, &tree).map(|paths| (files, paths))
                });
                match applied {
                    Ok((files, _)) => row.files = Some(files),
                    Err(e) => {
                        let say = format!("[run-vm] its file changes did not apply here: {e}\n");
                        out(2, say.as_bytes());
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

/// `acpmux run-vm -- CMD`: run `CMD` on a run VM when it goes there, else here, and exit with
/// its exit code.
pub async fn main(command: &str) -> anyhow::Result<i32> {
    use super::exec_router::{Force, route};
    let machine = sub_fork::this_machine();
    let force = Force::from_env();
    let class = route(run_vms_on(), machine.as_deref(), command, force);
    if let (Some(machine), Some(class)) = (machine, class)
        && let Some(exit) = fork_or_here(&machine, class, command, "hook").await?
    {
        return Ok(exit);
    }
    if force == Force::Local {
        write_forced_here(command, "hook");
    }
    run_here(command).await
}

/// Run `command` (a `class`) on a fork of `machine`, its output on this stdout: `Some(exit)` when
/// it ran there, None when it must run here (the row says why). `via` names what sent it.
/// The fork backend (cmux-cloud-api) is unix-only: elsewhere every command runs here.
#[cfg(not(unix))]
pub async fn fork_or_here(
    machine: &str,
    class: &'static str,
    command: &str,
    via: &'static str,
) -> anyhow::Result<Option<i32>> {
    let _ = (machine, class, command, via);
    eprintln!("[run-vm] ran here: Cloud forks need a unix build of acpmux");
    Ok(None)
}

/// Run `command` (a `class`) on a fork of `machine`, its output on this stdout: `Some(exit)` when
/// it ran there, None when it must run here (the row says why). `via` names what sent it.
#[cfg(unix)]
pub async fn fork_or_here(
    machine: &str,
    class: &'static str,
    command: &str,
    via: &'static str,
) -> anyhow::Result<Option<i32>> {
    let machines = match sub_fork::CloudMachines::from_env(|k| std::env::var(k).ok()) {
        Ok(m) => Arc::new(m),
        Err(e) => {
            eprintln!("[run-vm] ran here: {e}");
            return Ok(None);
        }
    };
    let link = super::sub_fork_run::CloudLink::new(machines.request.clone());
    let cwd = std::env::current_dir()?;
    // AutoCloud sizes the run VM from the shadow table; without it, the source's size.
    let sized = super::auto_cloud_on()
        .then(|| {
            let repo = cwd.to_string_lossy();
            sizing(&super::command_sampler::predict_from_file(
                &super::command_sampler::file_path(),
                &repo,
                command,
            ))
        })
        .flatten();
    match &sized {
        Some(s) => eprintln!("{}", sizing_notice(class, s)),
        None => eprintln!("[run-vm] {class}: running on a fork of this machine"),
    }
    let (mut stdout, mut stderr) = (tokio::io::stdout(), tokio::io::stderr());
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(u8, Vec<u8>)>();
    let mut push = move |fd: u8, data: &[u8]| {
        let _ = tx.send((fd, data.to_vec()));
    };
    let call = Call {
        class,
        command,
        cwd: &cwd,
        env: std::env::vars_os().collect(),
        merged: super::run_vm_shell::stdio_merged(),
        size: sized.map(|s| s.size),
    };
    let run = on_fork(machines, &link, machine, &call, &mut push);
    tokio::pin!(run);
    // Each chunk on its own fd, written whole and flushed before the next: the order holds.
    let ran = loop {
        tokio::select! {
            biased;
            Some((fd, data)) = rx.recv() => replay(&mut stdout, &mut stderr, fd, &data).await?,
            ran = &mut run => break ran,
        }
    };
    while let Ok((fd, data)) = rx.try_recv() {
        replay(&mut stdout, &mut stderr, fd, &data).await?;
    }
    match ran {
        Ran::Done { exit, mut row } => {
            row.via = Some(via);
            write_row(&row);
            eprintln!(
                "[run-vm] ran on a run VM: exit {exit}, {} file(s) back, {} s",
                row.files.unwrap_or(0),
                row.wall_ms.unwrap_or(0) / 1000
            );
            Ok(Some(exit))
        }
        Ran::Here { mut row } => {
            row.via = Some(via);
            eprintln!("[run-vm] ran here: {}", row.cause.as_deref().unwrap_or("no run VM"));
            write_row(&row);
            Ok(None)
        }
    }
}

/// Write `data` to this process's `fd` (2 is stderr, anything else stdout), flushed.
async fn replay(
    stdout: &mut tokio::io::Stdout,
    stderr: &mut tokio::io::Stderr,
    fd: u8,
    data: &[u8],
) -> std::io::Result<()> {
    if fd == 2 {
        stderr.write_all(data).await?;
        stderr.flush().await
    } else {
        stdout.write_all(data).await?;
        stdout.flush().await
    }
}

/// Run `command` here with this process's stdio, as the shell call would have.
async fn run_here(command: &str) -> anyhow::Result<i32> {
    let command = command.to_owned();
    // The command's own terminal streams: it runs here exactly as the agent asked.
    let status = tokio::task::spawn_blocking(move || {
        cmux_process::Command::new("/bin/sh")
            .arg("-c")
            .arg(command)
            // Decided: a shim under it runs the real program here (`exec_router.rs`).
            .env(super::exec_router::ROUTED_ENV, "here")
            .status()
    })
    .await??;
    Ok(exit_code(status))
}

// Forks are git checkouts whose executable bits the tests compare: unix only.
#[cfg(all(test, unix))]
#[path = "run_vm_tests.rs"]
mod tests;
