//! Running a job as a process.
//!
//! The runner never runs a body itself: [`ProcessExecutor`] starts
//! `<cmux> automation _exec <automation> <run>` in its own process group, so
//! a runner restart (an update, a crash) does not stop runs in flight. That
//! process calls [`run_job`], which runs the body with the automation's
//! timeout, writes its output to the run's log and records how it ended.
//!
//! On Windows the store side works, but a body does not run yet: `start`
//! refuses and `run_job` records the run as failed with the reason (see
//! `sys`), so a run never runs without its timeout.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
#[cfg(unix)]
use std::sync::mpsc;
use std::time::Duration;

use crate::automation::Body;
use crate::runner::{ExecOutcome, Executor, Job, finish};
use crate::store::{Store, StoreError};
use crate::sys::private_file;

/// After a timeout's SIGTERM, how long the body has to exit before SIGKILL.
#[cfg(unix)]
const KILL_GRACE: Duration = Duration::from_secs(10);

/// Starts `program args… <automation> <run>` per job and reaps it.
#[cfg_attr(
    not(unix),
    expect(dead_code, reason = "Windows refuses to start a run, so it reads no field")
)]
pub struct ProcessExecutor {
    program: PathBuf,
    args: Vec<String>,
    store_root: PathBuf,
    children: Vec<Child>,
}

impl ProcessExecutor {
    /// `program args…` is the `_exec` entry point; the store root goes to it
    /// in `CMUX_AUTOMATIONS_DIR`.
    pub fn new(program: PathBuf, args: Vec<String>, store: &Store) -> ProcessExecutor {
        ProcessExecutor {
            program,
            args,
            store_root: store.root().to_path_buf(),
            children: Vec::new(),
        }
    }

    /// Collect finished children (no zombies in a long-running runner).
    pub fn reap(&mut self) {
        self.children.retain_mut(|c| matches!(c.try_wait(), Ok(None)));
    }

    /// Wait for the child with this pid (a foreground `run --wait`).
    pub fn wait(&mut self, pid: u32) -> Option<std::process::ExitStatus> {
        let index = self.children.iter().position(|c| c.id() == pid)?;
        let mut child = self.children.swap_remove(index);
        child.wait().ok()
    }
}

impl Executor for ProcessExecutor {
    #[cfg(unix)]
    fn start(&mut self, job: &Job) -> Result<u32, String> {
        use std::os::unix::process::CommandExt;
        let child = Command::new(&self.program)
            .args(&self.args)
            .arg(&job.automation)
            .arg(&job.run)
            .env("CMUX_AUTOMATIONS_DIR", &self.store_root)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .map_err(|e| e.to_string())?;
        let pid = child.id();
        self.children.push(child);
        Ok(pid)
    }

    /// Refused: the run is recorded as failed with the reason.
    #[cfg(windows)]
    fn start(&mut self, _job: &Job) -> Result<u32, String> {
        Err(crate::sys::UNSUPPORTED_ON_WINDOWS.into())
    }

    fn is_alive(&self, pid: u32) -> bool {
        pid_alive(pid)
    }
}

/// Whether a process with this id exists.
pub fn pid_alive(pid: u32) -> bool {
    crate::sys::pid_alive(pid)
}

/// The acpmux to run prompt bodies with: `$CMUX_AUTOMATION_ACPMUX`, else the
/// one next to this executable, else `acpmux` on `PATH`.
fn acpmux() -> PathBuf {
    if let Some(p) = std::env::var_os("CMUX_AUTOMATION_ACPMUX").filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(sibling) = exe.parent().map(|d| d.join("acpmux"))
        && sibling.exists()
    {
        return sibling;
    }
    PathBuf::from("acpmux")
}

