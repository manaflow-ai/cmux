//! `cmux __app-watch`: the out-of-process watcher of one cmux NEXT app run
//! (crash-only recovery, issue #22844, plans/cmux-next/crash-classes.md).
//!
//! The app cannot always end itself. Its in-process crash deadline
//! (`CrashDeadline`, 10 s) is a thread of the same process: when a crash
//! reporter suspends every other thread and then blocks, that thread stops
//! too, and the app hangs at 0% CPU until Force Quit (NIGHTLY 2026-10-20). A
//! main thread that never returns to its run loop is the same class: nothing
//! inside the process can recover it safely. So a second, much simpler
//! process watches each app run and ends it in bounded time:
//!
//! - The app starts this mode at launch (`setsid`, so the watcher outlives
//!   the app) with the read end of a pipe as stdin. The app writes one byte
//!   per event; every write is one `write(2)` on a non-blocking descriptor,
//!   async-signal-safe for the crash paths:
//!   - `C`: a crash began (fatal signal handler, uncaught exception path);
//!   - `H`: the main thread has not returned to its run loop for the
//!     in-process hang threshold (2 s); `h`: it returned;
//!   - `Q`: a requested quit began: no relaunch after it. A hang is still
//!     ended (a quit asked for while the main thread hangs cannot start,
//!     and its own deadline arms only when it does).
//! - Crash grace: a crash that has not ended the process `--crash-grace`
//!   seconds after `C` (default 15, after the in-process deadline) is ended.
//! - Hang limit: a main thread that stays hung `--hang-limit` seconds after
//!   `H` (default 30; 0 turns it off) is ended.
//! - Ending a run: write `run.watch` (why, after how long) into the app's
//!   run-marker folder, so the next launch says what happened; sample the
//!   stacks when the system allows it (`/usr/bin/sample`, Debug and DEV
//!   builds; hardened builds refuse it and the in-process hang report already
//!   holds the main stack); then SIGABRT (the app's fatal handler records it,
//!   macOS writes a crash report with every thread); SIGKILL after 3 s if the
//!   process still runs (its threads may all be suspended). Never a process
//!   that a debugger traces.
//! - Relaunch: when the run ended in a crash (`C` seen) or by this watcher,
//!   and no quit began, the app executable is started again with this
//!   process's environment (the app's launch environment: a tagged build
//!   relaunches as the same tag), unless `--no-relaunch`, or the run was
//!   itself a restart that ended within the quick-crash window (60 s; no
//!   restart loop), or `RESTART_CAP` relaunches already happened within
//!   `RESTART_WINDOW` (counted in `watch.restarts` in the run-marker folder,
//!   per app build). The new run restores from the daemon and the store and
//!   starts its own watcher. A run that ended with no `C` (Force Quit,
//!   `kill -9`, jetsam) is not relaunched: someone may have ended it on
//!   purpose.
//!
//! The watcher is one thread blocked in `kevent` on three sources: the app's
//! exit (`EVFILT_PROC NOTE_EXIT`), the pipe, and the next deadline as the
//! wait's timeout. No polling, no wakeups while the app runs normally.

#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::client_log;

/// The private mode's name.
pub(crate) const MODE: &str = "__app-watch";
/// The first stdout line once the watcher waits; the app reads it to know
/// that this binary has the mode (an older `cmux` does not).
pub(crate) const READY_LINE: &str = "cmux-app-watch ready 1";

const DEFAULT_CRASH_GRACE: Duration = Duration::from_secs(15);
const DEFAULT_HANG_LIMIT: Duration = Duration::from_secs(30);
/// A restart that ends within this time of its launch is not relaunched
/// again (`LaunchRecovery.quickCrashWindow` in the app).
const QUICK_CRASH_WINDOW: Duration = Duration::from_secs(60);
/// At most this many relaunches in a row within `RESTART_WINDOW`: a run that
/// hangs or crashes a minute after every launch must not cycle forever.
const RESTART_CAP: u32 = 3;
const RESTART_WINDOW: Duration = Duration::from_secs(600);
/// `<count> <unix seconds of the first relaunch in the window>`, in the
/// run-marker folder.
const RESTARTS_FILE: &str = "watch.restarts";
const SAMPLE_LIMIT: Duration = Duration::from_secs(10);
const ABORT_GRACE: Duration = Duration::from_secs(3);
const KILL_GRACE: Duration = Duration::from_secs(2);

