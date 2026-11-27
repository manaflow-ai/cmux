//! Every hook answers its agent before the agent's own timeout: the class of
//! leo-workspace#10655 ("every request answered before its timeout") in the
//! hooks cmux installs. An agent that waits past a hook's `timeout` kills it
//! and shows its person "A hook didn't answer in time"; every cmux user runs
//! these hooks, so one that runs long under load shows that to all of them.
//!
//! The helper knows the timeout it was installed with
//! ([`cmux_tui_hooks::installed_hook_wait`]) and answers by [`answer_by`] of
//! it, measured from its start: each wait it makes (the journal handoff, the
//! inbox and session-context reads) takes the time left ([`within`]), and an
//! interval timer answers for whatever still runs at that point. Its answer is
//! the safe default, the one the installed command prints when the helper
//! fails: the empty object where the agent reads one, else nothing, exit 0.
//! A pre-tool hook still waiting on its repository barrier is the exception:
//! its installed command fails closed (`||exit 2`), so its deadline answer is
//! the barrier's own denial ([`hold_barrier`]), never a silent pass; once the
//! barrier clears ([`barrier_cleared`]) the deadline answer is `{}` again, a
//! no-decision that leaves the agent's own permission rules in charge. The
//! detached child (a separate process) keeps the event queued and delivers
//! it regardless.
//!
//! No thread: the timer is `SIGALRM` (`setitimer`), whose handler only makes
//! async-signal-safe calls (`write`, `_exit`). The helper spawns its detached
//! child (a fork and exec) after arming it, from a process with no thread of
//! its own; a timer is not inherited across fork. A main-thread answer and
//! the timer's take [`STATE`] in turn, so exactly one is written, whole.

use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::time::{Duration, Instant};

/// When the agent gets its answer at the latest, for a hook it waits
/// `timeout` for: a tenth of it before, at least 1.5 s and at most 5 s
/// (5 s -> 3.5 s, 3 s -> 1.5 s, 10 s -> 8.5 s, 90 s -> 85 s), and never less
/// than 0.5 s. The margin covers the shell and the exec before this process
/// can read a clock, and a loaded machine's scheduling.
pub(super) fn answer_by(timeout: Duration) -> Duration {
    let margin = (timeout / 10).clamp(Duration::from_millis(1500), Duration::from_secs(5));
    timeout.saturating_sub(margin).max(Duration::from_millis(500))
}

/// The armed deadline; none outside a provider-facing hook process (the
/// daemon and the tests call the same readers with their own bounds).
static DUE: OnceLock<Instant> = OnceLock::new();

const IDLE: u8 = 0;
const WRITING: u8 = 1;
const ANSWERED: u8 = 2;
/// Who answers: the main thread moves IDLE -> WRITING -> ANSWERED around its
/// one write, the timer IDLE -> ANSWERED around its own.
static STATE: AtomicU8 = AtomicU8::new(IDLE);
/// The timer fired while the main thread was writing: it exits once written.
static LATE: AtomicBool = AtomicBool::new(false);
/// Whether the safe default is the empty object (the agent reads one) or no
/// output (the installed command echoes it).
static EMPTY_OBJECT: AtomicBool = AtomicBool::new(false);

/// The pre-tool repository barrier's denial, set while it is held.
static DENIAL: OnceLock<Vec<u8>> = OnceLock::new();
/// The barrier is held: a deadline now answers with [`DENIAL`].
static BARRIER_HELD: AtomicBool = AtomicBool::new(false);

/// The pre-tool repository barrier is waiting: until [`barrier_cleared`], the
/// deadline answers with `denial` (one line), as the installed command's
/// `||exit 2` would, so a stalled barrier never lets the tool run unchecked.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn hold_barrier(denial: &str) {
    let _ = DENIAL.set(format!("{denial}\n").into_bytes());
    BARRIER_HELD.store(true, Ordering::SeqCst);
}

/// The repository barrier passed: a deadline from here gives the plain safe
/// default.
#[cfg_attr(not(unix), allow(dead_code))]
pub(super) fn barrier_cleared() {
    BARRIER_HELD.store(false, Ordering::SeqCst);
}

/// What the deadline writes: the barrier's denial while it is held, else `{}`
/// where the agent reads an object, else nothing. Async-signal-safe (atomic
/// loads and an initialized `OnceLock` read).
fn due_answer() -> Option<&'static [u8]> {
    if BARRIER_HELD.load(Ordering::SeqCst) {
        if let Some(denial) = DENIAL.get() {
            return Some(denial.as_slice());
        }
    }
    EMPTY_OBJECT.load(Ordering::SeqCst).then_some(b"{}\n".as_slice())
}

