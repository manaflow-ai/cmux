//! A deadline that holds past the async boundary, for a runner that has one (the carrier fault drill's,
//! [`super::super::SelfRunner::until`]): a step's child process is killed at the deadline, by its own process group;
//! a `cloud exec`'s remote script gets what is left of the deadline, less the remote kill's grace and the exec's
//! dispatch, as its own limit, so it ends on the machine before the deadline too; an app request stops at it; and a
//! read of stdin stops waiting at it. Every step's group is recorded until it is gone, so the drill's exit kills
//! what a step thread still runs ([`kill_steps`]). Runners without a deadline never come here: their steps run
//! exactly as before.

use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::{Ran, shell_quote};

/// The exit code of a step the deadline ended (as coreutils `timeout`).
pub(in crate::cli::cloud_start_chat) const PAST_DEADLINE: i32 = 124;
/// What a step the deadline ended says.
const PAST_DEADLINE_SAID: &str = "--timeout ran out: the step was stopped";
/// The grace the remote `timeout` gives its script after TERM, before KILL.
// timeout: TERM-to-KILL grace inside the caller's own --timeout; it ends no request early.
const REMOTE_KILL_GRACE: Duration = Duration::from_secs(1);
/// How long a `cloud exec` may take from here to its script starting on the machine (the app's request, the
/// exec's own connect). The remote limit leaves it out, so a script that started that late still ends, KILL
/// included, by the deadline.
const REMOTE_DISPATCH_MARGIN: Duration = Duration::from_secs(2);

/// The app error a step answers when the deadline passed before it could start.
pub(in crate::cli::cloud_start_chat) fn past_deadline() -> Value {
    json!({"code": "carrier_fault.timeout", "message": PAST_DEADLINE_SAID})
}

/// The error object itself on stderr (not under `{"ok": false, "error": ...}`), as `step_result` reads a step's
/// error: its own code reaches the answer, never `step.failed` with the JSON as its message.
fn ran_past_deadline() -> Ran {
    Ran { code: PAST_DEADLINE, stdout: String::new(), stderr: past_deadline().to_string() }
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
    keep_children();
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
    let mut pipes: Vec<Pipe> =
        [child.stdout.take().map(Pipe::of), child.stderr.take().map(Pipe::of)]
            .into_iter()
            .flatten()
            .collect();
    // The output is read here, on this thread, while the step runs: no reader thread outlives the step. A pipe
    // ends once every process holding it is gone; until then each wait is at most one slice, so the step's exit
    // is seen even while a leftover of its group still holds a pipe.
    let mut exited = false;
    loop {
        if !exited && child.exited_within(Duration::ZERO).unwrap_or(false) {
            exited = true;
            // The step is done: what is left in its group is its own leftover, and goes now.
            end_group(&mut child);
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() || pipes.iter().all(|pipe| pipe.ended) {
            break;
        }
        read_ready(&mut pipes, left.min(EXIT_CHECK_SLICE));
    }
    if !exited {
        // Every pipe ended (the step closed them) or `until` came: unreaped either way.
        let left = until.saturating_duration_since(Instant::now());
        exited = child.exited_within(left).unwrap_or(false);
    }
    end_group(&mut child);
    // After the kill the leader is gone or going: this reap returns at once.
    let status = child.wait().ok().filter(|_| exited);
    let ended = pipes.iter().all(|pipe| pipe.ended);
    let mut text = pipes.into_iter().map(|pipe| String::from_utf8_lossy(&pipe.read).into_owned());
    let (stdout, stderr) = (text.next().unwrap_or_default(), text.next().unwrap_or_default());
    match status {
        // A pipe still held at `until` (a process that left the group) is not waited for.
        Some(status) if ended => Ran { code: status.code().unwrap_or(1), stdout, stderr },
        // Only a deadline that came is a timeout. A step whose exit could not be read before it (another reaper
        // took it) is that step's own failure, with what it printed: never "--timeout ran out" with time left.
        _ if Instant::now() < until => {
            let error = json!({
                "code": UNWAITED,
                "message": format!("the step ended but its exit could not be read: {stderr}"),
            });
            Ran { code: 1, stdout, stderr: error.to_string() }
        }
        _ => ran_past_deadline(),
    }
}

/// What a bounded step answers whose exit could not be read with its deadline still ahead.
const UNWAITED: &str = "step.unwaited";

/// Makes this process keep its children's exit until it reads it, once, before its first bounded step. A process
/// started with `SIGCHLD` ignored (inherited across exec from whatever ran the drill) has the system reap every
/// child at its exit: a step's exit can then never be read, and its group id is no longer proven its own.
/// `carrier tunnel` takes the default back the same way (`carrier::tunnel::reap_own_children`).
fn keep_children() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        if !cmux_tui_platform::ended_children::keep_their_ids() {
            let _ = crate::carrier::tunnel::reap_own_children();
        }
    });
}

