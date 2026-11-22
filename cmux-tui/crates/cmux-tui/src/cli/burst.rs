//! `cmux burst [--name MACHINE | --target machine:ID] [--environment E] [--out PATH]...
//! [--timeout SECONDS] [--json] -- COMMAND...`: runs COMMAND on a cmux Cloud VM against this folder,
//! as if it ran here (prototype; cmuxterm-hq docs/design/burst-to-cloud.md, "the Mac is one node of
//! a pool"; Leo, 2026-11-22: "IT'S THE INTERMINGLING AND BREAKING OF BARRIERS BETWEEN LOCAL AND
//! CLOUD.").
//!
//! Nothing new carries the folder: the start is `cmux cloud start-chat --from-folder .`
//! ([`super::cloud_start_chat::run`]), whose copy step (`cmux link start-chat copy`) projects the
//! folder first (link/sync_cli/project.rs, RFD 0007), so the machine sees every file at once and
//! reads a file's bytes from this Mac when the command first opens it. The command then runs in the
//! chat's folder there through `cloud exec` ([`super::cloud_start_chat::exec`]):
//!
//! 1. launched detached under a job folder of its own (`/tmp/cmux-burst/<id>`), its stdout and
//!    stderr to files there and its exit status last ([`launch_script`]);
//! 2. read back piece by piece, each read one short `cloud exec`, and written here as it comes
//!    ([`poll_script`], [`stream`]): stdout to stdout, stderr to stderr;
//! 3. each `--out PATH` (relative to this folder; none by default) packed there with `tar` and
//!    unpacked into this folder ([`plan_writeback`], [`write_back`]);
//! 4. this process exits with the remote command's own exit status ([`exit_status`]).
//!
//! Floor: run by hand only. Automatic overflow (a slow local build moved to the pool unasked) is
//! out of scope.

use std::io::Write;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value;

use super::cloud_start_chat::{self, GUEST_PRELUDE, Outcome, Runner, sections, shell_quote};
use super::{GlobalArgs, OutputMode, UsageError};

pub(super) const USAGE: &str = "usage: cmux burst [--name MACHINE | --target machine:ID] \
[--environment E] [--out PATH]... [--timeout SECONDS] -- COMMAND [ARG...]\n\n\
Runs COMMAND on a cmux Cloud VM in this folder, projected there (no copy), streams its output\n\
here and exits with its exit status. Each --out PATH (relative to this folder) the command\n\
wrote is brought back into this folder afterwards.\n";

/// The longest a burst runs by default; `--timeout` sets another.
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60 * 60);
/// The pause between two reads of the command's output.
const POLL_PAUSE: Duration = Duration::from_millis(700);
/// The most of one stream one read brings back, as raw bytes (base64 makes it a third larger).
const READ_PIECE: u64 = 192 * 1024;
/// The exit status when the command never reported one in time (as `timeout(1)` answers).
const TIMED_OUT: i32 = 124;
/// The exit status when the burst itself failed before or around the command (no machine, no
/// folder, a lost job): never one of the command's own.
const BURST_FAILED: i32 = 1;

/// `cmux burst`'s parsed words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Burst {
    /// The command's words, as given after `--`.
    pub command: Vec<String>,
    /// `--out` paths, relative to [`Burst::root`], as given.
    pub outs: Vec<String>,
    /// `--name M` / `--target machine:ID` / `--environment E`: passed to `cloud start-chat` as they
    /// are, so a burst picks its machine the way a Cloud chat does.
    pub start_words: Vec<String>,
    pub timeout: Duration,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run(Burst),
}

/// `Some(exit code)` when `args` is `burst …`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [verb, rest @ ..] = command_args.as_slice() else { return None };
    if verb != "burst" {
        return None;
    }
    match parse(rest) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            Some(0)
        }
        Ok(Parsed::Run(burst)) => Some(run(&global, &burst)),
        Err(error) => Some(super::app::failure(
            "usage.invalid",
            &format!("cmux: {}\n{USAGE}", error.0),
            global.output,
            2,
        )),
    }
}

