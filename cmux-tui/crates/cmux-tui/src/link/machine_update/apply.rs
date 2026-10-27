//! The machine side of `cmux link machine update` (cx-rppd.13):
//! `cmux-tui __machine-update-apply --sha256 HEX --install PATH --daemon-pid
//! PID --result PATH`, run once by the machine's own daemon in a detached
//! terminal, as the daemon's user, from the staged new build itself.
//!
//! It touches nothing until every check passes: it holds the folder's update
//! lock (one update at a time), its own executable has the pinned checksum,
//! `--install` is `$HOME/.cmux/bin/cmux-tui` and is the binary daemon
//! `--daemon-pid` runs, that daemon is the one serving this terminal's daemon
//! socket, and `--result` is an outcome file next to it. Then it hard-links
//! the running binary as `cmux-tui.prev`, renames itself over the binary
//! (one atomic rename in the same folder, of the very file it hashed) and sends
//! the daemon SIGTERM, which ends only the daemon: every terminal host and
//! chat keeps running, and the daemon the supervisor starts from the new
//! binary adopts them (docs/cloud-guest-upgrades.md). A new daemon that does
//! not serve within ten minutes is replaced by the previous binary, which is
//! trusted only once it serves again. The outcome goes to `--result` as one
//! JSON object: `{"state":"updated"|"rolled_back"|"pending"|"failed",
//! "detail":...}`.
//!
//! The lock orders this mode's own runs only; the image's root fleet
//! upgrade script keeps its own lock.
//!
//! Linux only: a Cloud machine is a Linux machine.

use std::os::unix::fs::MetadataExt as _;
use std::os::unix::io::AsRawFd as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::json;
use sha2::{Digest as _, Sha256};

/// The private argv mode (crate::private_mode).
pub(crate) const MODE: &str = "__machine-update-apply";
/// How long the old daemon may take to stop after SIGTERM.
const STOP_TIMEOUT: Duration = Duration::from_secs(60);
/// How long a daemon may take to serve: it replays its journal and adopts
/// every terminal host before it listens.
const SERVE_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// A daemon must keep serving this long to count.
const SETTLE: Duration = Duration::from_secs(5);
const INSTALL_SUFFIX: &str = "/.cmux/bin/cmux-tui";
const RESULT_PREFIX: &str = ".cmux-tui.update-";
/// The folder's update lock: a second update while one runs is `busy`.
const LOCK_NAME: &str = ".cmux-tui.update.lock";

/// The fixed argv the Mac side runs on the machine.
pub(crate) fn argv(
    staged: &str,
    sha256: &str,
    install: &str,
    pid: u64,
    result: &str,
) -> Vec<String> {
    [
        staged,
        MODE,
        "--sha256",
        sha256,
        "--install",
        install,
        "--daemon-pid",
        &pid.to_string(),
        "--result",
        result,
    ]
    .map(str::to_owned)
    .to_vec()
}

pub(crate) fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

struct Args {
    sha256: String,
    install: PathBuf,
    daemon_pid: i32,
    result: PathBuf,
}

/// Runs the apply step; the exit code (its outcome is in `--result`).
pub(crate) fn run(args: &[String]) -> i32 {
    let Some(args) = parse(args) else {
        eprintln!(
            "usage: cmux-tui {MODE} --sha256 HEX --install PATH --daemon-pid PID --result PATH"
        );
        return 64;
    };
    let (state, detail) = apply(&args);
    let outcome = json!({"state": state, "detail": detail});
    eprintln!("cmux machine update: {outcome}");
    // The outcome goes only next to this user's own binary.
    let written = own_install(&args.install)
        .map_err(std::io::Error::other)
        .and_then(|()| write_atomically(&args.result, outcome.to_string().as_bytes()));
    if written.is_err() || state != "updated" { 1 } else { 0 }
}

fn parse(args: &[String]) -> Option<Args> {
    let mut rest = args.iter();
    let (mut sha256, mut install, mut daemon_pid, mut result) = (None, None, None, None);
    while let Some(flag) = rest.next() {
        let value = rest.next()?;
        match flag.as_str() {
            "--sha256" => sha256 = Some(value.clone()),
            "--install" => install = Some(PathBuf::from(value)),
            "--daemon-pid" => daemon_pid = value.parse::<i32>().ok().filter(|pid| *pid > 1),
            "--result" => result = Some(PathBuf::from(value)),
            _ => return None,
        }
    }
    let (sha256, install, daemon_pid, result) = (sha256?, install?, daemon_pid?, result?);
    let install_text = install.to_str()?;
    let plain = |path: &Path| {
        path.components().all(|part| {
            matches!(part, std::path::Component::Normal(_) | std::path::Component::RootDir)
        })
    };
    let result_ok = result.parent() == install.parent()
        && result
            .file_name()?
            .to_str()?
            .strip_prefix(RESULT_PREFIX)?
            .strip_suffix(".json")
            .is_some_and(|nonce| {
                nonce.len() == 16 && nonce.bytes().all(|byte| byte.is_ascii_hexdigit())
            });
    let valid = is_sha256(&sha256)
        && install.is_absolute()
        && install_text.ends_with(INSTALL_SUFFIX)
        && plain(&install)
        && result_ok;
    valid.then_some(Args { sha256, install, daemon_pid, result })
}