/// How long one wait on a step's pipes lasts before the step's exit is checked again.
const EXIT_CHECK_SLICE: Duration = Duration::from_millis(50);

/// One of a step's output pipes, read on the step's own thread.
struct Pipe {
    fd: std::os::fd::OwnedFd,
    read: Vec<u8>,
    ended: bool,
}

impl Pipe {
    fn of(pipe: impl Into<std::os::fd::OwnedFd>) -> Self {
        Self { fd: pipe.into(), read: Vec::new(), ended: false }
    }
}

/// Waits at most `wait` for any open pipe of `pipes` to be readable, and reads what each readable one holds: one
/// read per readiness, which never blocks. A pipe at its end, or failed, is ended.
fn read_ready(pipes: &mut [Pipe], wait: Duration) {
    use std::os::fd::AsRawFd as _;
    let mut open: Vec<&mut Pipe> = pipes.iter_mut().filter(|pipe| !pipe.ended).collect();
    let mut polled: Vec<libc::pollfd> = open
        .iter()
        .map(|pipe| libc::pollfd { fd: pipe.fd.as_raw_fd(), events: libc::POLLIN, revents: 0 })
        .collect();
    let millis = libc::c_int::try_from(wait.as_millis()).unwrap_or(libc::c_int::MAX);
    let count = libc::nfds_t::try_from(polled.len()).unwrap_or(0);
    // SAFETY: `polled` holds `count` live pollfds for descriptors `pipes` owns.
    if unsafe { libc::poll(polled.as_mut_ptr(), count, millis) } <= 0 {
        return;
    }
    let mut buffer = [0u8; 16 * 1024];
    for (polled, pipe) in polled.iter().zip(open.iter_mut()) {
        if polled.revents == 0 {
            continue;
        }
        // SAFETY: a read into a live buffer of its own length from a descriptor `pipe` owns.
        let read =
            unsafe { libc::read(pipe.fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
        match usize::try_from(read) {
            Ok(0) => pipe.ended = true,
            Ok(read) => pipe.read.extend_from_slice(buffer.get(..read).unwrap_or(&buffer)),
            Err(_) if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted => {
            }
            Err(_) => pipe.ended = true,
        }
    }
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

/// All of `reader` (stdin), by `until`, read on this thread: past it the read stops waiting and is an error.
pub(in crate::cli::cloud_start_chat) fn read_by(
    reader: impl std::os::fd::AsFd,
    until: Instant,
) -> Result<String, String> {
    use std::os::fd::AsRawFd as _;
    let fd = reader.as_fd().as_raw_fd();
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 16 * 1024];
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err("--timeout ran out while the prompt was read from stdin".into());
        }
        let mut polled = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let millis = libc::c_int::try_from(left.as_millis()).unwrap_or(libc::c_int::MAX);
        // SAFETY: one live pollfd for a descriptor `reader` holds open.
        match unsafe { libc::poll(&mut polled, 1, millis) } {
            0 => continue,
            ready if ready < 0 => {
                let error = std::io::Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error.to_string());
            }
            _ => {}
        }
        // SAFETY: a read into a live buffer of its own length; after POLLIN it does not block.
        let read = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        match usize::try_from(read) {
            Ok(0) => return String::from_utf8(bytes).map_err(|error| error.to_string()),
            Ok(read) => bytes.extend_from_slice(buffer.get(..read).unwrap_or(&buffer)),
            Err(_) => {
                let error = std::io::Error::last_os_error();
                if error.kind() != std::io::ErrorKind::Interrupted {
                    return Err(error.to_string());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stdin that never ends (a pipe nobody closes) stops the prompt's read at the deadline; one that ends is read
    /// whole. Without the bound the drill waited on such a stdin past any `--timeout`.
    #[test]
    fn a_stdin_read_stops_at_the_deadline() {
        use std::io::Write as _;
        // A pipe nobody closes: its reader never sees an end.
        let (reader, writer) = std::io::pipe().unwrap();
        let began = Instant::now();
        assert!(read_by(&reader, began + Duration::from_millis(200)).is_err());
        assert!(began.elapsed() < Duration::from_secs(5), "{:?}", began.elapsed());
        // One that ends is read whole.
        let (reader, mut writer_two) = std::io::pipe().unwrap();
        writer_two.write_all(b"count").unwrap();
        drop(writer_two);
        let read = read_by(&reader, began + Duration::from_secs(5));
        assert_eq!(read, Ok("count".to_owned()));
        drop(writer);
    }

    /// A bounded step that answers at once answers its own output and exit, on every Unix the drill runs on (the
    /// production drill runs on macOS): never `--timeout ran out` with the deadline far off.
    #[cfg(unix)]
    #[test]
    fn a_bounded_step_that_answers_at_once_answers_its_output() {
        // Many short steps in a row: the window between a step's pipes ending (its exit event) and its zombie
        // (macOS posts `NOTE_EXIT` first) is short, so one step alone may miss it.
        let began = Instant::now();
        for round in 0..100 {
            let mut command = cmux_process::Command::new("sh");
            command.arg("-c").arg("echo hi; echo there >&2; exit 3");
            let ran = output_by(command, began + Duration::from_secs(60));
            assert_eq!(
                (ran.code, ran.stdout.as_str(), ran.stderr.as_str()),
                (3, "hi\n", "there\n"),
                "step {round}, after {:?}",
                began.elapsed()
            );
        }
        assert!(began.elapsed() < Duration::from_secs(30), "{:?}", began.elapsed());
    }

    /// The marker a re-run of this test binary reads to be the child that ignores `SIGCHLD`.
    #[cfg(unix)]
    const IGNORED_SIGCHLD_CHILD: &str = "CMUX_TEST_BOUNDED_IGNORED_SIGCHLD_CHILD";

    /// A drill started with `SIGCHLD` ignored (inherited across exec from whatever ran it) still answers a bounded
    /// step's own output: the system then reaps the step behind the runner's back, and a wait that cannot see its
    /// exit is not a deadline. Run in a child process of its own (this test binary again), so the ignored `SIGCHLD`
    /// touches no other test.
    #[cfg(unix)]
    #[test]
    fn a_bounded_step_under_an_ignored_sigchld_answers_its_output() {
        if std::env::var_os(IGNORED_SIGCHLD_CHILD).is_some() {
            // SAFETY: `signal` with SIG_IGN installs no handler code; this process is this one test.
            unsafe {
                libc::signal(libc::SIGCHLD, libc::SIG_IGN);
            }
            let mut command = cmux_process::Command::new("sh");
            command.arg("-c").arg("echo hi; exit 3");
            let began = Instant::now();
            let ran = output_by(command, began + Duration::from_secs(30));
            assert_eq!((ran.code, ran.stdout.as_str()), (3, "hi\n"), "{}", ran.stderr);
            assert!(began.elapsed() < Duration::from_secs(10), "{:?}", began.elapsed());
            return;
        }
        let output = cmux_process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "cli::cloud_start_chat::internal::bounded::tests::a_bounded_step_under_an_ignored_sigchld_answers_its_output",
                "--nocapture",
            ])
            .env(IGNORED_SIGCHLD_CHILD, "1")
            .output()
            .unwrap();
        let said = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success(),
            "the child with SIGCHLD ignored failed: {}: {said}",
            output.status
        );
        // A name that matched no test would pass with 0 run.
        assert!(said.contains("1 passed"), "the child ran no test: {said}");
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