/// The words after `burst`.
pub(super) fn parse(words: &[String]) -> Result<Parsed, UsageError> {
    let Some(split) = words.iter().position(|word| word == "--") else {
        if words.iter().any(|word| word == "-h" || word == "--help") {
            return Ok(Parsed::Help);
        }
        return Err(UsageError::new("burst needs `-- COMMAND`"));
    };
    let (flags, command) = (&words[..split], &words[split + 1..]);
    let mut outs = Vec::new();
    let mut start_words = Vec::new();
    let mut timeout = DEFAULT_TIMEOUT;
    let mut machine_named = false;
    let mut index = 0;
    while index < flags.len() {
        let word = flags[index].as_str();
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (word, None),
        };
        let mut value = || -> Result<String, UsageError> {
            if let Some(value) = inline.clone() {
                return Ok(value);
            }
            index += 1;
            flags
                .get(index)
                .cloned()
                .filter(|value| !value.is_empty())
                .ok_or_else(|| UsageError::new(format!("{flag} needs a value")))
        };
        match flag {
            "-h" | "--help" => return Ok(Parsed::Help),
            "--out" => outs.push(value()?),
            "--name" | "--target" => {
                if machine_named {
                    return Err(UsageError::new("give one of --name or --target"));
                }
                machine_named = true;
                start_words.extend([flag.to_owned(), value()?]);
            }
            "--environment" => start_words.extend([flag.to_owned(), value()?]),
            "--timeout" => {
                let text = value()?;
                let seconds =
                    text.parse::<u64>().ok().filter(|seconds| *seconds > 0).ok_or_else(|| {
                        UsageError::new(format!("--timeout {text:?}: whole seconds"))
                    })?;
                timeout = Duration::from_secs(seconds);
            }
            other => return Err(UsageError::new(format!("burst does not take {other}"))),
        }
        index += 1;
    }
    if command.is_empty() {
        return Err(UsageError::new("burst needs a command after `--`"));
    }
    Ok(Parsed::Run(Burst { command: command.to_vec(), outs, start_words, timeout }))
}

/// One `--out` path: what is packed on the machine (relative to the command's folder there) and
/// where it lands here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Writeback {
    pub relative: String,
    pub local: PathBuf,
}

/// The `--out` paths, checked and in the order they are brought back: each relative, inside the
/// folder (no `..`, never the folder itself), spelled once, and none inside another one already
/// brought back (`target` brings `target/debug` too).
pub(super) fn plan_writeback(root: &Path, outs: &[String]) -> Result<Vec<Writeback>, String> {
    let mut parts_of: Vec<Vec<String>> = Vec::new();
    for out in outs {
        let path = Path::new(out);
        if path.is_absolute() {
            return Err(format!("--out {out}: a path inside this folder, not an absolute one"));
        }
        let mut parts = Vec::new();
        for component in path.components() {
            match component {
                Component::CurDir => {}
                Component::Normal(part) => match part.to_str() {
                    Some(part) => parts.push(part.to_owned()),
                    None => return Err(format!("--out {out}: not UTF-8")),
                },
                _ => return Err(format!("--out {out}: no `..` (a path inside this folder)")),
            }
        }
        if parts.is_empty() {
            return Err(format!(
                "--out {out}: names the whole folder; name what the command makes"
            ));
        }
        parts_of.push(parts);
    }
    // Shorter first, so a path inside one already planned is dropped.
    parts_of.sort_by(|a, b| a.len().cmp(&b.len()).then_with(|| a.cmp(b)));
    let mut kept: Vec<Vec<String>> = Vec::new();
    for parts in parts_of {
        if !kept.iter().any(|outer| parts.starts_with(outer)) {
            kept.push(parts);
        }
    }
    Ok(kept
        .into_iter()
        .map(|parts| {
            let relative = parts.join("/");
            Writeback { local: root.join(&relative), relative }
        })
        .collect())
}

/// The exit status this process answers with for what the job's `exit` file held: the command's
/// own (0 to 255; a shell's 128+N for a signal), else [`BURST_FAILED`].
pub(super) fn exit_status(reported: &str) -> i32 {
    reported
        .trim()
        .parse::<i32>()
        .ok()
        .filter(|code| (0..=255).contains(code))
        .unwrap_or(BURST_FAILED)
}

