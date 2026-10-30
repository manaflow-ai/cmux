//! The forks of one process and of every process it starts, counted for
//! that tree alone (Linux). A tracer thread seizes the process with
//! `ptrace` (`PTRACE_SEIZE` with `PTRACE_O_TRACEFORK`, `TRACEVFORK` and
//! `TRACECLONE`, so each new process and thread of the tree is traced from
//! its start) and counts each `PTRACE_EVENT_FORK` and `PTRACE_EVENT_VFORK`
//! stop. The forking process stays stopped until the tracer has counted the
//! fork and resumes it, so when the process prints something after a fork,
//! that fork is already in the count: the count is exact, never a lower
//! bound. No other process on the host, and nothing else this test process
//! starts, changes it (the system PID counter, which the fork-count tests
//! read before, takes every process and thread of the host).
//!
//! A thread (`PTRACE_EVENT_CLONE`) is not a fork. An exec
//! (`PTRACE_EVENT_EXEC`) is counted apart, so a caller can prove the watch
//! is on the process it started.
//!
//! The tracer waits only for its own tracees (`__WNOTHREAD`), so the waits
//! of the test's other threads for their own children are untouched. It
//! reaps the watched process when that ends: the caller's own wait for it
//! then fails with `ECHILD`. Dropping the watch kills the watched process
//! (`SIGKILL`) and returns once every traced process ended, so it must drop
//! before anything that waits for the process (a `TestPty`), or a wait there
//! could take a stop the tracer never resumes.
//!
//! It needs the right to trace a child: Yama's `ptrace_scope` 0 or 1, the
//! default of every Linux the fleet and CI run.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::Duration;

/// What the watched tree did since the watch started.
#[derive(Clone, Copy, Default)]
pub(super) struct Counts {
    pub(super) forks: u32,
    pub(super) execs: u32,
}

#[derive(Default)]
struct Shared {
    forks: AtomicU32,
    execs: AtomicU32,
    /// Whether the watched process ended and was reaped. The tracer holds
    /// the lock while it reaps that process, and `drop` while it signals
    /// it, so a signal never reaches a reused pid.
    reaped: Mutex<bool>,
}

/// Counts the forks and execs of one process and its descendants from now on.
pub(super) struct ForkWatch {
    pid: libc::pid_t,
    shared: Arc<Shared>,
    tracer: Option<JoinHandle<()>>,
}

/// `ptrace(request, pid, 0, data)`; the result, or the error.
fn ptrace(request: libc::c_uint, pid: libc::pid_t, data: usize) -> std::io::Result<()> {
    // SAFETY: the requests used here take no address and an integer `data`
    // (options or a signal number), passed as the pointer-sized argument.
    let result = unsafe {
        let data = std::ptr::without_provenance_mut::<libc::c_void>(data);
        libc::ptrace(request, pid, std::ptr::null_mut::<libc::c_void>(), data)
    };
    if result < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
}

/// Resumes the stopped tracee `pid`, delivering `signal` (0: none). A tracee
/// killed while stopped (`ESRCH`) has nothing to resume.
fn resume(pid: libc::pid_t, signal: libc::c_int) {
    if let Err(error) = ptrace(libc::PTRACE_CONT, pid, signal as usize) {
        assert_eq!(error.raw_os_error(), Some(libc::ESRCH), "PTRACE_CONT {pid}: {error}");
    }
}

