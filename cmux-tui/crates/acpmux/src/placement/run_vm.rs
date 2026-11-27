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

use super::command_shadow::{Predicted, Shape, workload_shape};
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
        // Decided: a shim under it (a build script's `cc`, `make`'s `cargo`) runs the real
        // program here, on the run VM, never routes again (`exec_router.rs`).
        cmd.env(super::exec_router::ROUTED_ENV, "fork");
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
    /// The project whose published memory minimum set the size, when it was above the prediction.
    pub floor: Option<&'static str>,
}

/// The run VM's size for what the rows file predicts, when it is above the smallest.
pub fn sizing(predicted: &Predicted) -> Option<Sizing> {
    sizing_floored(predicted, None)
}

/// [`sizing`] with a known-heavy project's published memory minimum as a floor
/// (`heavy_precheck::memory_floor`): RFD 0133's "run on a build machine" button, taken without
/// asking (RFD 0144 piece 8). The floor alone sizes a command with no history.
pub fn sizing_floored(
    predicted: &Predicted,
    floor: Option<(crate::heavy_precheck::Project, u64)>,
) -> Option<Sizing> {
    let floor_gib = floor.map(|(_, bytes)| bytes as f64 / (1u64 << 30) as f64);
    let need = match (predicted.need.map(workload_shape), floor_gib) {
        (Some(need), Some(f)) => Shape { vcpu: need.vcpu, mem_gib: need.mem_gib.max(f) },
        (Some(need), None) => need,
        (None, Some(f)) => Shape { vcpu: 1.0, mem_gib: f },
        (None, None) => return None,
    };
    let floored =
        floor_gib.is_some_and(|f| predicted.need.map(workload_shape).is_none_or(|n| f > n.mem_gib));
    let (size, vcpu, mem_gib) = LADDER
        .iter()
        .find(|(_, vcpu, mem)| *vcpu >= need.vcpu && *mem >= need.mem_gib)
        .or(LADDER.last())
        .copied()?;
    let floor = floor.filter(|_| floored).map(|(p, _)| p.name());
    (size != LADDER[0].0).then_some(Sizing { size, vcpu, mem_gib, runs: predicted.runs, floor })
}

/// The notice row for a sized run VM: what it starts at and why, in place of an ask.
pub fn sizing_notice(class: &str, sizing: &Sizing) -> String {
    let from = match (sizing.floor, sizing.runs) {
        (Some(project), _) => format!("{project}'s published memory minimum"),
        (None, 0) => "the usual need of the class".to_owned(),
        (None, 1) => "its last run here".to_owned(),
        (None, n) => format!("its last {n} runs here"),
    };
    format!(
        "[run-vm] {class}: running on a {} vCPU, {} GiB run VM, sized from {from}",
        sizing.vcpu, sizing.mem_gib
    )
}

/// Where a run ended up, one row of `run-vm.jsonl`.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub class: String,
    /// The ladder size the run VM was asked for, when above the source's (RFD 0144 piece 8).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<String>,
    /// `fork` when it ran on a run VM, `here` when it fell back.
    pub ran: &'static str,
    /// What sent it: `hook` (Claude Code's Bash call), `shim` (a PATH shim, any process), `cli`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub via: Option<&'static str>,
    /// The program it ran (its first word's file name, never its arguments).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    /// Bytes of file changes the run VM sent back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patch_bytes: Option<usize>,
    /// Bytes of output the run VM streamed back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub out_bytes: Option<usize>,
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
    size: Option<&str>,
    out: &mut (dyn FnMut(&str) + Send),
) -> Ran {
    let began = Instant::now();
    let mut row = Row {
        class: class.to_owned(),
        size: size.map(str::to_owned),
        ran: "here",
        via: None,
        program: program_of(command),
        patch_bytes: None,
        out_bytes: None,
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
    let fork = match machines.fork_sized(machine, &key, size).await {
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
                *row.out_bytes.get_or_insert(0) += text.len() + 1;
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
                row.patch_bytes = Some(patch.len());
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
        let _ = crate::home_fs::create_dirs(dir);
    }
    bound_rows(&path, ROWS_MAX_BYTES);
    if let Ok(mut f) = crate::home_fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = std::io::Write::write_all(&mut f, format!("{v}\n").as_bytes());
    }
}

