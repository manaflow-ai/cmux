//! `projfs mount` (mount, then serve in the foreground) and `projfs unmount`.

use std::io::Write;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::daemon::DaemonSource;
use super::git_settings;
use super::overlay::{self, Undone};
use super::state::{self, Paths, mount_at};
use super::{Failure, Opts, print_line};
use crate::cache::ChunkCache;
use crate::core::{Config, Core};
use crate::fuse::{self, MountConfig, Mounted, Unmount};
use crate::manifest::Manifest;

/// The most cache a mount keeps: 8 GiB, or a quarter of the free disk when that is less.
const CACHE_MAX: u64 = 8 << 30;
/// How often, at most, `stats.json` is rewritten while the counters change.
const STATS_EVERY: Duration = Duration::from_secs(1);
/// How long `unmount` waits for a serving helper to exit after asking it to.
const HELPER_EXIT_WAIT: Duration = Duration::from_secs(10);

/// What `projfs mount` was given.
#[derive(Debug, Clone)]
pub(super) struct MountArgs {
    pub mount: String,
    pub manifest: PathBuf,
    pub paths: Paths,
    pub at: PathBuf,
    pub socket: PathBuf,
}

impl MountArgs {
    pub(super) fn from_opts(opts: &Opts, default_socket: Option<PathBuf>) -> Result<Self, String> {
        opts.only(&["mount", "manifest", "at", "state", "socket"])?;
        let mount = opts.need("mount")?.to_owned();
        if !plain_id(&mount) {
            return Err("--mount must be 1 to 64 letters, digits, '.', '_' or '-'".into());
        }
        let paths = Paths::parse(Some(opts.need("at")?), opts.need("state")?)?;
        let at = paths.at.clone().ok_or("--at is required")?;
        let socket = match opts.get("socket") {
            Some(s) => PathBuf::from(s),
            None => default_socket_path(default_socket),
        };
        Ok(MountArgs { mount, manifest: PathBuf::from(opts.need("manifest")?), paths, at, socket })
    }
}

/// The plain form of a mount id the helper and the Mac agree on.
pub(crate) fn plain_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// `CMUX_TUI_SOCKET`, else the caller's resolution, else the Cloud session's socket by the
/// plain rule (`$XDG_RUNTIME_DIR`, `$TMPDIR` or `/tmp`, then `cmux-tui-UID/cloud.sock`).
fn default_socket_path(default_socket: Option<PathBuf>) -> PathBuf {
    if let Some(s) = std::env::var_os("CMUX_TUI_SOCKET").filter(|s| !s.is_empty()) {
        return PathBuf::from(s);
    }
    if let Some(s) = default_socket {
        return s;
    }
    let base = ["XDG_RUNTIME_DIR", "TMPDIR"]
        .iter()
        .find_map(|k| std::env::var_os(k).filter(|v| !v.is_empty()))
        .map_or_else(|| PathBuf::from("/tmp"), PathBuf::from);
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    base.join(format!("cmux-tui-{uid}")).join("cloud.sock")
}

fn ms(since: Instant) -> u64 {
    since.elapsed().as_millis() as u64
}

fn io(what: &str, path: &Path, e: &std::io::Error) -> Failure {
    Failure::new("io", format!("cannot {what} {}: {e}", path.display()))
}

/// Checks the host and the paths before anything is changed.
fn preflight(args: &MountArgs) -> Result<(), Failure> {
    let md = std::fs::metadata(&args.at).map_err(|e| io("use", &args.at, &e))?;
    if !md.is_dir() {
        return Err(Failure::new("bad_path", format!("{} is not a directory", args.at.display())));
    }
    if mount_at(&args.at).is_some() {
        return Err(Failure::new("busy", format!("{} is already a mountpoint", args.at.display())));
    }
    if mount_at(&args.paths.lower).is_some() || state::running_helper(&args.paths).is_some() {
        return Err(Failure::new(
            "busy",
            format!("{} is already served; unmount it first", args.paths.state.display()),
        ));
    }
    overlay::check_fuse()?;
    overlay::check_sudo()
}