/// The tracer: seizes `pid`, reports whether that worked, then counts and
/// resumes every stop of the tree until no tracee is left.
fn trace(pid: libc::pid_t, shared: &Shared, seized: std::sync::mpsc::Sender<std::io::Result<()>>) {
    let options = libc::PTRACE_O_TRACEFORK
        | libc::PTRACE_O_TRACEVFORK
        | libc::PTRACE_O_TRACECLONE
        | libc::PTRACE_O_TRACEEXEC
        | libc::PTRACE_O_EXITKILL;
    let result = ptrace(libc::PTRACE_SEIZE, pid, options as usize);
    let failed = result.is_err();
    let _ = seized.send(result);
    if failed {
        return;
    }
    // `__WNOTHREAD`: only this thread's tracees, never another thread's
    // children.
    let flags = libc::__WALL | libc::__WNOTHREAD;
    loop {
        // SAFETY: zeroed siginfo_t is valid output storage.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // Which tracee has news, left in place (`WNOWAIT`) for the wait
        // below, which reads its full status.
        // SAFETY: `info` is valid output storage.
        let news = libc::WEXITED | libc::WSTOPPED | libc::WNOWAIT | flags;
        let found = unsafe { libc::waitid(libc::P_ALL, 0, &mut info, news) };
        if found < 0 {
            let error = std::io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                // No tracee is left.
                Some(libc::ECHILD) => return,
                _ => panic!("waitid for the traced tree: {error}"),
            }
        }
        // SAFETY: waitid filled `info` for a child, so `si_pid` is set.
        let stopped = unsafe { info.si_pid() };
        let mut status: libc::c_int = 0;
        let reaped =
            (stopped == pid).then(|| shared.reaped.lock().unwrap_or_else(PoisonError::into_inner));
        // SAFETY: `status` is valid output storage; `stopped` has news, so
        // this returns at once.
        let waited = unsafe { libc::waitpid(stopped, &mut status, flags) };
        if waited < 0 {
            let error = std::io::Error::last_os_error();
            assert_eq!(error.raw_os_error(), Some(libc::EINTR), "waitpid {stopped}: {error}");
            continue;
        }
        if !libc::WIFSTOPPED(status) {
            // A tracee ended, and is reaped now.
            if let Some(mut reaped) = reaped {
                *reaped = true;
            }
            continue;
        }
        drop(reaped);
        let event = (status >> 16) & 0xffff;
        let signal = match event {
            libc::PTRACE_EVENT_FORK | libc::PTRACE_EVENT_VFORK => {
                // Counted before the forking process runs on.
                shared.forks.fetch_add(1, Ordering::SeqCst);
                0
            }
            libc::PTRACE_EVENT_EXEC => {
                shared.execs.fetch_add(1, Ordering::SeqCst);
                0
            }
            // A thread; a new tracee's first stop or a group stop
            // (`PTRACE_EVENT_STOP`): nothing to deliver.
            libc::PTRACE_EVENT_CLONE | libc::PTRACE_EVENT_STOP => 0,
            // A signal on its way to the tracee: deliver it.
            _ => libc::WSTOPSIG(status),
        };
        resume(stopped, signal);
    }
}

impl ForkWatch {
    /// Starts counting the forks and execs of `pid`, a live child of this
    /// process that has not forked yet (a shell parked behind a gate).
    pub(super) fn new(pid: u32) -> Self {
        let pid = libc::pid_t::try_from(pid).expect("a pid fits pid_t");
        let shared = Arc::new(Shared::default());
        let (seized, result) = channel();
        let tracer = {
            let shared = shared.clone();
            // supervise-allow: the handle is kept and joined in `drop`, which re-raises the tracer's panic in the test.
            std::thread::spawn(move || trace(pid, &shared, seized))
        };
        let result =
            result.recv_timeout(Duration::from_secs(10)).expect("the tracer did not start");
        if let Err(error) = result {
            let _ = tracer.join();
            panic!(
                "PTRACE_SEIZE {pid}: {error}; the fork count traces the shell it starts, which \
                 needs Yama's ptrace_scope 0 or 1 (/proc/sys/kernel/yama/ptrace_scope)"
            );
        }
        Self { pid, shared, tracer: Some(tracer) }
    }

    /// The forks and execs of the tree so far, every one that happened
    /// before this call included.
    pub(super) fn counts(&self) -> Counts {
        Counts {
            forks: self.shared.forks.load(Ordering::SeqCst),
            execs: self.shared.execs.load(Ordering::SeqCst),
        }
    }
}

impl Drop for ForkWatch {
    fn drop(&mut self) {
        let reaped = self.shared.reaped.lock().unwrap_or_else(PoisonError::into_inner);
        if !*reaped {
            // SAFETY: signals the watched process, which is not reaped (the
            // tracer reaps it only under this lock), so the pid is still its.
            unsafe { libc::kill(self.pid, libc::SIGKILL) };
        }
        drop(reaped);
        if let Some(tracer) = self.tracer.take()
            && let Err(panic) = tracer.join()
            && !std::thread::panicking()
        {
            std::panic::resume_unwind(panic);
        }
    }
}

#[test]
fn counts_the_forks_of_its_tree_and_not_of_others() {
    use std::io::{BufRead, BufReader, Write};
    // On each line, the child forks a subshell, which forks one more (the
    // inner subshell is not its last command, so no shell runs it in place),
    // and then says so; it forks nothing before the first line, so the watch
    // is in place.
    let mut child = cmux_process::Command::new("/bin/sh")
        .args(["-c", "while read -r line; do ( ( : ); : ); echo forked; done"])
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::piped())
        .spawn()
        .unwrap();
    let watch = ForkWatch::new(child.id());
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    assert_eq!(watch.counts().forks, 0);
    for round in 1..=3 {
        // Forks of this process are not the tree's, and their waits are
        // this thread's own.
        for _ in 0..3 {
            assert!(cmux_process::Command::new("true").status().unwrap().success());
        }
        stdin.write_all(b"go\n").unwrap();
        let mut said = String::new();
        stdout.read_line(&mut said).unwrap();
        assert_eq!(said, "forked\n");
        assert_eq!(watch.counts().forks, 2 * round, "the subshell's own fork is the tree's");
    }
    assert_eq!(watch.counts().execs, 0, "the child execs nothing");
    drop(stdin);
    // The tracer reaps the child; the watch returns once it ended.
    drop(watch);
}