fn expand_home(folder: &str) -> PathBuf {
    match (folder.strip_prefix("~/"), std::env::var_os("HOME")) {
        (Some(rest), Some(home)) => PathBuf::from(home).join(rest),
        _ => PathBuf::from(folder),
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Run one job in this process and record the outcome. The caller is the
/// `_exec` entry point.
pub fn run_job(store: &Store, automation: &str, run: &str) -> Result<ExecOutcome, StoreError> {
    let a = store.get(automation)?;
    let r = store.run(automation, run)?.ok_or_else(|| StoreError::NotFound(run.into()))?;
    let log_path = store.log_path(automation, run);
    if let Some(dir) = log_path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut log = private_file(OpenOptions::new().create(true).append(true)).open(&log_path)?;
    let late = if r.late_seconds > 120 {
        format!(", started {} min late", r.late_seconds / 60)
    } else {
        String::new()
    };
    let scheduled =
        r.scheduled_at.map(|t| format!(" scheduled for {t} (unix time)")).unwrap_or_default();
    let header = format!("[cmux automation \"{}\" run {}{scheduled}{late}]", a.name, r.id);
    let _ = writeln!(log, "{header}");

    let mut command = match &a.body {
        Body::Command { command, .. } => {
            let mut c = Command::new("/bin/sh");
            c.arg("-c").arg(command);
            c
        }
        Body::Prompt { prompt, model, .. } => {
            let prompt_path = log_path.with_extension("prompt.md");
            let text = format!(
                "{header}\nThis run was started by a cmux automation, not typed by the person now. Use {} as the idempotency key for anything you create.\n\n{prompt}\n",
                r.id
            );
            std::fs::write(&prompt_path, text)?;
            let mut c = Command::new(acpmux());
            c.arg("run")
                .arg("-n")
                .arg(format!("auto-{}-{}", id_head(&a.id, "auto_"), id_head(&r.id, "run_")))
                .arg("--timeout")
                .arg(a.timeout_seconds.to_string())
                .arg("--on-permission")
                .arg("fail")
                .arg("--prompt-file")
                .arg(&prompt_path);
            if let Some(model) = model {
                c.arg("-m").arg(model);
            }
            if let Some(folder) = a.body.folder() {
                c.arg("--cwd").arg(expand_home(folder));
            }
            c
        }
    };
    if let Some(folder) = a.body.folder() {
        command.current_dir(expand_home(folder));
    }
    command
        .env("CMUX_AUTOMATION_ID", &a.id)
        .env("CMUX_AUTOMATION_RUN_ID", &r.id)
        .env("CMUX_AUTOMATION_LATE_SECONDS", r.late_seconds.to_string())
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log.try_clone()?);
    if let Some(t) = r.scheduled_at {
        command.env("CMUX_AUTOMATION_SCHEDULED_AT", t.to_string());
    }
    let outcome = spawn_and_wait(command, Duration::from_secs(a.timeout_seconds));
    let _ = writeln!(log, "[cmux automation: {outcome:?}]");
    finish(store, automation, run, outcome.clone(), now())?;
    Ok(outcome)
}

/// Run `command` in its own process group and wait for it, at most `timeout`.
#[cfg(unix)]
fn spawn_and_wait(mut command: Command, timeout: Duration) -> ExecOutcome {
    use std::os::unix::process::CommandExt;
    match command.process_group(0).spawn() {
        Err(e) => ExecOutcome::Error(e.to_string()),
        Ok(child) => wait_with_timeout(child, timeout),
    }
}

/// Refused: without a job object the timeout could not stop the whole tree.
#[cfg(windows)]
fn spawn_and_wait(_command: Command, _timeout: Duration) -> ExecOutcome {
    ExecOutcome::Error(crate::sys::UNSUPPORTED_ON_WINDOWS.into())
}

/// Wait for `child`; at the deadline SIGTERM its process group, then SIGKILL.
#[cfg(unix)]
fn wait_with_timeout(mut child: Child, timeout: Duration) -> ExecOutcome {
    use std::os::unix::process::ExitStatusExt;
    let pgid = child.id() as libc::pid_t;
    let (tx, rx) = mpsc::channel();
    let waiter = std::thread::spawn(move || {
        let _ = tx.send(child.wait());
    });
    let status = match rx.recv_timeout(timeout) {
        Ok(status) => status,
        Err(_) => {
            // SAFETY: signals the process group this function started.
            unsafe { libc::kill(-pgid, libc::SIGTERM) };
            if rx.recv_timeout(KILL_GRACE).is_err() {
                unsafe { libc::kill(-pgid, libc::SIGKILL) };
                let _ = rx.recv();
            }
            let _ = waiter.join();
            return ExecOutcome::TimedOut;
        }
    };
    let _ = waiter.join();
    match status {
        Ok(s) => match (s.code(), s.signal()) {
            (Some(code), _) => ExecOutcome::Exited { code },
            (None, Some(signal)) => ExecOutcome::Signaled { signal },
            _ => ExecOutcome::Error("no exit status".into()),
        },
        Err(e) => ExecOutcome::Error(e.to_string()),
    }
}

/// The first 8 characters of `id` after `prefix` (`auto_` or `run_` and base32), for a short
/// session name; the whole id when it does not have that form.
fn id_head<'a>(id: &'a str, prefix: &str) -> &'a str {
    id.strip_prefix(prefix).and_then(|rest| rest.get(..8)).unwrap_or(id)
}

#[cfg(test)]
mod id_head_tests {
    use super::id_head;

    #[test]
    fn a_session_name_takes_8_characters_after_each_prefix() {
        assert_eq!(id_head("auto_abcdefgh234567abcdef", "auto_"), "abcdefgh");
        assert_eq!(id_head("run_234567abcdefghijklmn", "run_"), "234567ab");
        // An id of another form is used whole, never a panic.
        assert_eq!(id_head("auto_é", "auto_"), "auto_é");
        assert_eq!(id_head("other", "run_"), "other");
    }
}
