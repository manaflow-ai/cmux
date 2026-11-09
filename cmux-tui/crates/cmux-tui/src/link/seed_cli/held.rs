//! The held copy (`git-seed-hold-v1`): a start-chat copy of a folder the machine has
//! nothing of opens the chat at its head, as a head-first seed does (cmuxterm-hq
//! goals/cloud-no-network-wait.md, step 6).
//!
//! The push takes a hold on the machine folder (`git.seed.hold`: the machine holds the
//! folder's sync barrier, so no tool runs on it yet), sends the head
//! ([`sync_cli::push_head`]: the root's files, the harness folders and the chat's folders)
//! and asks the machine to mark it (`git.seed.hold.head`). Marked, it starts a detached
//! `cmux link seed copy-rest` of itself that sends the rest of the folder and ends the hold
//! (`git.seed.hold.end`), and answers `filling` with the hold's job, as a seed at its head
//! does; a later `--since-last` waits for that job ([`super::settle_fill`]). A head the
//! machine will not mark (its harness settings run a command at start) is copied whole
//! here before the push answers, under the same hold.
//!
//! The hold lives on a lease the machine drops as failed: every `git.seed.status` of the
//! job renews it ([`Renewal`]), so a copy whose Mac went away leaves the folder failed,
//! never a partial folder that reads ready. A machine that refuses the hold (an older
//! build, a folder that is not new) gets the plain copy.

use std::io::{BufRead as _, BufReader};
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::{Value, json};

use super::{Machine, Pushed, SeedError, copied, sync_cli};

/// The lease the hold asks for, and how often a running copy renews it.
const LEASE: Duration = Duration::from_secs(60);
const RENEW_EVERY: Duration = Duration::from_secs(10);
/// The child's one stdout line once it renews the hold itself.
const RENEWING: &str = "renewing";

/// A hold the machine took for this copy.
pub(super) struct Hold {
    pub(super) job: String,
}

/// `git.seed.hold` on `remote` for a chat at `subpath`; None when the machine refuses it
/// (the plain copy goes instead).
pub(super) fn take(machine: &Machine<'_>, remote: &str, subpath: &str) -> Option<Hold> {
    if !machine.holds {
        return None;
    }
    let mut params = json!({"folder": remote, "key": super::unique(),
                            "lease_ms": LEASE.as_millis() as u64});
    if !subpath.is_empty() {
        params["subpath"] = json!(subpath);
    }
    let answer = sync_cli::machine_call(machine.socket, "git.seed.hold", params).ok()?;
    let job = answer.get("job").and_then(Value::as_str)?.to_owned();
    Some(Hold { job })
}

/// The held copy of `local` to `remote` (module docs).
pub(super) fn copy(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    subpath: &str,
    hold: Hold,
    fallback: Option<SeedError>,
) -> anyhow::Result<Pushed> {
    let socket = machine.socket;
    let renewal = Renewal::start(socket, &hold.job);
    let head = match sync_cli::push_head(socket, local, remote, subpath) {
        Ok(head) => head,
        Err(error) => {
            // The copy's own error is the answer; a hold whose end is lost runs out its lease.
            let _ = end(socket, &hold.job, false);
            return Err(error);
        }
    };
    let marked = sync_cli::machine_call(socket, "git.seed.hold.head", json!({"job": hold.job}))
        .map(|answer| answer.get("head_ready").and_then(Value::as_bool) == Some(true));
    let marked = match marked {
        Ok(marked) => marked,
        Err(error) => {
            // The copy's own error is the answer; a hold whose end is lost runs out its lease.
            let _ = end(socket, &hold.job, false);
            return Err(error);
        }
    };
    if marked && rest_in_the_background(socket, local, remote, &hold.job) {
        drop(renewal);
        return Ok(copied(machine, local, remote, &head, fallback, Some(&hold.job)));
    }
    // Copied whole before the answer: the head was not marked, or the child did not start.
    let whole = sync_cli::push(socket, local, remote);
    drop(renewal);
    let ended = end(socket, &hold.job, whole.is_ok());
    let whole = whole?;
    ended?;
    Ok(copied(machine, local, remote, &whole, fallback, None))
}

/// `git.seed.hold.end`: the folder reads ready (`ok`) or is left failed.
fn end(socket: &Path, job: &str, ok: bool) -> anyhow::Result<()> {
    sync_cli::machine_call(socket, "git.seed.hold.end", json!({"job": job, "ok": ok})).map(drop)
}

/// Starts `cmux link seed copy-rest` of this program, in its own session (it outlives
/// this process), and waits for its one line: it renews the hold itself from then on.
/// False when it did not start or ended before it said so.
fn rest_in_the_background(socket: &Path, local: &Path, remote: &str, job: &str) -> bool {
    let Ok(program) = std::env::current_exe() else { return false };
    let mut child = cmux_process::Command::new(program);
    child
        .args(["link", "seed", "copy-rest", "--socket"])
        .arg(socket)
        .arg("--job")
        .arg(job)
        .arg(local)
        .arg(remote)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        // No one reads this process's stderr once it answers.
        .stderr(cmux_process::Stdio::null())
        .new_session();
    let Ok(mut child) = child.spawn() else { return false };
    let Some(stdout) = child.stdout.take() else { return false };
    let mut line = String::new();
    // One blocking read: the child writes its line once it renews, or exits.
    match BufReader::new(stdout).read_line(&mut line) {
        Ok(_) if line.trim_end() == RENEWING => true,
        _ => {
            let _ = child.wait();
            false
        }
    }
}

/// `cmux link seed copy-rest --socket PATH --job JOB LOCAL REMOTE`: the rest of a held
/// copy past its head, then the hold's end. Exit 0 once the folder reads ready.
pub(super) fn copy_rest(socket: &Path, job: &str, local: &Path, remote: &str) -> i32 {
    let renewal = Renewal::start(socket, job);
    println!("{RENEWING}");
    let whole = sync_cli::push(socket, local, remote);
    drop(renewal);
    match end(socket, job, whole.is_ok()) {
        Ok(()) if whole.is_ok() => 0,
        _ => 1,
    }
}

/// A thread that reads the hold's job every [`RENEW_EVERY`], which renews its lease,
/// until dropped.
struct Renewal {
    stop: Option<mpsc::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Renewal {
    fn start(socket: &Path, job: &str) -> Self {
        let (stop, stopped) = mpsc::channel::<()>();
        let (socket, job) = (socket.to_path_buf(), job.to_owned());
        let thread = std::thread::Builder::new()
            .name("cmux-link-hold-renewal".into())
            .spawn(move || {
                while let Err(mpsc::RecvTimeoutError::Timeout) = stopped.recv_timeout(RENEW_EVERY) {
                    let _ = sync_cli::machine_call(&socket, "git.seed.status", json!({"job": job}));
                }
            })
            .ok();
        Self { stop: Some(stop), thread }
    }
}

impl Drop for Renewal {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