#[derive(Debug, PartialEq, Eq)]
struct Options {
    pid: i32,
    exe: Option<PathBuf>,
    marker_dir: Option<PathBuf>,
    crash_grace: Duration,
    hang_limit: Option<Duration>,
    launched_as_restart: bool,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut options = Options {
        pid: 0,
        exe: None,
        marker_dir: None,
        crash_grace: DEFAULT_CRASH_GRACE,
        hang_limit: Some(DEFAULT_HANG_LIMIT),
        launched_as_restart: false,
    };
    let mut relaunch = true;
    let mut index = 0;
    while index < args.len() {
        let flag = args[index].as_str();
        let mut value = || {
            index += 1;
            args.get(index).cloned().ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "--pid" => options.pid = value()?.parse().map_err(|_| "--pid is not a pid".to_string())?,
            "--exe" => options.exe = Some(PathBuf::from(value()?)),
            "--marker-dir" => options.marker_dir = Some(PathBuf::from(value()?)),
            "--crash-grace" => options.crash_grace = seconds(&value()?, flag)?,
            "--hang-limit" => {
                let limit = seconds(&value()?, flag)?;
                options.hang_limit = (!limit.is_zero()).then_some(limit);
            }
            "--launched-as-restart" => options.launched_as_restart = true,
            "--no-relaunch" => relaunch = false,
            other => return Err(format!("unknown argument {other}")),
        }
        index += 1;
    }
    if options.pid <= 1 {
        return Err("--pid is required".into());
    }
    if !relaunch {
        options.exe = None;
    }
    Ok(options)
}

fn seconds(raw: &str, flag: &str) -> Result<Duration, String> {
    raw.parse::<u64>().map(Duration::from_secs).map_err(|_| format!("{flag} takes whole seconds"))
}

/// Why this watcher ended the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Ending {
    /// A crash began and the process still ran after the crash grace.
    CrashStuck,
    /// The main thread stayed hung past the hang limit.
    Hang,
}

impl Ending {
    fn name(self) -> &'static str {
        match self {
            Ending::CrashStuck => "crash_stuck",
            Ending::Hang => "hang",
        }
    }
}

/// What the watcher knows about the run, fed by the app's event bytes.
#[derive(Debug, Default)]
struct Run {
    crash_began: Option<Instant>,
    hang_began: Option<Instant>,
    quitting: bool,
    ended: Option<Ending>,
}

impl Run {
    fn apply(&mut self, byte: u8, now: Instant) {
        match byte {
            b'C' => {
                self.crash_began.get_or_insert(now);
            }
            b'H' => {
                self.hang_began.get_or_insert(now);
            }
            b'h' => self.hang_began = None,
            b'Q' => self.quitting = true,
            _ => {}
        }
    }

    /// The next moment the watcher must act, and what it would do then.
    fn next_deadline(&self, options: &Options) -> Option<(Instant, Ending)> {
        if self.ended.is_some() {
            return None;
        }
        let crash = self.crash_began.map(|at| (at + options.crash_grace, Ending::CrashStuck));
        let hang = match (self.hang_began, options.hang_limit) {
            (Some(at), Some(limit)) => Some((at + limit, Ending::Hang)),
            _ => None,
        };
        match (crash, hang) {
            (Some(a), Some(b)) => Some(if a.0 <= b.0 { a } else { b }),
            (a, b) => a.or(b),
        }
    }

    /// Whether the run ended in a way the watcher relaunches.
    fn relaunches(&self, options: &Options, lived: Duration) -> bool {
        if options.exe.is_none() || self.quitting {
            return false;
        }
        if self.crash_began.is_none() && self.ended.is_none() {
            return false;
        }
        !(options.launched_as_restart && lived < QUICK_CRASH_WINDOW)
    }
}