/// The update itself: its outcome state and a detail line.
fn apply(args: &Args) -> (&'static str, String) {
    // Nothing is written next to an install path that is not this user's own.
    if let Err(why) = own_install(&args.install) {
        return ("failed", why);
    }
    let Some(_lock) = lock(&args.install) else {
        return ("busy", "another update of this machine is running".into());
    };
    let own = match check(args) {
        Ok(own) => own,
        Err(why) => return ("failed", why),
    };
    // A hard link: no copy, no space, and a planted file there goes first.
    let previous = args.install.with_file_name("cmux-tui.prev");
    let _ = cmux_blocking::fs::remove_file(&previous);
    if let Err(error) = crate::blocking::fs::hard_link(&args.install, &previous) {
        return ("failed", format!("cannot keep the running binary: {error}"));
    }
    // The file at our own path is still the one hashed: same inode, one link.
    match cmux_blocking::fs::symlink_metadata(&own.path) {
        Ok(now) if now.dev() == own.dev && now.ino() == own.ino && now.nlink() == 1 => {}
        _ => return ("failed", "the staged build changed after it was checked".into()),
    }
    if let Err(error) = cmux_blocking::fs::rename(&own.path, &args.install) {
        return ("failed", format!("cannot install the new build: {error}"));
    }
    // SAFETY: kill has no memory preconditions; the pid was checked to run
    // the installed binary and to serve this terminal's daemon socket.
    // A daemon already gone (ESRCH) counts as stopped: its supervisor may be
    // starting the new binary right now.
    if unsafe { libc::kill(args.daemon_pid, libc::SIGTERM) } != 0
        && std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    {
        // The old daemon still runs (and serves): only put its binary back.
        return match put_back(args, &previous) {
            Ok(()) => ("rolled_back", "the daemon could not be stopped; nothing changed".into()),
            Err(error) => (
                "failed",
                format!(
                    "the daemon could not be stopped, and its binary could not be put back: {error}"
                ),
            ),
        };
    }
    if !wait(STOP_TIMEOUT, || !alive(args.daemon_pid)) {
        return (
            "pending",
            "the daemon did not stop; the new build runs after its next restart".into(),
        );
    }
    let own_build = cmux_build_identity::BUILD_IDENTITY;
    if serving(|build| build == own_build, args.daemon_pid) {
        return ("updated", format!("the daemon runs {own_build}"));
    }
    restore(args, &previous, "the new daemon did not serve")
}

/// The staged build that passed [`check`]: its path and the inode hashed.
struct Staged {
    path: PathBuf,
    dev: u64,
    ino: u64,
}

/// Whether `install` is this user's `~/.cmux/bin/cmux-tui`.
fn own_install(install: &Path) -> Result<(), String> {
    let home = std::env::var_os("HOME").ok_or("no HOME")?;
    let expected = PathBuf::from(home).join(".cmux/bin/cmux-tui");
    let canonical = |path: &Path| {
        cmux_blocking::fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()))
    };
    if canonical(install)? != canonical(&expected)? {
        return Err("the install path is not this user's ~/.cmux/bin/cmux-tui".into());
    }
    Ok(())
}