/// The command's words as one line for the machine's shell: each word quoted, as `exec` would
/// pass them (`cmux burst -- sh -c 'a && b'` for a shell line).
pub(super) fn command_line(command: &[String]) -> String {
    command.iter().map(|word| shell_quote(word)).collect::<Vec<_>>().join(" ")
}

fn job_dir(job: &str) -> String {
    format!("/tmp/cmux-burst/{job}")
}

/// Starts `command` in `cwd` on the machine, detached from the exec that starts it (its own
/// session, its output to files), and answers `@@started` at once. The exit status goes to
/// `exit` only once the command ended, through a rename, so a read that sees it has all output.
pub(super) fn launch_script(job: &str, cwd: &str, command: &[String]) -> String {
    let dir = shell_quote(&job_dir(job));
    let cwd = shell_quote(cwd);
    let line = shell_quote(&command_line(command));
    format!(
        "{GUEST_PRELUDE}d={dir}; mkdir -p \"$d\" && cd {cwd} || exit 97; \
         setsid nohup sh -c 'sh -c \"$1\"; echo $? > \"$0/exit.part\"; mv \"$0/exit.part\" \"$0/exit\"' \
         \"$d\" {line} > \"$d/out\" 2> \"$d/err\" < /dev/null & echo @@started"
    )
}

/// One read of the job: its exit status when it has one (read first, so the output read after
/// it is whole), then up to [`READ_PIECE`] bytes of each stream from the given offsets, base64.
pub(super) fn poll_script(job: &str, out_at: u64, err_at: u64) -> String {
    let dir = shell_quote(&job_dir(job));
    let piece = |name: &str, at: u64| {
        format!(
            "echo @@{name}; tail -c +{} \"$d/{name}\" 2>/dev/null | head -c {READ_PIECE} | base64 | tr -d '\\n'; echo; ",
            at + 1
        )
    };
    format!(
        "d={dir}; [ -d \"$d\" ] || {{ echo @@lost; exit 0; }}; echo @@exit; cat \"$d/exit\" 2>/dev/null; echo; {}{}",
        piece("out", out_at),
        piece("err", err_at)
    )
}

/// Ends the job's command (a burst that ran out of time) and removes its folder.
fn stop_script(job: &str) -> String {
    let dir = shell_quote(&job_dir(job));
    format!("d={dir}; pkill -f -- \"$d\" 2>/dev/null; rm -rf \"$d\"; echo @@stopped")
}

/// Packs `relative` (in `cwd`) into the job folder and answers its size, or `@@missing`.
fn pack_script(job: &str, cwd: &str, relative: &str, index: usize) -> String {
    let dir = shell_quote(&job_dir(job));
    let cwd = shell_quote(cwd);
    let relative = shell_quote(relative);
    format!(
        "d={dir}; cd {cwd} || exit 97; [ -e {relative} ] || {{ echo @@missing; exit 0; }}; \
         tar czf \"$d/out-{index}.tgz\" -- {relative} && echo @@size && wc -c < \"$d/out-{index}.tgz\""
    )
}

fn piece_script(job: &str, index: usize, at: u64) -> String {
    let dir = shell_quote(&job_dir(job));
    format!(
        "d={dir}; echo @@piece; tail -c +{} \"$d/out-{index}.tgz\" | head -c {READ_PIECE} | base64 | tr -d '\\n'; echo",
        at + 1
    )
}

/// What a burst needs of a machine: one shell script run to its end, and the time between reads.
pub(super) trait Remote {
    /// Runs `script` on the machine and answers its stdout, or why it could not run.
    fn exec(&mut self, script: &str) -> Result<String, String>;
    fn pause(&mut self, duration: Duration);
    fn now(&mut self) -> Instant;
}

/// A [`Remote`] over the start's own runner: each script one `cloud exec` on `machine`.
struct OnMachine<'a> {
    runner: &'a mut dyn Runner,
    machine: String,
}