/// The rows file's bound: past it the older half is dropped before the next row.
pub const ROWS_MAX_BYTES: u64 = 4 * 1024 * 1024;

/// Keep `path` under `max` bytes: past it, keep its newer half (whole lines).
pub fn bound_rows(path: &Path, max: u64) {
    if std::fs::metadata(path).map(|m| m.len()).unwrap_or(0) <= max {
        return;
    }
    let Ok(text) = std::fs::read_to_string(path) else { return };
    // The newer half from the first line start past the middle. Found by bytes, so a middle
    // that falls inside a multi-byte character cannot panic; just past a '\n' is always a char
    // boundary, so `get` finds it.
    let cut = text.len() / 2;
    let newer = text
        .as_bytes()
        .iter()
        .skip(cut)
        .position(|&b| b == b'\n')
        .and_then(|i| cut.checked_add(i)?.checked_add(1))
        .and_then(|start| text.get(start..))
        .unwrap_or("");
    // Made whole: a copy beside it, renamed over it.
    let _ = crate::home_fs::write(path, newer);
}

/// The program `command` runs, file name only, never a `VAR=value` or an argument: the first
/// heavy-table program among its commands, else its first command's.
pub fn program_of(command: &str) -> Option<String> {
    let heavy = heavy_programs();
    let (mut first, mut listed) = (None, None);
    crate::host_load::for_each_command(command, &mut |argv: &[&str]| {
        let Some(name) =
            argv.iter().find(|w| !w.contains('=')).map(|w| w.rsplit('/').next().unwrap_or(w))
        else {
            return;
        };
        first.get_or_insert_with(|| name.to_owned());
        if listed.is_none() && heavy.contains(&name) {
            listed = Some(name.to_owned());
        }
    });
    listed.or(first)
}

/// A row for a command the conformance switch kept here (`CMUX_EXEC_ROUTE=local`).
pub fn write_forced_here(command: &str, via: &'static str) {
    write_row(&Row {
        class: heavy_class(command).unwrap_or("a command").to_owned(),
        size: None,
        ran: "here",
        via: Some(via),
        program: program_of(command),
        patch_bytes: None,
        out_bytes: None,
        fork: None,
        fork_ms: None,
        start_ms: None,
        first_output_ms: None,
        wall_ms: None,
        files: None,
        exit: None,
        fork_deleted: None,
        cause: Some(format!("{}=local", super::exec_router::FORCE_ENV)),
    });
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
    if super::auto_cloud_on()
        && let Some(row) = here_notice(command)
    {
        eprintln!("{row}");
    }
    run_here(command).await
}

/// The notice row for a known-heavy command that runs here on a machine too small for it (RFD
/// 0133's warning as RFD 0144's notice: no question, it runs). A cloud machine grows as it works.
fn here_notice(command: &str) -> Option<String> {
    use crate::heavy_precheck::{Place, Shape, notice, precheck};
    let cwd = std::env::current_dir().ok()?;
    let cwd_text = cwd.to_string_lossy();
    // A string match first: most commands are not known-heavy, and they read nothing.
    if !crate::heavy_precheck::is_known_heavy(command, Some(&cwd_text)) {
        return None;
    }
    let shape = Shape::here(&cwd)?;
    let warning = precheck(command, &shape, &Place { cwd: Some(&cwd_text), checkout_bytes: None })?;
    Some(notice(&warning, sub_fork::this_machine().is_some()))
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
            sizing_floored(
                &super::command_sampler::predict_from_file(
                    &super::command_sampler::file_path(),
                    &repo,
                    command,
                ),
                crate::heavy_precheck::memory_floor(command, Some(&repo)),
            )
        })
        .flatten();
    match &sized {
        Some(s) => eprintln!("{}", sizing_notice(class, s)),
        None => eprintln!("[run-vm] {class}: running on a fork of this machine"),
    }
    let mut stdout = tokio::io::stdout();
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let mut push = move |l: &str| {
        let _ = tx.send(l.to_owned());
    };
    let run = on_fork(
        machines,
        &link,
        machine,
        class,
        command,
        &cwd,
        std::env::var("PATH").ok(),
        sized.map(|s| s.size),
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
