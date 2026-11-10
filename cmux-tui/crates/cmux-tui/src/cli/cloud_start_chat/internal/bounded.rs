//! A deadline that holds past the async boundary, for a runner that has one (the carrier fault drill's,
//! [`super::super::SelfRunner::until`]): a step's child process is killed at the deadline, by its own process group;
//! a `cloud exec`'s remote script gets what is left of the deadline, less the remote kill's grace and the exec's
//! dispatch, as its own limit, so it ends on the machine before the deadline too; an app request stops at it; and a
//! read of stdin stops waiting at it. Every step's group is recorded until it is gone, so the drill's exit kills
//! what a step thread still runs ([`kill_steps`]). Runners without a deadline never come here: their steps run
//! exactly as before.

use std::io::Read;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{Ran, shell_quote};

/// The exit code of a step the deadline ended (as coreutils `timeout`).
pub(in crate::cli::cloud_start_chat) const PAST_DEADLINE: i32 = 124;
/// What a step the deadline ended says.
const PAST_DEADLINE_SAID: &str = "--timeout ran out: the step was stopped";
/// The grace the remote `timeout` gives its script after TERM, before KILL.
const REMOTE_KILL_GRACE: Duration = Duration::from_secs(1);
/// How long a `cloud exec` may take from here to its script starting on the machine (the app's request, the
/// exec's own connect). The remote limit leaves it out, so a script that started that late still ends, KILL
/// included, by the deadline.
const REMOTE_DISPATCH_MARGIN: Duration = Duration::from_secs(2);

/// The app error a step answers when the deadline passed before it could start.
pub(in crate::cli::cloud_start_chat) fn past_deadline() -> Value {
    json!({"code": "carrier_fault.timeout", "message": PAST_DEADLINE_SAID})
}

fn ran_past_deadline() -> Ran {
    let error = json!({"ok": false, "error": past_deadline()});
    Ran { code: PAST_DEADLINE, stdout: String::new(), stderr: error.to_string() }
}

/// The process groups of the bounded steps still running (each step's leader is unreaped while its id is here, so
/// the id is still that step's group), and whether the drill is ending ([`kill_steps`]): then no step starts.
struct Steps {
    groups: Vec<u32>,
    closed: bool,
}

static STEPS: Mutex<Steps> = Mutex::new(Steps { groups: Vec::new(), closed: false });

fn steps() -> std::sync::MutexGuard<'static, Steps> {
    STEPS.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The drill's exit path, before it answers: kills the group of every bounded step a thread still runs (a send the
/// drill gave up on, say), since the process may exit before that thread's own kill. No step starts after it.
pub(in crate::cli::cloud_start_chat) fn kill_steps() {
    let mut steps = steps();
    steps.closed = true;
    for group in &steps.groups {
        kill_group_id(*group);
    }
}

/// `command`'s output, by `until`: a step past it is not started, and one still running at it is killed with its
/// whole process group (it runs in a group of its own, so nothing it started outlives it) and answers
/// [`PAST_DEADLINE`]. A step that exits leaves nothing behind either: what is left in its group (a backgrounded
/// grandchild that may hold its output pipes open) is killed then, and its output is read by `until` at the latest.
/// The group is killed before the step's leader is reaped, so the kill never reaches a reused id.
pub(in crate::cli::cloud_start_chat) fn output_by(
    mut command: cmux_process::Command,
    until: Instant,
) -> Ran {
    if Instant::now() >= until {
        return ran_past_deadline();
    }
    command
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped());
    #[cfg(unix)]
    command.process_group(0);
    // Started and recorded under one lock: the drill's exit kills it, or it never starts.
    let mut child = {
        let mut steps = steps();
        if steps.closed {
            return ran_past_deadline();
        }
        match command.spawn() {
            Ok(child) => {
                steps.groups.push(child.id());
                child
            }
            Err(error) => {
                return Ran { code: 127, stdout: String::new(), stderr: error.to_string() };
            }
        }
    };
    let stdout = child.stdout.take().map(drain);
    let stderr = child.stderr.take().map(drain);
    let left = until.saturating_duration_since(Instant::now());
    // Unreaped either way: exited (a zombie) or still running at `until`.
    let exited = child.exited_within(left).unwrap_or(false);
    end_group(&mut child);
    // After the kill the leader is gone or going: this reap returns at once.
    let status = child.wait().ok().filter(|_| exited);
    // Each pipe ends once the group is gone; a reader still waiting at `until` (a process that left the group and
    // holds the pipe) is not waited for.
    let collect = |reader: Option<std::sync::mpsc::Receiver<Vec<u8>>>| match reader {
        None => Some(Vec::new()),
        Some(reader) => reader.recv_timeout(until.saturating_duration_since(Instant::now())).ok(),
    };
    let (stdout, stderr) = (collect(stdout), collect(stderr));
    match (status, stdout, stderr) {
        (Some(status), Some(stdout), Some(stderr)) => Ran {
            code: status.code().unwrap_or(1),
            stdout: String::from_utf8_lossy(&stdout).into_owned(),
            stderr: String::from_utf8_lossy(&stderr).into_owned(),
        },
        _ => ran_past_deadline(),
    }
}