impl Remote for OnMachine<'_> {
    fn exec(&mut self, script: &str) -> Result<String, String> {
        cloud_start_chat::exec(self.runner, &self.machine, script).map_err(|error| {
            error.get("message").and_then(Value::as_str).unwrap_or("cloud exec failed").to_owned()
        })
    }

    fn pause(&mut self, duration: Duration) {
        self.runner.pause(duration);
    }

    fn now(&mut self) -> Instant {
        self.runner.now()
    }
}

fn decode(section: Option<&String>) -> Result<Vec<u8>, String> {
    let text = section.map(|text| text.trim()).unwrap_or_default();
    STANDARD.decode(text).map_err(|error| format!("the machine's output was not base64: {error}"))
}

/// Starts the job and copies its output to `out` and `err` until it ended: its exit status, or
/// [`TIMED_OUT`] once `until` passed (the job is stopped then).
pub(super) fn stream(
    remote: &mut dyn Remote,
    job: &str,
    cwd: &str,
    command: &[String],
    until: Instant,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, String> {
    let started = remote.exec(&launch_script(job, cwd, command))?;
    if !sections(&started).contains_key("started") {
        return Err(format!("the command did not start in {cwd} on the machine"));
    }
    let (mut out_at, mut err_at) = (0u64, 0u64);
    loop {
        let read = sections(&remote.exec(&poll_script(job, out_at, err_at))?);
        if read.contains_key("lost") {
            return Err("the job's folder on the machine is gone".to_owned());
        }
        let exit = read.get("exit").map(|text| text.trim().to_owned()).filter(|t| !t.is_empty());
        let (stdout, stderr) = (decode(read.get("out"))?, decode(read.get("err"))?);
        out.write_all(&stdout).and_then(|()| out.flush()).map_err(|e| e.to_string())?;
        err.write_all(&stderr).and_then(|()| err.flush()).map_err(|e| e.to_string())?;
        out_at += stdout.len() as u64;
        err_at += stderr.len() as u64;
        let drained = (stdout.len() as u64) < READ_PIECE && (stderr.len() as u64) < READ_PIECE;
        match exit {
            Some(code) if drained => return Ok(exit_status(&code)),
            Some(_) => continue,
            None if remote.now() >= until => {
                let _ = remote.exec(&stop_script(job));
                return Ok(TIMED_OUT);
            }
            None if drained => remote.pause(POLL_PAUSE),
            None => {}
        }
    }
}

/// Brings each planned path back: packed on the machine, read in pieces and unpacked here by
/// `unpack` (`tar xzf -` into `root`). A path the command did not make is said on `err` and
/// skipped; its absence never changes the exit status.
pub(super) fn write_back(
    remote: &mut dyn Remote,
    job: &str,
    cwd: &str,
    plan: &[Writeback],
    err: &mut dyn Write,
    unpack: &mut dyn FnMut(&[u8]) -> Result<(), String>,
) -> Result<Vec<String>, String> {
    let mut written = Vec::new();
    for (index, item) in plan.iter().enumerate() {
        let packed = sections(&remote.exec(&pack_script(job, cwd, &item.relative, index))?);
        if packed.contains_key("missing") {
            let _ = writeln!(
                err,
                "cmux burst: --out {}: the command made nothing there",
                item.relative
            );
            continue;
        }
        let size = packed
            .get("size")
            .and_then(|size| size.trim().parse::<u64>().ok())
            .ok_or_else(|| format!("--out {}: packing it on the machine failed", item.relative))?;
        let mut bytes = Vec::with_capacity(usize::try_from(size).unwrap_or(0));
        while (bytes.len() as u64) < size {
            let piece = decode(
                sections(&remote.exec(&piece_script(job, index, bytes.len() as u64))?).get("piece"),
            )?;
            if piece.is_empty() {
                return Err(format!("--out {}: its pack ended early", item.relative));
            }
            bytes.extend_from_slice(&piece);
        }
        unpack(&bytes)?;
        written.push(item.relative.clone());
    }
    Ok(written)
}

/// `tar xzf -` of `bytes` into `root`.
fn untar(root: &Path, bytes: &[u8]) -> Result<(), String> {
    let mut child = cmux_process::Command::new("tar")
        .args(["xzf", "-", "--no-same-owner", "-C"])
        .arg(root)
        .stdin(cmux_process::Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot run tar here: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(bytes).map_err(|error| format!("tar: {error}"))?;
    }
    let status = child.wait().map_err(|error| format!("tar: {error}"))?;
    if status.success() { Ok(()) } else { Err(format!("tar answered {status}")) }
}

fn job_id() -> String {
    uuid::Uuid::new_v4().simple().to_string().chars().take(16).collect()
}

fn failed(global: &GlobalArgs, code: &str, message: &str) -> i32 {
    super::app::failure(code, &format!("cmux burst: {message}"), global.output, BURST_FAILED)
}

/// Takes a machine with this folder projected on it, runs the command there and answers its
/// exit status.
pub(super) fn run(global: &GlobalArgs, burst: &Burst) -> i32 {
    let root = match std::env::current_dir().and_then(std::fs::canonicalize) {
        Ok(root) => root,
        Err(error) => return failed(global, "burst.no_folder", &format!("this folder: {error}")),
    };
    let plan = match plan_writeback(&root, &burst.outs) {
        Ok(plan) => plan,
        Err(message) => return failed(global, "usage.invalid", &message),
    };
    let began = Instant::now();
    let mut words =
        vec!["--from-folder".to_owned(), root.display().to_string(), "--no-focus".to_owned()];
    words.extend(burst.start_words.iter().cloned());
    let request = match cloud_start_chat::parse(&words, || Err("no prompt".to_owned())) {
        Ok(cloud_start_chat::Parsed::Run(request)) => *request,
        Ok(cloud_start_chat::Parsed::Help) => return failed(global, "usage.invalid", "bad start"),
        Err(error) => {
            if let Some(code) = cloud_start_chat::folder_refused(&error, global.output) {
                return code;
            }
            return failed(global, "usage.invalid", &error.0);
        }
    };
    let mut runner = cloud_start_chat::self_runner(global);
    eprintln!("cmux burst: projecting {} onto a Cloud machine", root.display());
    let answer = match cloud_start_chat::run(&mut runner, &request) {
        Outcome::Done(answer) => answer,
        Outcome::Failed { error, exit } => {
            return super::wire::print_local_error(&error, global.output, exit);
        }
    };
    let field = |key: &str| answer.get(key).and_then(Value::as_str).map(str::to_owned);
    let (Some(machine), Some(cwd)) = (field("machine_id"), field("cwd")) else {
        return failed(global, "burst.no_folder", "the machine did not say where the folder is");
    };
    let ready = began.elapsed();
    if global.output == OutputMode::Human {
        eprintln!("cmux burst: on {machine} in {cwd} ({} ms); running", ready.as_millis());
    }
    let job = job_id();
    let mut remote = OnMachine { runner: &mut runner, machine: machine.clone() };
    let until = remote.now() + burst.timeout;
    let (mut stdout, mut stderr) = (std::io::stdout(), std::io::stderr());
    let code =
        match stream(&mut remote, &job, &cwd, &burst.command, until, &mut stdout, &mut stderr) {
            Ok(code) => code,
            Err(message) => return failed(global, "burst.lost", &message),
        };
    if code == TIMED_OUT {
        eprintln!("cmux burst: stopped after {} s (--timeout)", burst.timeout.as_secs());
    }
    match write_back(&mut remote, &job, &cwd, &plan, &mut stderr, &mut |bytes| untar(&root, bytes))
    {
        Ok(written) if !written.is_empty() => {
            eprintln!("cmux burst: brought back {}", written.join(", "));
        }
        Ok(_) => {}
        Err(message) => {
            eprintln!("cmux burst: {message}");
            let _ = remote.exec(&format!("rm -rf {}", shell_quote(&job_dir(&job))));
            return if code == 0 { BURST_FAILED } else { code };
        }
    }
    let _ = remote.exec(&format!("rm -rf {}", shell_quote(&job_dir(&job))));
    code
}

#[cfg(test)]
#[path = "burst_tests.rs"]
mod tests;