/// Every check before anything changes.
fn check(args: &Args) -> Result<Staged, String> {
    own_install(&args.install)?;
    let canonical = |path: &Path| {
        cmux_blocking::fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()))
    };
    let own = std::env::current_exe().map_err(|e| e.to_string())?;
    if own.parent() != canonical(&args.install)?.parent() {
        return Err("the new build is not staged beside the binary".into());
    }
    // Hash the file through one descriptor, and remember which file it was.
    let mut file = cmux_blocking::fs::open(&own).map_err(|e| e.to_string())?;
    let opened = file.metadata().map_err(|e| e.to_string())?;
    let mut digest = Sha256::new();
    std::io::copy(&mut file, &mut digest).map_err(|e| e.to_string())?;
    let sha256: String = digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    if sha256 != args.sha256 {
        return Err("the staged build does not match the pinned checksum".into());
    }
    let running = crate::blocking::fs::read_link(format!("/proc/{}/exe", args.daemon_pid))
        .map_err(|e| format!("cannot read the daemon's binary: {e}"))?;
    if running != canonical(&args.install)? {
        return Err("the daemon does not run the installed binary".into());
    }
    // The pid is the daemon serving this terminal's socket now, not a pid
    // reused since the Mac read it.
    let socket = socket().ok_or("no daemon socket in this terminal")?;
    let identity =
        super::super::machine_gate::identify(&socket).ok_or("the daemon socket did not answer")?;
    if identity["pid"].as_i64() != Some(i64::from(args.daemon_pid)) {
        return Err("the daemon pid is not the one serving this machine".into());
    }
    Ok(Staged { path: own, dev: opened.dev(), ino: opened.ino() })
}

/// The folder's update lock, held while this process lives.
fn lock(install: &Path) -> Option<std::fs::File> {
    let file = crate::blocking::fs::open_with(
        std::fs::OpenOptions::new().create(true).truncate(false).write(true),
        install.with_file_name(LOCK_NAME),
    )
    .ok()?;
    // SAFETY: flock on a descriptor this function owns.
    let locked = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
    locked.then_some(file)
}

/// Puts the previous binary back over the install, atomically.
fn put_back(args: &Args, previous: &Path) -> std::io::Result<()> {
    let back = args.install.with_file_name(".cmux-tui.rollback");
    let _ = cmux_blocking::fs::remove_file(&back);
    crate::blocking::fs::hard_link(previous, &back)?;
    cmux_blocking::fs::rename(&back, &args.install)
}

/// Puts the previous binary back and waits for a daemon of it to serve.
fn restore(args: &Args, previous: &Path, why: &str) -> (&'static str, String) {
    let restored = put_back(args, previous);
    if let Err(error) = restored {
        return (
            "failed",
            format!("{why}, and the previous binary could not be restored: {error}"),
        );
    }
    // The new daemon may still run (or crash-loop); end it so the
    // supervisor starts the restored binary.
    if let Some(pid) = socket()
        .and_then(|socket| super::super::machine_gate::identify(&socket))
        .and_then(|identity| identity["pid"].as_i64())
        .and_then(|pid| i32::try_from(pid).ok())
    {
        // SAFETY: as above.
        unsafe { libc::kill(pid, libc::SIGTERM) };
    }
    let new_build = cmux_build_identity::BUILD_IDENTITY;
    if serving(|build| build != new_build, args.daemon_pid) {
        ("rolled_back", format!("{why}; the previous binary serves again"))
    } else {
        ("failed", format!("{why}, and the restored previous binary does not serve either"))
    }
}

/// True once a daemon other than `old_pid` whose build passes `wanted`
/// answers on this terminal's daemon socket and keeps answering for
/// [`SETTLE`].
fn serving(wanted: impl Fn(&str) -> bool, old_pid: i32) -> bool {
    let Some(socket) = socket() else { return false };
    let deadline = Instant::now() + SERVE_TIMEOUT;
    while Instant::now() < deadline {
        if let Some(pid) = answering(&socket, &wanted, old_pid) {
            cmux_blocking::thread::sleep(SETTLE);
            if answering(&socket, &wanted, old_pid) == Some(pid) {
                return true;
            }
        }
        cmux_blocking::thread::sleep(Duration::from_secs(1));
    }
    false
}

fn answering(socket: &Path, wanted: &impl Fn(&str) -> bool, old_pid: i32) -> Option<i64> {
    let identity = super::super::machine_gate::identify(socket)?;
    let pid = identity["pid"].as_i64()?;
    let build = super::super::machine_gate::build_id(&identity)?;
    (pid != i64::from(old_pid) && wanted(build)).then_some(pid)
}

/// The daemon socket this terminal's daemon gave it.
fn socket() -> Option<PathBuf> {
    std::env::var_os("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()).map(PathBuf::from)
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn wait(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if done() {
            return true;
        }
        cmux_blocking::thread::sleep(Duration::from_millis(100));
    }
    done()
}

/// A file's SHA-256, lowercase hex.
pub(crate) fn file_sha256(path: &Path) -> std::io::Result<String> {
    let mut file = cmux_blocking::fs::open(path)?;
    let mut digest = Sha256::new();
    std::io::copy(&mut file, &mut digest)?;
    Ok(digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("json.part");
    cmux_blocking::fs::write(&temporary, bytes)?;
    cmux_blocking::fs::rename(&temporary, path)
}
