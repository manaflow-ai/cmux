//! The machine side of `cmux link machine update` (cx-rppd.13):
//! `cmux-tui __machine-update-apply --sha256 HEX --install PATH --daemon-pid
//! PID --result PATH`, run once by the machine's own daemon in a detached
//! terminal, as the daemon's user, from the staged new build itself.
//!
//! It touches nothing until every check passes: its own executable has the
//! pinned checksum, `--install` is `$HOME/.cmux/bin/cmux-tui` and is the
//! binary daemon `--daemon-pid` runs, and `--result` is an outcome file next
//! to it. Then it copies the running binary to `cmux-tui.prev`, renames
//! itself over the binary (one atomic rename in the same folder) and sends
//! the daemon SIGTERM, which ends only the daemon: every terminal host and
//! chat keeps running, and the daemon the supervisor starts from the new
//! binary adopts them (docs/cloud-guest-upgrades.md). A new daemon that does
//! not serve within ten minutes is replaced by the previous binary, which is
//! trusted only once it serves again. The outcome goes to `--result` as one
//! JSON object: `{"state":"updated"|"rolled_back"|"pending"|"failed",
//! "detail":...}`.
//!
//! Linux only: a Cloud machine is a Linux machine.

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
    let written = write_atomically(&args.result, outcome.to_string().as_bytes());
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
    if let Err(why) = check(args) {
        return ("failed", why);
    }
    let previous = args.install.with_file_name("cmux-tui.prev");
    if let Err(error) = std::fs::copy(&args.install, &previous) {
        return ("failed", format!("cannot keep the running binary: {error}"));
    }
    let own = match std::env::current_exe() {
        Ok(own) => own,
        Err(error) => return ("failed", format!("cannot name the new build: {error}")),
    };
    if let Err(error) = std::fs::rename(&own, &args.install) {
        return ("failed", format!("cannot install the new build: {error}"));
    }
    // SAFETY: kill has no memory preconditions; the pid was checked to run
    // the installed binary.
    if unsafe { libc::kill(args.daemon_pid, libc::SIGTERM) } != 0 {
        return restore(args, &previous, "the daemon could not be stopped");
    }
    if !wait(STOP_TIMEOUT, || !alive(args.daemon_pid)) {
        return (
            "pending",
            "the daemon did not stop; the new build runs after its next restart".into(),
        );
    }
    let own_build = cmux_remote::ssh_bootstrap::BUILD_IDENTITY;
    if serving(|build| build == own_build, args.daemon_pid) {
        return ("updated", format!("the daemon runs {own_build}"));
    }
    restore(args, &previous, "the new daemon did not serve")
}

/// Every check before anything changes.
fn check(args: &Args) -> Result<(), String> {
    let home = std::env::var_os("HOME").ok_or("no HOME")?;
    let expected = PathBuf::from(home).join(".cmux/bin/cmux-tui");
    let canonical =
        |path: &Path| std::fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()));
    if canonical(&args.install)? != canonical(&expected)? {
        return Err("the install path is not this user's ~/.cmux/bin/cmux-tui".into());
    }
    let own = std::env::current_exe().map_err(|e| e.to_string())?;
    if own.parent() != canonical(&args.install)?.parent() {
        return Err("the new build is not staged beside the binary".into());
    }
    if file_sha256(&own).map_err(|e| e.to_string())? != args.sha256 {
        return Err("the staged build does not match the pinned checksum".into());
    }
    let running = std::fs::read_link(format!("/proc/{}/exe", args.daemon_pid))
        .map_err(|e| format!("cannot read the daemon's binary: {e}"))?;
    if running != canonical(&args.install)? {
        return Err("the daemon does not run the installed binary".into());
    }
    Ok(())
}

/// Puts the previous binary back and waits for a daemon of it to serve.
fn restore(args: &Args, previous: &Path, why: &str) -> (&'static str, String) {
    let back = args.install.with_file_name(".cmux-tui.rollback");
    let restored =
        std::fs::copy(previous, &back).and_then(|_| std::fs::rename(&back, &args.install));
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
    let new_build = cmux_remote::ssh_bootstrap::BUILD_IDENTITY;
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
            std::thread::sleep(SETTLE);
            if answering(&socket, &wanted, old_pid) == Some(pid) {
                return true;
            }
        }
        std::thread::sleep(Duration::from_secs(1));
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
        std::thread::sleep(Duration::from_millis(100));
    }
    done()
}

fn file_sha256(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut digest = Sha256::new();
    std::io::copy(&mut file, &mut digest)?;
    Ok(digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("json.part");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(&temporary, path)
}
