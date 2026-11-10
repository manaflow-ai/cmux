//! A deadline that holds past the async boundary, for a runner that has one (the carrier fault drill's,
//! [`super::super::SelfRunner::until`]): a step's child process is killed at the deadline, by its own process group;
//! a `cloud exec`'s remote script gets what is left of the deadline as its own limit, so it is killed on the
//! machine there too; and a read of stdin stops waiting at the deadline. Runners without a deadline never come
//! here: their steps run exactly as before.

use std::io::Read;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{Ran, shell_quote};

/// The exit code of a step the deadline ended (as coreutils `timeout`).
pub(in crate::cli::cloud_start_chat) const PAST_DEADLINE: i32 = 124;
/// What a step the deadline ended says.
const PAST_DEADLINE_SAID: &str = "--timeout ran out: the step was stopped";
/// The grace the remote `timeout` gives its script after TERM, before KILL.
const REMOTE_KILL_AFTER_SECONDS: u64 = 1;

/// The app error a step answers when the deadline passed before it could start.
pub(in crate::cli::cloud_start_chat) fn past_deadline() -> Value {
    json!({"code": "carrier_fault.timeout", "message": PAST_DEADLINE_SAID})
}

fn ran_past_deadline() -> Ran {
    let error = json!({"ok": false, "error": past_deadline()});
    Ran { code: PAST_DEADLINE, stdout: String::new(), stderr: error.to_string() }
}

/// `command`'s output, by `until`: a step past it is not started, and one still running at it is killed with its
/// whole process group (it runs in a group of its own, so nothing it started outlives it) and answers
/// [`PAST_DEADLINE`]. A step that exits leaves nothing behind either: what is left in its group (a backgrounded
/// grandchild that may hold its output pipes open) is killed then, and its output is read by `until` at the latest.
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
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return Ran { code: 127, stdout: String::new(), stderr: error.to_string() },
    };
    let stdout = child.stdout.take().map(drain);
    let stderr = child.stderr.take().map(drain);
    let left = until.saturating_duration_since(Instant::now());
    let status = match child.wait_timeout(left) {
        Ok(Some(status)) => {
            // The step is done; anything still in its group is its own leftover.
            kill_group(&mut child);
            Some(status)
        }
        Ok(None) | Err(_) => {
            kill_group(&mut child);
            let _ = child.wait();
            None
        }
    };
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

/// Kills the child this runner spawned, and its process group (its own, `process_group(0)`). After the child exited
/// and was reaped, the group's id stays its own while any member is left, and with none left `killpg` finds nothing.
fn kill_group(child: &mut cmux_process::Child) {
    #[cfg(unix)]
    if let Ok(pid) = libc::pid_t::try_from(child.id())
        && pid > 0
    {
        // SAFETY: killpg on the group this runner made for its own child; no memory is touched.
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    }
    let _ = child.kill();
}

/// `script` for a `cloud exec` with `left` of the deadline: run under the machine's own `timeout`, so the remote
/// side stops there too. `None` when nothing is left.
pub(in crate::cli::cloud_start_chat) fn remote_script(
    script: &str,
    left: Duration,
) -> Option<String> {
    let seconds = left.as_secs();
    if seconds == 0 {
        return None;
    }
    Some(format!("timeout -k {REMOTE_KILL_AFTER_SECONDS} {seconds} sh -c {}", shell_quote(script)))
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

    /// A step that exits at once but leaves a backgrounded grandchild holding its stdout answers right away with
    /// its own output, and the grandchild is killed with the step's group: neither the pipe nor the leftover
    /// outlives the step. Without it, reading the output waited on the grandchild, past any deadline.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_step_that_exits_leaving_a_grandchild_on_its_pipe_answers_and_leaves_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let pid_file = dir.path().join("grandchild.pid");
        let mut command = cmux_process::Command::new("sh");
        command.arg("-c").arg(format!("sleep 600 & echo $! > '{}'; echo hi", pid_file.display()));
        let began = Instant::now();
        let ran = output_by(command, began + Duration::from_secs(5));
        let took = began.elapsed();
        assert_eq!((ran.code, ran.stdout.as_str()), (0, "hi\n"), "{}", ran.stderr);
        assert!(took < Duration::from_secs(3), "answered {took:?} after the step exited");
        let pid = std::fs::read_to_string(&pid_file).unwrap();
        let gone = (0..100).any(|_| {
            let stat =
                std::fs::read_to_string(format!("/proc/{}/stat", pid.trim())).unwrap_or_default();
            let running = stat.rsplit_once(") ").is_some_and(|(_, rest)| !rest.starts_with('Z'));
            if running {
                std::thread::sleep(Duration::from_millis(20));
            }
            !running
        });
        assert!(gone, "the step's grandchild outlived it");
    }

    /// Under a second left, no remote script is sent; otherwise the machine's `timeout` holds the whole seconds
    /// left, the script quoted whole.
    #[test]
    fn a_remote_script_holds_the_seconds_left() {
        assert_eq!(remote_script("true", Duration::from_millis(999)), None);
        assert_eq!(
            remote_script("echo a b", Duration::from_millis(5_900)).as_deref(),
            Some("timeout -k 1 5 sh -c 'echo a b'")
        );
    }
}
