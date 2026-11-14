//! The held copy (`git-seed-hold-v2`): a start-chat copy of a folder outside git that the
//! machine has nothing of opens the chat at its head, as a head-first seed does (cmuxterm-hq
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
use crate::link::sync_cli::fence;

/// The lease the hold asks for, and how often a running copy renews it.
const LEASE: Duration = Duration::from_secs(60);
const RENEW_EVERY: Duration = Duration::from_secs(10);
/// The child's one stdout line once it renews the hold itself.
const RENEWING: &str = "renewing";

/// A hold the machine took for this copy.
pub(super) struct Hold {
    pub(super) job: String,
    /// When it was asked for: the machine said it runs no earlier.
    asked: fence::Now,
}

/// `git.seed.hold` on `remote` for a chat at `subpath`. None (the plain copy goes instead)
/// for a folder in git, whose head would hold a partial `.git` a starting harness reads, for
/// a subpath no head can name, and when the machine has the folder whole already
/// (`seed.folder_not_empty`) or does not know holds. Any other refusal fails the push: the
/// folder is held or synced by another push, and a plain copy would race it. A request whose
/// answer is lost is sent once more with the same key, which the machine answers with the
/// same hold; one still unanswered fails the push too.
pub(super) fn take(
    machine: &Machine<'_>,
    local: &Path,
    remote: &str,
    subpath: &str,
) -> anyhow::Result<Option<Hold>> {
    if !machine.holds
        || sync_cli::in_git(local)
        || !cmux_tui_core::git_seed::head_subpath_is_literal(subpath)
    {
        return Ok(None);
    }
    let mut params = json!({"folder": remote, "key": super::unique(),
                            "lease_ms": LEASE.as_millis() as u64});
    if !subpath.is_empty()
        && let Some(map) = params.as_object_mut()
    {
        map.insert("subpath".into(), json!(subpath));
    }
    let mut when = fence::now();
    let mut asked = sync_cli::machine_call(machine.socket, "git.seed.hold", params.clone());
    if asked.as_ref().is_err_and(|error| !sync_cli::is_refusal(error)) {
        when = fence::now();
        asked = sync_cli::machine_call(machine.socket, "git.seed.hold", params);
    }
    match asked {
        Ok(answer) => Ok(answer
            .get("job")
            .and_then(Value::as_str)
            .map(|job| Hold { job: job.to_owned(), asked: when })),
        Err(error) if sync_cli::refusal_code(&error).is_some_and(plain_copy_goes) => Ok(None),
        Err(error) => Err(error),
    }
}

/// The hold refusals the plain copy may follow: the machine has the folder whole, or does not
/// serve holds on this connection.
fn plain_copy_goes(code: &str) -> bool {
    code == "seed.folder_not_empty" || !code.starts_with("seed.")
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
    let renewal = Renewal::start(socket, &hold.job, Some(hold.asked));
    let head = match sync_cli::push_head(socket, local, remote, subpath) {
        Ok(head) => head,
        Err(error) => {
            // The copy's own error is the answer; a hold whose end is lost runs out its lease.
            let _ = end(socket, &hold.job, false);
            return Err(error);
        }
    };
    // A head link that found nothing at its target is missing from the head: not marked.
    let marked = if head.head_links_short > 0 {
        Ok(false)
    } else {
        sync_cli::machine_call(socket, "git.seed.hold.head", json!({"job": hold.job}))
            .map(|answer| answer.get("head_ready").and_then(Value::as_bool) == Some(true))
    };
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
    child.detach("copy-rest renews the hold after this command exits (its own session)");
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
    // Started unheard: it may have slept past the lease since the parent last heard. Until
    // the machine says the hold runs it writes nothing, and the parent copies the rest itself.
    let renewal = Renewal::start(socket, job, None);
    if fence::confirm().is_err() {
        return 1;
    }
    println!("{RENEWING}");
    let whole = sync_cli::push(socket, local, remote);
    drop(renewal);
    match end(socket, job, whole.is_ok()) {
        Ok(()) if whole.is_ok() => 0,
        _ => 1,
    }
}

/// A thread that reads the hold's job every [`RENEW_EVERY`], which renews its lease,
/// until dropped, and the hold's [`fence`]: a write once the job no longer runs (its lease
/// ran out while this process slept) goes nowhere. Dropping it never waits: a read still in
/// flight ends on its own, so the chat's answer is never held up by a renewal.
struct Renewal {
    _stop: mpsc::Sender<()>,
    _fence: fence::Raised,
}

impl Renewal {
    fn start(socket: &Path, job: &str, heard: Option<fence::Now>) -> Self {
        let fence = fence::raise(socket, job, LEASE, heard);
        let (stop, stopped) = mpsc::channel::<()>();
        let (socket, job) = (socket.to_path_buf(), job.to_owned());
        // Detached: it ends once `stop` is dropped.
        let _ =
            std::thread::Builder::new().name("cmux-link-hold-renewal".into()).spawn(move || {
                while let Err(mpsc::RecvTimeoutError::Timeout) = stopped.recv_timeout(RENEW_EVERY) {
                    let asked = fence::now();
                    let answer =
                        sync_cli::machine_call(&socket, "git.seed.status", json!({"job": job}));
                    fence::heard(&job, asked, &answer);
                }
            });
        Self { _stop: stop, _fence: fence }
    }
}