/// Reads a pipe to its end on a thread of its own, and sends what it read.
fn drain(mut pipe: impl Read + Send + 'static) -> std::sync::mpsc::Receiver<Vec<u8>> {
    let (done, read) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = pipe.read_to_end(&mut bytes);
        let _ = done.send(bytes);
    });
    read
}

/// Kills the group of `child` (its own, `process_group(0)`), leader included, and forgets it, under the registry's
/// lock, so the drill's exit path never kills a group after this. The caller has not reaped `child` yet.
fn end_group(child: &mut cmux_process::Child) {
    let id = child.id();
    let mut steps = steps();
    kill_group_id(id);
    let _ = child.kill();
    steps.groups.retain(|group| *group != id);
}

/// SIGKILL to process group `id`, a bounded step's own while its leader is unreaped.
fn kill_group_id(id: u32) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(id)
        && pid > 0
    {
        // SAFETY: killpg on a group this runner made for a child it has not reaped; no memory is touched.
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    }
    #[cfg(not(unix))]
    let _ = id;
}

/// `script` for a `cloud exec` with `left` of the deadline: run under the machine's own `timeout`, whose limit
/// leaves out the KILL grace after TERM and the exec's dispatch, so even a script that ignores TERM and started
/// late ends by the deadline. `None` when nothing is left after those.
pub(in crate::cli::cloud_start_chat) fn remote_script(
    script: &str,
    left: Duration,
) -> Option<String> {
    let seconds = left
        .checked_sub(REMOTE_KILL_GRACE)
        .and_then(|left| left.checked_sub(REMOTE_DISPATCH_MARGIN))?
        .as_secs();
    if seconds == 0 {
        return None;
    }
    let grace = REMOTE_KILL_GRACE.as_secs();
    Some(format!("timeout -k {grace} {seconds} sh -c {}", shell_quote(script)))
}

/// All of `reader` (stdin), by `until`: past it the read stops waiting and is an error. The thread that reads stays
/// blocked on a reader that never ends, and goes with the process.
pub(in crate::cli::cloud_start_chat) fn read_by(
    reader: impl Read + Send + 'static,
    until: Instant,
) -> Result<String, String> {
    let (done, read) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("carrier-drill-stdin".into())
        .spawn(move || {
            let mut reader = reader;
            let mut text = String::new();
            let _ = done.send(reader.read_to_string(&mut text).map(|_| text));
        })
        .map_err(|error| error.to_string())?;
    match read.recv_timeout(until.saturating_duration_since(Instant::now())) {
        Ok(read) => read.map_err(|error| error.to_string()),
        Err(_) => Err("--timeout ran out while the prompt was read from stdin".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stdin that never ends (a pipe nobody closes) stops the prompt's read at the deadline; one that ends is read
    /// whole. Without the bound the drill waited on such a stdin past any `--timeout`.
    #[test]
    fn a_stdin_read_stops_at_the_deadline() {
        struct Never;
        impl Read for Never {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                std::thread::sleep(Duration::from_secs(600));
                Ok(0)
            }
        }
        let began = Instant::now();
        assert!(read_by(Never, began + Duration::from_millis(200)).is_err());
        assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
        let read = read_by(std::io::Cursor::new(b"count".to_vec()), began + Duration::from_secs(5));
        assert_eq!(read, Ok("count".to_owned()));
    }

    /// Under a second left after the kill grace and the dispatch margin, no remote script is sent; otherwise the
    /// machine's `timeout` holds those whole seconds, the script quoted whole.
    #[test]
    fn a_remote_script_holds_the_seconds_left() {
        assert_eq!(remote_script("true", Duration::from_millis(3_999)), None);
        assert_eq!(
            remote_script("echo a b", Duration::from_millis(5_900)).as_deref(),
            Some("timeout -k 1 2 sh -c 'echo a b'")
        );
    }
}