/// Arms the deadline for a hook the agent waits `timeout` for, whose safe
/// answer is `{}` when `empty_object`. Once per process; a second call is
/// ignored.
pub(super) fn arm(timeout: Duration, empty_object: bool) {
    let after = answer_by(timeout);
    if DUE.set(Instant::now() + after).is_err() {
        return;
    }
    EMPTY_OBJECT.store(empty_object, Ordering::SeqCst);
    timer::start(after);
}

/// `cap` from now, or the time left before the deadline when that is
/// sooner.
pub(super) fn within(cap: Duration) -> Instant {
    let now = Instant::now();
    let capped = now + cap;
    match DUE.get() {
        Some(due) => capped.min(*due).max(now),
        None => capped,
    }
}

/// Writes the main thread's one answer with `write`, unless the timer gave
/// the safe one already (then the agent has it and this process is ending).
/// Unarmed, it only writes.
pub(super) fn answer(write: impl FnOnce()) {
    if DUE.get().is_none() {
        write();
        return;
    }
    if STATE.compare_exchange(IDLE, WRITING, Ordering::SeqCst, Ordering::SeqCst).is_err() {
        return;
    }
    write();
    STATE.store(ANSWERED, Ordering::SeqCst);
    if LATE.load(Ordering::SeqCst) {
        // The deadline passed while this answer was written: it was the
        // answer, and nothing after it may hold the agent.
        timer::finish();
    }
}

/// The timer's side, in the signal handler or its thread.
fn on_due() {
    match STATE.compare_exchange(IDLE, ANSWERED, Ordering::SeqCst, Ordering::SeqCst) {
        Ok(_) => {
            if let Some(bytes) = due_answer() {
                timer::write_stdout(bytes);
            }
            timer::finish();
        }
        Err(WRITING) => LATE.store(true, Ordering::SeqCst),
        Err(_) => timer::finish(),
    }
}

#[cfg(unix)]
mod timer {
    use std::time::Duration;

    extern "C" fn handle(_signal: libc::c_int) {
        super::on_due();
    }

    pub(super) fn start(after: Duration) {
        // SAFETY: a zeroed sigaction with a plain handler, an empty mask and
        // SA_RESTART is valid for sigaction(2); the handler only touches
        // atomics and calls write(2) and _exit(2), which are async-signal-safe.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = handle as extern "C" fn(libc::c_int) as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut action.sa_mask);
            if libc::sigaction(libc::SIGALRM, &action, std::ptr::null_mut()) != 0 {
                return;
            }
            let value = libc::itimerval {
                it_interval: libc::timeval { tv_sec: 0, tv_usec: 0 },
                it_value: libc::timeval {
                    tv_sec: after.as_secs() as libc::time_t,
                    tv_usec: after.subsec_micros().max(1) as libc::suseconds_t,
                },
            };
            libc::setitimer(libc::ITIMER_REAL, &value, std::ptr::null_mut());
        }
    }

    pub(super) fn write_stdout(bytes: &[u8]) {
        // SAFETY: write(2) on stdout with a valid buffer; a short or failed
        // write only leaves the agent with less output.
        unsafe {
            libc::write(libc::STDOUT_FILENO, bytes.as_ptr().cast(), bytes.len());
        }
    }

    pub(super) fn finish() -> ! {
        // SAFETY: _exit(2) ends the process without running destructors or
        // atexit handlers, as a signal handler must.
        unsafe { libc::_exit(0) }
    }
}

#[cfg(not(unix))]
mod timer {
    use std::io::Write;
    use std::time::Duration;

    /// No fork here (the detached child is a fresh process), so a thread is
    /// the timer.
    pub(super) fn start(after: Duration) {
        let _ = std::thread::Builder::new().name("hook-deadline".into()).spawn(move || {
            std::thread::sleep(after);
            super::on_due();
        });
    }

    pub(super) fn write_stdout(bytes: &[u8]) {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(bytes);
        let _ = stdout.flush();
    }

    /// Ends nothing here: the answer is written and every later one is
    /// dropped (`answer` sees ANSWERED); the helper's own bounded waits end
    /// the process.
    pub(super) fn finish() {
        let _ = std::io::stdout().lock().flush();
    }
}

#[cfg(test)]
#[path = "answer_deadline_tests.rs"]
mod tests;