/// `projfs mount`: mounts, prints the ready line, serves until told to stop, then unmounts.
pub(super) fn mount(args: &MountArgs, out: &mut dyn Write) -> Result<(), Failure> {
    let started = Instant::now();
    preflight(args)?;
    let bytes = std::fs::read(&args.manifest).map_err(|e| {
        Failure::new("bad_manifest", format!("cannot read {}: {e}", args.manifest.display()))
    })?;
    let manifest = Manifest::decode(&bytes)
        .map_err(|e| Failure::new("bad_manifest", format!("the manifest is not valid: {e}")))?;
    let (entries, total) = (manifest.len(), manifest.total_bytes());
    let t_manifest = ms(started);
    let p = &args.paths;
    for dir in [&p.state, &p.lower, &p.upper, &p.work, &p.cache] {
        std::fs::create_dir_all(dir).map_err(|e| io("create", dir, &e))?;
    }
    let cache = ChunkCache::open(&p.cache, cache_budget(&p.cache))
        .map_err(|e| io("open the cache in", &p.cache, &e))?;
    let source = Arc::new(DaemonSource::new(args.socket.clone(), args.mount.clone()));
    let core = Core::new(manifest, cache, source.clone(), Config::default());
    source.attach(Arc::downgrade(&core));

    let t = Instant::now();
    // SAFETY: getuid and getgid have no preconditions and cannot fail.
    let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
    let mounted = fuse::mount(core.clone(), &p.lower, &MountConfig::new(uid, gid))
        .map_err(|e| Failure::new("no_fuse", format!("the FUSE mount failed: {e}")))?;
    let t_lower = ms(t);
    let t = Instant::now();
    if let Err(failure) = overlay::mount_overlay(p, &args.at) {
        let _ = mounted.unmount();
        return Err(failure);
    }
    let t_overlay = ms(t);
    let stop = Stop::new();
    let signals = match Signals::install(stop.clone()) {
        Ok(s) => s,
        Err(e) => {
            let _ = overlay::unmount_overlay(p, &args.at);
            let _ = mounted.unmount();
            return Err(Failure::new("io", format!("cannot handle signals: {e}")));
        }
    };
    let _lock = match state::lock_helper(p) {
        Ok(Some(lock)) => lock,
        held_or_failed => {
            let _ = overlay::unmount_overlay(p, &args.at);
            let _ = mounted.unmount();
            return Err(match held_or_failed {
                Err(e) => io("lock", &p.pid_file(), &e),
                _ => Failure::new(
                    "busy",
                    format!("{} is already served; unmount it first", p.state.display()),
                ),
            });
        }
    };
    // Best effort, never a failure: `git status` must not rehash (and fault) the whole tree.
    let git = git_settings::ensure().word();
    print_line(
        out,
        &json!({
            "ok": true, "mount": args.mount, "at": args.at, "entries": entries, "bytes": total,
            "git": git, "ms": { "manifest": t_manifest, "lower": t_lower, "overlay": t_overlay, "total": ms(started) },
        }),
    );
    serve(args, &core, mounted, &stop);
    drop(signals);
    Ok(())
}

/// Serves until a signal or the end of the lower session, then unmounts both layers.
fn serve(args: &MountArgs, core: &Arc<Core>, mounted: Mounted, stop: &Arc<Stop>) {
    let ending = mounted.ending();
    let watcher_stop = stop.clone();
    let watcher = std::thread::Builder::new().name("projfs-session".into()).spawn(move || {
        // Ends when the session does; a stop from elsewhere lets it go on until the unmount
        // below ends the session too.
        while ending.wait(Duration::from_secs(3600)).is_none() {}
        watcher_stop.set("unmounted");
    });
    let stats_file = args.paths.stats_file();
    let mut written = None;
    let why = loop {
        let stats = core.stats();
        if written != Some(stats) {
            let _ = state::write_atomic(&stats_file, &state::stats_json(&args.mount, &stats));
            written = Some(stats);
        }
        if let Some(why) = stop.wait(STATS_EVERY) {
            break why;
        }
    };
    let overlay = overlay::unmount_overlay(&args.paths, &args.at).map_or("failed", Undone::word);
    let lower = match mounted.unmount() {
        Ok(Unmount::Ended) => "unmounted",
        Ok(Unmount::Busy(_)) => "detached",
        Err(_) => "failed",
    };
    let _ = state::write_atomic(&stats_file, &state::stats_json(&args.mount, &core.stats()));
    let _ = std::fs::remove_file(args.paths.pid_file());
    if lower == "unmounted"
        && let Ok(w) = watcher
    {
        let _ = w.join();
    }
    eprintln!("{}", json!({ "stopped": why, "overlay": overlay, "lower": lower }));
}

fn cache_budget(dir: &Path) -> u64 {
    let Some(c) = dir.to_str().and_then(|d| std::ffi::CString::new(d).ok()) else {
        return CACHE_MAX;
    };
    // SAFETY: `c` is NUL-terminated and lives across the call; `st` is written by the kernel.
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return CACHE_MAX;
    }
    // The field types differ between Linux targets (u64 here, u32 on some 32-bit ones).
    #[allow(clippy::useless_conversion)]
    let free = u64::from(st.f_bavail).saturating_mul(u64::from(st.f_frsize));
    CACHE_MAX.min(free / 4).max(64 << 20)
}