/// Runs the mode; returns the exit code.
pub(crate) fn run(args: &[String]) -> i32 {
    let options = match parse(args) {
        Ok(options) => options,
        Err(error) => {
            client_log::stderr_log!("startup", "{MODE}: {error}");
            return 2;
        }
    };
    #[cfg(target_os = "macos")]
    {
        match sys::watch(&options) {
            Ok(()) => 0,
            Err(error) => {
                client_log::stderr_log!("startup", "{MODE}: {error}");
                1
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = options;
        client_log::stderr_log!("startup", "{MODE}: only macOS apps are watched");
        2
    }
}

/// The relaunch count for the next run, or `None` when the cap is reached.
/// `previous` is this run's `RESTARTS_ENV` value; `now` unix seconds.
fn next_restarts(previous: Option<&str>, now: u64) -> Option<(u32, u64)> {
    let parsed = previous.and_then(|value| {
        let mut words = value.split_whitespace();
        Some((words.next()?.parse::<u32>().ok()?, words.next()?.parse::<u64>().ok()?))
    });
    match parsed {
        Some((count, first)) if now.saturating_sub(first) < RESTART_WINDOW.as_secs() => {
            (count < RESTART_CAP).then_some((count + 1, first))
        }
        _ => Some((1, now)),
    }
}

/// `run.watch` in the app's run-marker folder: read by the next launch
/// (`AppRunMarker`), which removes it.
fn write_ending(dir: &Path, pid: i32, ending: Ending, after: Duration) -> std::io::Result<()> {
    let at = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let body = format!(
        "{{\"pid\":{pid},\"reason\":\"{}\",\"seconds\":{},\"at\":{at}}}\n",
        ending.name(),
        after.as_secs()
    );
    let temporary = dir.join(format!("run.watch.{pid}.tmp"));
    std::fs::write(&temporary, body)?;
    std::fs::rename(&temporary, dir.join("run.watch"))
}

#[cfg(target_os = "macos")]
mod sys {
    use std::io::{self, Write};
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    use super::{
        Ending, Options, Run, ABORT_GRACE, KILL_GRACE, MODE, READY_LINE, SAMPLE_LIMIT,
    };
    use crate::client_log;

    /// `PROC_FLAG_TRACED` in `<sys/proc_info.h>`.
    const PROC_FLAG_TRACED: u32 = 0x2;

    pub(super) fn watch(options: &Options) -> io::Result<()> {
        let started = Instant::now();
        let queue = Queue::new()?;
        // The app may already be gone (it crashed during launch): ESRCH.
        let app_alive = queue.watch_exit(options.pid)?;
        queue.watch_read(libc::STDIN_FILENO)?;
        {
            let mut stdout = io::stdout().lock();
            writeln!(stdout, "{READY_LINE}")?;
            stdout.flush()?;
        }
        // The app reads one line; nothing else is written to stdout.
        redirect_to_null(libc::STDOUT_FILENO);
        let mut run = Run::default();
        let mut pipe_open = true;
        let mut alive = app_alive;
        while alive {
            let deadline = run.next_deadline(options);
            let timeout = deadline.map(|(at, _)| at.saturating_duration_since(Instant::now()));
            match queue.next(timeout)? {
                Event::Exit => {
                    alive = false;
                    // A `C` written just before the exit may still sit in the pipe.
                    if pipe_open {
                        drain(&mut run);
                    }
                }
                Event::Readable => {
                    let mut bytes = [0_u8; 64];
                    // SAFETY: reads into a stack buffer of the given length.
                    let count = unsafe {
                        libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len())
                    };
                    if count > 0 {
                        let now = Instant::now();
                        for &byte in bytes.iter().take(count as usize) {
                            run.apply(byte, now);
                        }
                    } else if count == 0 && pipe_open {
                        // The app's write end closed: it exited, or exits now.
                        pipe_open = false;
                        queue.unwatch_read(libc::STDIN_FILENO);
                    }
                }
                Event::Timeout => {
                    let Some((at, ending)) = deadline else { continue };
                    if Instant::now() < at {
                        continue;
                    }
                    if is_traced(options.pid) {
                        client_log::stderr_log!(
                            "startup",
                            "{MODE}: pid {} is traced by a debugger; not ending it",
                            options.pid
                        );
                        // Stop acting on this episode; a new `C`/`H` cannot
                        // arrive for a crash, and a hang starts over.
                        run.crash_began = None;
                        run.hang_began = None;
                        continue;
                    }
                    let began = match ending {
                        Ending::CrashStuck => run.crash_began,
                        Ending::Hang => run.hang_began,
                    };
                    let after = began.map(|at| at.elapsed()).unwrap_or_default();
                    run.ended = Some(ending);
                    end_app(&queue, options, ending, after)?;
                    alive = false;
                }
            }
        }
        if run.relaunches(options, started.elapsed()) {
            if let Some(exe) = &options.exe {
                relaunch(exe, options.marker_dir.as_deref())?;
            }
        }
        Ok(())
    }

    /// Reads what the pipe still holds without waiting (the app is gone).
    fn drain(run: &mut Run) {
        // SAFETY: fcntl on our own stdin.
        unsafe {
            let flags = libc::fcntl(libc::STDIN_FILENO, libc::F_GETFL);
            if flags >= 0 {
                libc::fcntl(libc::STDIN_FILENO, libc::F_SETFL, flags | libc::O_NONBLOCK);
            }
        }
        let now = Instant::now();
        let mut bytes = [0_u8; 64];
        loop {
            // SAFETY: reads into a stack buffer of the given length.
            let count =
                unsafe { libc::read(libc::STDIN_FILENO, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count <= 0 {
                return;
            }
            for &byte in bytes.iter().take(count as usize) {
                run.apply(byte, now);
            }
        }
    }

    fn end_app(queue: &Queue, options: &Options, ending: Ending, after: Duration) -> io::Result<()> {
        let pid = options.pid;
        client_log::stderr_log!(
            "startup",
            "{MODE}: ending pid {pid}: {} for {} s",
            ending.name(),
            after.as_secs()
        );
        if let Some(dir) = &options.marker_dir {
            if let Err(error) = super::write_ending(dir, pid, ending, after) {
                client_log::stderr_log!("startup", "{MODE}: run.watch not written: {error}");
            }
            sample(queue, pid, &dir.join(format!("watch-{pid}-{}.sample.txt", ending.name())));
        }
        // SAFETY: signals the exact pid this watcher was started for.
        unsafe { libc::kill(pid, libc::SIGABRT) };
        if queue.wait_exit(pid, ABORT_GRACE)? {
            return Ok(());
        }
        // SAFETY: as above; its threads may all be suspended.
        unsafe { libc::kill(pid, libc::SIGKILL) };
        queue.wait_exit(pid, KILL_GRACE).map(|_| ())
    }

    /// Writes a stack sample of `pid` to `path` within `SAMPLE_LIMIT`. The
    /// system refuses it for hardened builds; then there is no sample.
    fn sample(queue: &Queue, pid: i32, path: &std::path::Path) {
        let child = Command::new("/usr/bin/sample")
            .arg(pid.to_string())
            .arg("1")
            .arg("-mayDie")
            .arg("-file")
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = child else { return };
        let Ok(child_pid) = i32::try_from(child.id()) else { return };
        let exited = queue.wait_exit(child_pid, SAMPLE_LIMIT).unwrap_or(false);
        if !exited {
            let _ = child.kill();
        }
        let _ = child.wait();
    }

    /// Starts the app executable again with this process's environment, and
    /// records the relaunch count; none once the cap is reached.
    fn relaunch(exe: &std::path::Path, marker_dir: Option<&std::path::Path>) -> io::Result<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let file = marker_dir.map(|dir| dir.join(super::RESTARTS_FILE));
        let previous = file.as_ref().and_then(|file| std::fs::read_to_string(file).ok());
        let Some((count, first)) = super::next_restarts(previous.as_deref(), now) else {
            client_log::stderr_log!(
                "startup",
                "{MODE}: not relaunching: {} relaunches within {} s",
                super::RESTART_CAP,
                super::RESTART_WINDOW.as_secs()
            );
            return Ok(());
        };
        if let Some(file) = &file {
            if let Err(error) = std::fs::write(file, format!("{count} {first}\n")) {
                client_log::stderr_log!("startup", "{MODE}: {} not written: {error}", super::RESTARTS_FILE);
            }
        }
        let mut command = Command::new(exe);
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        // SAFETY: setsid is async-signal-safe; the new app leads its own
        // session, as a launch from the Finder does.
        unsafe {
            command.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        let child = command.spawn()?;
        client_log::stderr_log!("startup", "{MODE}: relaunched as pid {}", child.id());
        // Not waited for: the new app outlives this process (launchd reaps it).
        drop(child);
        Ok(())
    }

    fn redirect_to_null(fd: libc::c_int) {
        // SAFETY: opens /dev/null and moves it over `fd`; both are owned here.
        unsafe {
            let null = libc::open(c"/dev/null".as_ptr(), libc::O_WRONLY | libc::O_CLOEXEC);
            if null >= 0 {
                libc::dup2(null, fd);
                libc::close(null);
            }
        }
    }

    fn is_traced(pid: i32) -> bool {
        // SAFETY: zeroed POD filled by proc_pidinfo; the size passed matches.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = size_of::<libc::proc_bsdinfo>() as libc::c_int;
        // SAFETY: valid pointer and length for the duration of the call.
        let written = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, std::ptr::addr_of_mut!(info).cast(), size)
        };
        written == size && info.pbi_flags & PROC_FLAG_TRACED != 0
    }

    enum Event {
        Exit,
        Readable,
        Timeout,
    }

    /// One kqueue: the app's exit, the event pipe, and short-lived waits.
    struct Queue {
        fd: libc::c_int,
    }

    impl Drop for Queue {
        fn drop(&mut self) {
            // SAFETY: the descriptor is owned by this value.
            unsafe { libc::close(self.fd) };
        }
    }

    impl Queue {
        fn new() -> io::Result<Self> {
            // SAFETY: kqueue has no preconditions.
            let fd = unsafe { libc::kqueue() };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self { fd })
        }

        fn change(&self, ident: usize, filter: i16, flags: u16, fflags: u32) -> io::Result<()> {
            // SAFETY: a zeroed kevent is valid; the fields set below define it.
            let mut change: libc::kevent = unsafe { std::mem::zeroed() };
            change.ident = ident;
            change.filter = filter;
            change.flags = flags;
            change.fflags = fflags;
            change.udata = std::ptr::null_mut();
            // SAFETY: one change, no event list.
            let result = unsafe {
                libc::kevent(self.fd, &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
            };
            if result < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }

        /// Watches `pid`'s exit; false when it is already gone.
        fn watch_exit(&self, pid: i32) -> io::Result<bool> {
            match self.change(pid as usize, libc::EVFILT_PROC, libc::EV_ADD | libc::EV_ONESHOT, libc::NOTE_EXIT) {
                Ok(()) => Ok(true),
                Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(false),
                Err(error) => Err(error),
            }
        }

        fn watch_read(&self, fd: libc::c_int) -> io::Result<()> {
            self.change(fd as usize, libc::EVFILT_READ, libc::EV_ADD, 0)
        }

        fn unwatch_read(&self, fd: libc::c_int) {
            let _ = self.change(fd as usize, libc::EVFILT_READ, libc::EV_DELETE, 0);
        }

        fn next(&self, timeout: Option<Duration>) -> io::Result<Event> {
            let spec = timeout.map(|t| libc::timespec {
                tv_sec: t.as_secs() as libc::time_t,
                tv_nsec: t.subsec_nanos() as libc::c_long,
            });
            let spec_ptr = spec.as_ref().map_or(std::ptr::null(), |s| s as *const libc::timespec);
            loop {
                // SAFETY: a zeroed kevent is a valid output buffer.
                let mut event: libc::kevent = unsafe { std::mem::zeroed() };
                // SAFETY: one output event; the timespec outlives the call.
                let count = unsafe { libc::kevent(self.fd, std::ptr::null(), 0, &mut event, 1, spec_ptr) };
                if count < 0 {
                    let error = io::Error::last_os_error();
                    if error.raw_os_error() == Some(libc::EINTR) {
                        continue;
                    }
                    return Err(error);
                }
                if count == 0 {
                    return Ok(Event::Timeout);
                }
                return Ok(match event.filter {
                    libc::EVFILT_PROC => Event::Exit,
                    _ => Event::Readable,
                });
            }
        }

        /// Waits up to `limit` for `pid` to exit on a separate kqueue (the
        /// main queue's one-shot exit watch stays armed). True when it exited.
        fn wait_exit(&self, pid: i32, limit: Duration) -> io::Result<bool> {
            let waiter = Queue::new()?;
            if !waiter.watch_exit(pid)? {
                return Ok(true);
            }
            let deadline = Instant::now() + limit;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match waiter.next(Some(left))? {
                    Event::Exit => return Ok(true),
                    Event::Timeout => return Ok(false),
                    Event::Readable => continue,
                }
            }
        }
    }
}