/// `projfs unmount`: asks a serving helper to stop, then unmounts what is left (idempotent).
pub(super) fn unmount(paths: &Paths) -> Result<Value, Failure> {
    let at = paths.at.clone().ok_or_else(|| Failure::new("usage", "--at is required"))?;
    let helper = match state::running_helper(paths) {
        Some(pid) if pid as u32 != std::process::id() => stop_helper(pid),
        Some(_) => "this_process",
        None => "not_running",
    };
    let overlay = overlay::unmount_overlay(paths, &at)?;
    let lower = overlay::unmount_lower(paths)?;
    Ok(json!({ "ok": true, "helper": helper, "overlay": overlay.word(), "lower": lower.word() }))
}

/// Sends SIGTERM to `pid` and waits (bounded, on a pidfd) for it to exit.
fn stop_helper(pid: i32) -> &'static str {
    // SAFETY: pidfd_open takes a pid and flags and returns a new descriptor or -1.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        return "not_running";
    }
    // SAFETY: the descriptor was just opened and is owned here only.
    let fd = unsafe { OwnedFd::from_raw_fd(fd as i32) };
    // SAFETY: plain kill of a pid we just opened a pidfd for.
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        return "not_running";
    }
    let mut pfd = libc::pollfd { fd: fd.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    // SAFETY: one valid pollfd for the duration of the call.
    let ready = unsafe { libc::poll(&mut pfd, 1, HELPER_EXIT_WAIT.as_millis() as i32) };
    if ready > 0 { "stopped" } else { "still_running" }
}

/// Why serving should end, once something said so.
pub(super) struct Stop {
    why: Mutex<Option<&'static str>>,
    changed: Condvar,
}

impl Stop {
    fn new() -> Arc<Stop> {
        Arc::new(Stop { why: Mutex::new(None), changed: Condvar::new() })
    }

    fn set(&self, why: &'static str) {
        let mut w = self.why.lock().unwrap_or_else(PoisonError::into_inner);
        w.get_or_insert(why);
        self.changed.notify_all();
    }

    /// The reason, waiting at most `timeout` for one.
    fn wait(&self, timeout: Duration) -> Option<&'static str> {
        let w = self.why.lock().unwrap_or_else(PoisonError::into_inner);
        let (w, _) = self
            .changed
            .wait_timeout_while(w, timeout, |w| w.is_none())
            .unwrap_or_else(PoisonError::into_inner);
        *w
    }
}

/// The write end of the self-pipe SIGTERM and SIGINT write to (-1 when none).
static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(_: libc::c_int) {
    let fd = SIGNAL_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        // SAFETY: write is async-signal-safe; one byte from a static buffer.
        unsafe { libc::write(fd, b"s".as_ptr().cast(), 1) };
    }
}

/// SIGTERM and SIGINT turned into a [`Stop`] by a thread reading a self-pipe.
struct Signals {
    write: OwnedFd,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Signals {
    fn install(stop: Arc<Stop>) -> std::io::Result<Signals> {
        let mut fds = [0; 2];
        // SAFETY: `fds` has room for the two descriptors pipe2 writes.
        if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: both descriptors were just created and are owned here only.
        let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        SIGNAL_PIPE.store(write.as_raw_fd(), Ordering::SeqCst);
        for sig in [libc::SIGTERM, libc::SIGINT] {
            // SAFETY: a plain handler that only calls write(2); the struct is zeroed first.
            unsafe {
                let mut sa: libc::sigaction = std::mem::zeroed();
                sa.sa_sigaction = on_signal as *const () as libc::sighandler_t;
                sa.sa_flags = libc::SA_RESTART;
                libc::sigemptyset(&mut sa.sa_mask);
                libc::sigaction(sig, &sa, std::ptr::null_mut());
            }
        }
        let thread =
            std::thread::Builder::new().name("projfs-signals".into()).spawn(move || {
                let mut byte = [0u8; 1];
                let mut f = std::fs::File::from(read);
                if std::io::Read::read(&mut f, &mut byte).is_ok_and(|n| n == 1) && byte[0] == b's' {
                    stop.set("signal");
                }
            })?;
        Ok(Signals { write, thread: Some(thread) })
    }
}

impl Drop for Signals {
    fn drop(&mut self) {
        SIGNAL_PIPE.store(-1, Ordering::SeqCst);
        // Wakes the reader without a stop; it ends and the pipe closes.
        // SAFETY: one byte to our own pipe's write end.
        unsafe { libc::write(self.write.as_raw_fd(), b"q".as_ptr().cast(), 1) };
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
