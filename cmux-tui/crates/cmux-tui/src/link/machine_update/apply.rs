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
//! the daemon SIGTERM (SIGKILL once [`STOP_TIMEOUT`] passes: a daemon resumes
//! what it interrupted), which ends only the daemon: every terminal host and
//! chat keeps running, and the daemon the supervisor starts from the new
//! binary adopts them (docs/cloud-guest-upgrades.md). A new daemon that does
//! not serve within ten minutes is replaced by the previous binary, which is
//! trusted only once it serves again. The outcome goes to `--result` as one
//! JSON object: `{"state":"updated"|"rolled_back"|"pending"|"busy"|"foreign"|"failed",
//! "detail":...}`.
//!
//! A daemon still running an earlier copy of this same install (a binary an
//! earlier update or upgrade replaced while that daemon kept running, which
//! the kernel names `<install> (deleted)`, or `cmux-tui.prev`) is updated
//! like any other: stopping it is what that earlier update could not finish
//! ([`runs_this_install`]). A daemon on any other binary (someone's
//! own build run from another path) is `foreign`: left as it is, and no
//! failure, since nothing went wrong with the update. A daemon that restarted
//! since the Mac read its pid is `busy`: the next update reads it again.
//!
//! The step learns which binary the daemon runs only from the daemon socket
//! itself: the kernel's peer of a connection to `CMUX_TUI_SOCKET` must be
//! `--daemon-pid`, and its executable is read through that one connection's
//! peer authentication ([`daemon_binary`]), never by a pid alone
//! (plans/cmux-next/pty-holder.md, section 4).
//!
//! On a self-updating image (`--route store`) the build goes to the machine's
//! root updater instead ([`apply_store`]). The updater answers `older` when it
//! already applied a build with a later commit time; that is `foreign` too,
//! unless the Mac asked for this build itself (`--to-bundled` without
//! `--if-older`, which it passes as [`IN_PLACE_FLAG`]). Then the staged build is
//! renamed over the work user's store link and the daemon (and acpmux) restart
//! on it from that path ([`apply_in_place`]), so an app built from a branch can
//! still put its build on a machine whose channel moved past it (2026-11-16).
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
/// How long the old daemon may take to stop after SIGTERM, before SIGKILL.
const STOP_TIMEOUT: Duration = Duration::from_secs(60);
/// How long the kernel may take to end it after SIGKILL.
const KILL_TIMEOUT: Duration = Duration::from_secs(10);
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

/// How the new build reaches the daemon (`--route`, default `work`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    /// Renamed over `--install`, the daemon's own file; only the daemon restarts.
    Work,
    /// `--install` links into the self-updating image's store: the build goes into the
    /// store as the machine's next profile (`cmux host update install`, as root through
    /// `sudo -n`), and the machine restarts acpmux, the session host and `cmux host` on it.
    Store,
}

/// `--route store` only, no value: the Mac asked for this build itself (`--to-bundled`
/// without `--if-older`), so a store that refuses it as older than a build it applied
/// gets it installed in place instead ([`apply_in_place`]). Only the staged build reads
/// this argv, and it is always the Mac's own build, so no older apply step ever sees it.
pub(crate) const IN_PLACE_FLAG: &str = "--in-place-if-older-refused";

struct Args {
    sha256: String,
    install: PathBuf,
    daemon_pid: i32,
    result: PathBuf,
    route: Route,
    /// [`IN_PLACE_FLAG`].
    in_place: bool,
}

/// Runs the apply step; the exit code (its outcome is in `--result`).
pub(crate) fn run(args: &[String]) -> i32 {
    let Some(args) = parse(args) else {
        eprintln!(
            "usage: cmux-tui {MODE} --sha256 HEX --install PATH --daemon-pid PID --result PATH [--route work|store [{IN_PLACE_FLAG}]]"
        );
        return 64;
    };
    // A second run of this same update (its start sent again after a lost
    // answer) leaves everything, its outcome file included, to the first:
    // the first holds the outcome's own lock until it has written it.
    let _claim = match own_install(&args.install) {
        Ok(()) => match claim(&args.result) {
            Some(claim) => Some(claim),
            None => {
                eprintln!("cmux machine update: this update already runs");
                return 1;
            }
        },
        Err(_) => None,
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
    let mut route = Route::Work;
    let mut in_place = false;
    while let Some(flag) = rest.next() {
        if flag == IN_PLACE_FLAG {
            if in_place {
                return None;
            }
            in_place = true;
            continue;
        }
        let value = rest.next()?;
        match flag.as_str() {
            "--sha256" => sha256 = Some(value.clone()),
            "--install" => install = Some(PathBuf::from(value)),
            "--daemon-pid" => daemon_pid = value.parse::<i32>().ok().filter(|pid| *pid > 1),
            "--result" => result = Some(PathBuf::from(value)),
            "--route" => {
                route = match value.as_str() {
                    "work" => Route::Work,
                    "store" => Route::Store,
                    _ => return None,
                }
            }
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
        && result_ok
        && (!in_place || route == Route::Store);
    valid.then_some(Args { sha256, install, daemon_pid, result, route, in_place })
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
    // The Mac sees this step began even when its start's answer was lost,
    // and so does not start it again (machine_update.rs `start`); a run it
    // starts anyway finds the outcome claimed ([`claim`]) and writes nothing.
    let _ = write_atomically(&args.result, RUNNING.as_bytes());
    if args.route == Route::Store {
        return apply_store(args);
    }
    let own = match check(args) {
        Ok(own) => own,
        Err((state, why)) => return (state, why),
    };
    let previous = args.install.with_file_name("cmux-tui.prev");
    if let Err(error) = keep_previous(&args.install, &previous, &own.daemon.file, own.daemon.id) {
        return ("failed", format!("cannot keep the running binary: {error}"));
    }
    // The file at our own path is still the one hashed: same inode, one link.
    match std::fs::symlink_metadata(&own.path) {
        Ok(now) if now.dev() == own.dev && now.ino() == own.ino && now.nlink() == 1 => {}
        _ => return ("failed", "the staged build changed after it was checked".into()),
    }
    if let Err(error) = std::fs::rename(&own.path, &args.install) {
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
    if !stop(args.daemon_pid, STOP_TIMEOUT, KILL_TIMEOUT) {
        return (
            "pending",
            "the daemon did not stop, even after SIGKILL; the new build runs after its next restart"
                .into(),
        );
    }
    let own_build = cmux_build_identity::BUILD_IDENTITY;
    if serving(|build| build == own_build, args.daemon_pid) {
        return ("updated", format!("the daemon runs {own_build}"));
    }
    restore(args, &previous, "the new daemon did not serve")
}

/// The store route ([`Route::Store`]): checks this staged build against the pin, has the
/// machine's updater put a root-owned copy of it in the store and flip the profile to it
/// (`cmux host update install`, which relinks `--install` into `current` and restarts
/// acpmux, the cmux units and `cmux host`; the new host proves the build or rolls it
/// back), then waits until the daemon on this terminal's socket and the acpmux daemon
/// both run it. A machine whose updater was turned off on purpose or rolled this build
/// back is left as it is (`foreign`), as is one that already applied a newer build,
/// unless the Mac asked for this build itself ([`IN_PLACE_FLAG`]): then it is installed
/// in place ([`apply_in_place`]).
fn apply_store(args: &Args) -> (&'static str, String) {
    let own = match std::env::current_exe() {
        Ok(own) => own,
        Err(error) => return ("failed", format!("cannot read the staged build's path: {error}")),
    };
    let own_id = match hashed_file(&own) {
        Ok((sha, id)) if sha == args.sha256 => id,
        _ => return ("failed", "the staged build does not have the pinned checksum".into()),
    };
    match std::fs::read_link(&args.install) {
        Ok(target) if target == Path::new(STORE_CURRENT) => {}
        _ => {
            return (
                "foreign",
                format!("{} is not the store link; left as it is", args.install.display()),
            );
        }
    }
    let build = cmux_build_identity::BUILD_IDENTITY;
    let answer = cmux_process::Command::new("sudo")
        .args(["-n", "bash", "-c", STORE_INSTALL])
        .arg(&own)
        .arg(build)
        .arg(cmux_build_identity::BUILD_TIME.to_string())
        .stdin(cmux_process::Stdio::null())
        .output();
    let answer = match answer {
        Ok(answer) => answer,
        Err(error) => return ("failed", format!("cannot run the machine's updater: {error}")),
    };
    let (state, detail) = store_answer(&String::from_utf8_lossy(&answer.stdout));
    match store_next(state, args.in_place) {
        StoreNext::Wait => {}
        StoreNext::InPlace => return apply_in_place(args, &own, own_id, &detail),
        StoreNext::Foreign => return ("foreign", detail),
        StoreNext::Failed => {
            let why = String::from_utf8_lossy(&answer.stderr);
            return ("failed", format!("the machine's updater refused: {detail} {}", why.trim()));
        }
    }
    let binary = Path::new("/opt/cmux/store").join(&args.sha256).join("cmux-tui");
    if !serving(|running| running == build, args.daemon_pid) {
        return (
            "failed",
            "the new build did not serve within ten minutes; the machine's updater rolls it back"
                .into(),
        );
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return ("failed", "no HOME".into());
    };
    if home.join(ACPMUX_UNIT).exists() && !wait(SERVE_TIMEOUT, || acpmux_runs(&binary)) {
        return ("failed", "acpmux did not restart on the new build within ten minutes".into());
    }
    ("updated", format!("the machine runs {build}: its session host, acpmux and cmux host"))
}

/// What [`apply_store`] does after the updater's answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StoreNext {
    /// The updater installs the build (or has it): wait until it runs.
    Wait,
    /// The updater refused it as older and the Mac asked for it: [`apply_in_place`].
    InPlace,
    /// Left as it is, and no failure.
    Foreign,
    Failed,
}

/// The step for the updater's answer `state` ([`store_answer`]); `in_place` is
/// [`IN_PLACE_FLAG`]. Only `older` is installed in place: `off` and `rolled-back-before`
/// are someone's decision about this machine or this build, and stay `foreign`.
fn store_next(state: &str, in_place: bool) -> StoreNext {
    match state {
        "updating" | "current" => StoreNext::Wait,
        "older" if in_place => StoreNext::InPlace,
        "older" | "off" | "rolled-back-before" => StoreNext::Foreign,
        _ => StoreNext::Failed,
    }
}

/// The store refused this build as older than one it applied, and the Mac asked for this
/// build itself: the staged build `own` (the file hashed, `own_id` its device and inode) is
/// renamed over the work link `--install`, so it is a regular file there. The daemon gets
/// SIGTERM as on the work route, and its supervisor (`cmux host`) starts
/// `~/.cmux/bin/cmux-tui` again, now this build. Where the work user has the acpmux unit, its
/// `~/.local/bin/acpmux` link follows the work link and acpmux restarts on it
/// ([`acpmux_in_place`]). The store and its profiles stay as they are; the machine's updater
/// is off for this machine by its own rule (the work link is not the store link), until
/// `cmux host update adopt` links it again. A daemon (or acpmux) that does not serve the new
/// build puts the store link back and restarts again.
fn apply_in_place(
    args: &Args,
    own: &Path,
    own_id: (u64, u64),
    refused: &str,
) -> (&'static str, String) {
    let Some(socket) = socket() else {
        return ("failed", "no daemon socket in this terminal".into());
    };
    // The pid is the daemon serving this terminal's socket, and it runs a store entry.
    let daemon = match daemon_binary(&socket, args.daemon_pid) {
        Ok(daemon) => daemon,
        Err((state, why)) => return (state, why),
    };
    if !runs_a_store_entry(&daemon.path) {
        return ("foreign", foreign(args.daemon_pid, &daemon.path, Path::new(STORE_CURRENT)));
    }
    match std::fs::symlink_metadata(own) {
        Ok(now) if (now.dev(), now.ino()) == own_id && now.nlink() == 1 => {}
        _ => return ("failed", "the staged build changed after it was checked".into()),
    }
    if std::fs::read_link(&args.install).ok().as_deref() != Some(Path::new(STORE_CURRENT)) {
        return (
            "foreign",
            format!("{} is not the store link; left as it is", args.install.display()),
        );
    }
    if let Err(error) = std::fs::rename(own, &args.install) {
        return ("failed", format!("cannot install the new build in place: {error}"));
    }
    let put_back = || relink(&args.install, Path::new(STORE_CURRENT), STORE_PART);
    // SAFETY: as in apply: the pid serves this terminal's socket and runs the store's build.
    if unsafe { libc::kill(args.daemon_pid, libc::SIGTERM) } != 0
        && std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    {
        return match put_back() {
            Ok(()) => ("rolled_back", "the daemon could not be stopped; nothing changed".into()),
            Err(error) => (
                "failed",
                format!(
                    "the daemon could not be stopped, and the store link could not be put back: {error}"
                ),
            ),
        };
    }
    if !stop(args.daemon_pid, STOP_TIMEOUT, KILL_TIMEOUT) {
        return (
            "pending",
            "the daemon did not stop, even after SIGKILL; the new build runs after its next restart"
                .into(),
        );
    }
    let build = cmux_build_identity::BUILD_IDENTITY;
    if !serving(|running| running == build, args.daemon_pid) {
        return restore_by("the new daemon did not serve", put_back, args.daemon_pid);
    }
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return restore_by("no HOME", put_back, args.daemon_pid);
    };
    let acpmux = if home.join(ACPMUX_UNIT).exists() {
        match acpmux_in_place(&home, &args.install) {
            Ok(acpmux) => acpmux,
            Err(why) => return restore_by(&why, put_back, args.daemon_pid),
        }
    } else {
        "no acpmux unit".to_owned()
    };
    (
        "updated",
        format!(
            "the session host runs {build} from {} ({acpmux}); the store refused it ({refused}), so the machine's updater is off until the store link is back",
            args.install.display()
        ),
    )
}

/// What [`relink`] names the link it makes beside the work link.
const STORE_PART: &str = ".cmux-tui.store-part";
/// The work user's acpmux, under HOME: the unit's `ExecStart` (`acpmux daemon run`).
const ACPMUX_LINK: &str = ".local/bin/acpmux";
/// What [`ACPMUX_LINK`] points at on a self-updating image (bake.ts `acpmux-current-link`).
const STORE_ACPMUX: &str = "/opt/cmux/current/bin/acpmux";
const ACPMUX_PART: &str = ".acpmux.in-place-part";

/// What [`acpmux_in_place`] does with the work user's acpmux link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AcpmuxLink {
    /// It points at the store's acpmux: point it at the work link.
    Relink,
    /// It already points at the work link (an earlier in-place update).
    Follows,
    /// Anything else (someone's own acpmux): left as it is, and not restarted.
    Other,
}

/// The step for an acpmux link whose target is `target` (None: no link), given the work
/// link `install`.
fn acpmux_link(target: Option<&Path>, install: &Path) -> AcpmuxLink {
    match target {
        Some(target) if target == Path::new(STORE_ACPMUX) => AcpmuxLink::Relink,
        Some(target) if target == install => AcpmuxLink::Follows,
        _ => AcpmuxLink::Other,
    }
}

/// Points the work user's acpmux link at the work link `install` (acpmux is the same binary
/// under the name `acpmux`), restarts `acpmux.service` and waits until the acpmux daemon runs
/// the file now at `install`. On failure the store's acpmux link goes back and acpmux restarts
/// on it again; the error says why. Ok names what happened, for the outcome's detail.
fn acpmux_in_place(home: &Path, install: &Path) -> Result<String, String> {
    let link = home.join(ACPMUX_LINK);
    let plan = acpmux_link(std::fs::read_link(&link).ok().as_deref(), install);
    if plan == AcpmuxLink::Other {
        return Ok(format!("{} is not the store's acpmux; acpmux left as it is", link.display()));
    }
    if plan == AcpmuxLink::Relink {
        relink(&link, install, ACPMUX_PART).map_err(|e| {
            format!("cannot point {} at {}: {e}", link.display(), install.display())
        })?;
    }
    // The acpmux daemon's executable, as the kernel names it: the regular file at `install`.
    let binary = std::fs::canonicalize(install).unwrap_or_else(|_| install.to_owned());
    let failed = match restart_acpmux() {
        Ok(()) if wait(SERVE_TIMEOUT, || acpmux_runs(&binary)) => {
            return Ok("acpmux runs it too".into());
        }
        Ok(()) => "acpmux did not restart on the new build within ten minutes".to_owned(),
        Err(why) => format!("acpmux did not restart: {why}"),
    };
    if plan == AcpmuxLink::Relink {
        let _ = relink(&link, Path::new(STORE_ACPMUX), ACPMUX_PART);
        let _ = restart_acpmux();
    }
    Err(failed)
}

/// `systemctl --user restart acpmux.service`, at most a minute. The session host passes no
/// `XDG_RUNTIME_DIR` to its terminals (cmux-host `daemon_spec`), and `systemctl --user` finds
/// the user manager through it, so it is set to this user's runtime folder when missing, as
/// the machine's updater does for its acpmux calls.
fn restart_acpmux() -> Result<(), String> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|value| !value.is_empty())
        // SAFETY: getuid has no preconditions.
        .unwrap_or_else(|| format!("/run/user/{}", unsafe { libc::getuid() }).into());
    let output = cmux_process::Command::new("timeout")
        .args(["60", "systemctl", "--user", "restart", "acpmux.service"])
        .env("XDG_RUNTIME_DIR", runtime)
        .stdin(cmux_process::Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        return Ok(());
    }
    Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
}

/// Points `link` at `target`: a link made beside it (named `part`) and renamed over it, so
/// `link` is never missing.
fn relink(link: &Path, target: &Path, part: &str) -> std::io::Result<()> {
    let part = link.with_file_name(part);
    let _ = std::fs::remove_file(&part);
    std::os::unix::fs::symlink(target, &part)?;
    std::fs::rename(&part, link)
}

/// Whether a daemon's binary, as the kernel names it, is a store entry's cmux-tui.
fn runs_a_store_entry(running: &Path) -> bool {
    running
        .to_str()
        .and_then(|path| path.strip_prefix("/opt/cmux/store/"))
        .and_then(|entry| entry.strip_suffix("/cmux-tui"))
        .is_some_and(is_sha256)
}

/// The updater's link the work user's cmux-tui points at on a self-updating image.
const STORE_CURRENT: &str = "/opt/cmux/current/bin/cmux-tui";
/// The work user's acpmux unit (`cmuxTuiServiceInstallCommand`), under HOME.
const ACPMUX_UNIT: &str = ".config/systemd/user/acpmux.service";
/// Run as root by [`apply_store`] with the staged build, its commit and commit time:
/// a root-owned copy of the build runs its own `cmux host update install` (`host` is
/// mounted only under the name `cmux`), which moves that copy into the store.
const STORE_INSTALL: &str = r#"set -eu
f=$(mktemp /var/tmp/cmux-install.XXXXXX)
install -m 0555 -o root -g root "$0" "$f"
exec -a cmux "$f" host update install --file "$f" --commit "$1" --committed-at "$2""#;

/// The state and detail of `cmux host update install`'s one JSON line; `unknown` for
/// anything else.
pub(super) fn store_answer(stdout: &str) -> (&'static str, String) {
    let answer = stdout
        .lines()
        .rev()
        .find_map(|line| serde_json::from_str::<serde_json::Value>(line.trim()).ok());
    let detail = answer
        .as_ref()
        .and_then(|answer| answer["detail"].as_str())
        .unwrap_or_else(|| stdout.trim())
        .to_owned();
    let state = match answer.as_ref().and_then(|answer| answer["state"].as_str()) {
        Some("updating") => "updating",
        Some("current") => "current",
        Some("older") => "older",
        Some("off") => "off",
        Some("rolled-back-before") => "rolled-back-before",
        Some("failed") => "failed",
        _ => "unknown",
    };
    (state, detail)
}

/// Whether the acpmux daemon serving this user's acpmux socket (`acpmux::config::socket_path`,
/// the one rule every acpmux client shares) runs `binary`. Its executable is read through that
/// one connection's peer authentication, as [`daemon_binary`] does for the cmux daemon, never
/// by a pid alone (plans/cmux-next/pty-holder.md, section 4).
fn acpmux_runs(binary: &Path) -> bool {
    use cmux_tui_core::platform::transport::Stream as _;
    let Ok(stream) = std::os::unix::net::UnixStream::connect(acpmux::config::socket_path()) else {
        return false;
    };
    match stream.peer_process_key().and_then(|key| peer_binary(&key)) {
        Some((path, _)) => path == binary,
        // A daemon that holds a person key is not dumpable (acpmux `not_dumpable`), so the
        // kernel owns its /proc files and this user cannot read its executable: it names it.
        None => acpmux_says_it_runs(binary),
    }
}

/// [`acpmux_runs`] for a daemon whose executable this user cannot read: what that daemon's own
/// `daemon status` names (`exe`), asked through this user's acpmux link, which never starts one.
fn acpmux_says_it_runs(binary: &Path) -> bool {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return false };
    cmux_process::Command::new("timeout")
        .arg("10")
        .arg(home.join(ACPMUX_LINK))
        .args(["--json", "daemon", "status"])
        .stdin(cmux_process::Stdio::null())
        .output()
        .is_ok_and(|output| status_names(&String::from_utf8_lossy(&output.stdout), binary))
}

/// Whether a `daemon status` answer names `binary` as the running daemon's executable.
pub(super) fn status_names(stdout: &str, binary: &Path) -> bool {
    serde_json::from_str::<serde_json::Value>(stdout.trim()).is_ok_and(|status| {
        status
            .get("exe")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|exe| Path::new(exe) == binary)
    })
}

/// The staged build that passed [`check`]: its path and the inode hashed,
/// with the binary the daemon runs.
struct Staged {
    path: PathBuf,
    dev: u64,
    ino: u64,
    daemon: DaemonBinary,
}

/// The binary the daemon on this terminal's socket runs: its path as the
/// kernel reads it (` (deleted)` once no path names it), the file itself,
/// open (it still reads after its path is gone), and its device and inode.
struct DaemonBinary {
    path: PathBuf,
    file: std::fs::File,
    id: (u64, u64),
}

/// The outcome file's content while the step runs.
const RUNNING: &str = r#"{"state":"running"}"#;

/// Keeps the build the daemon runs as `previous`, the rollback target: a
/// hard link of `install` when the daemon runs it (no copy, no space), the
/// file already there when it runs that one, else a copy of `running`, the
/// running file itself, open ([`DaemonBinary`]), with its mode. A daemon left
/// on a replaced build must roll back to that build, not to the installed one
/// that never served. `running_id` is that file's device and inode.
fn keep_previous(
    install: &Path,
    previous: &Path,
    running: &std::fs::File,
    running_id: (u64, u64),
) -> std::io::Result<()> {
    let is_running = |path: &Path| {
        std::fs::symlink_metadata(path).ok().map(|file| (file.dev(), file.ino()))
            == Some(running_id)
    };
    if is_running(previous) {
        return Ok(());
    }
    // A planted file at either name goes first.
    if is_running(install) {
        let _ = std::fs::remove_file(previous);
        return std::fs::hard_link(install, previous);
    }
    let part = install.with_file_name(".cmux-tui.prev.part");
    let _ = std::fs::remove_file(&part);
    let mut copy = std::fs::OpenOptions::new().write(true).create_new(true).open(&part)?;
    std::io::copy(&mut &*running, &mut copy)?;
    copy.set_permissions(running.metadata()?.permissions())?;
    drop(copy);
    std::fs::rename(&part, previous)
}

/// Whether `install` is this user's `~/.cmux/bin/cmux-tui`.
fn own_install(install: &Path) -> Result<(), String> {
    let home = std::env::var_os("HOME").ok_or("no HOME")?;
    let expected = PathBuf::from(home).join(".cmux/bin/cmux-tui");
    let canonical =
        |path: &Path| std::fs::canonicalize(path).map_err(|e| format!("{}: {e}", path.display()));
    if canonical(install)? != canonical(&expected)? {
        return Err("the install path is not this user's ~/.cmux/bin/cmux-tui".into());
    }
    Ok(())
}

/// Every check before anything changes; a refusal is its outcome state
/// (`failed`, or the quiet `foreign` and `busy`) and a detail line.
fn check(args: &Args) -> Result<Staged, (&'static str, String)> {
    let failed = |why: String| ("failed", why);
    own_install(&args.install).map_err(failed)?;
    let canonical = |path: &Path| {
        std::fs::canonicalize(path).map_err(|e| failed(format!("{}: {e}", path.display())))
    };
    let own = std::env::current_exe().map_err(|e| failed(e.to_string()))?;
    if own.parent() != canonical(&args.install)?.parent() {
        return Err(failed("the new build is not staged beside the binary".into()));
    }
    // Hash the file through one descriptor, and remember which file it was.
    let mut file = std::fs::File::open(&own).map_err(|e| failed(e.to_string()))?;
    let opened = file.metadata().map_err(|e| failed(e.to_string()))?;
    let mut digest = Sha256::new();
    std::io::copy(&mut file, &mut digest).map_err(|e| failed(e.to_string()))?;
    let sha256: String = digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    if sha256 != args.sha256 {
        return Err(failed("the staged build does not match the pinned checksum".into()));
    }
    let socket = socket().ok_or_else(|| failed("no daemon socket in this terminal".into()))?;
    // The file the daemon runs, even when no path names it any more.
    let daemon = daemon_binary(&socket, args.daemon_pid)?;
    let install = canonical(&args.install)?;
    if !runs_this_install(&daemon.path, &install, Some(daemon.id)) {
        // Someone's own build, run from another path: not this update's to
        // replace, and nothing failed (the Mac shows nothing for it).
        return Err(("foreign", foreign(args.daemon_pid, &daemon.path, &install)));
    }
    // The pid is the daemon serving this terminal's socket now, not a pid
    // reused since the Mac read it. A daemon that restarted since is `busy`:
    // nothing changed, and the next update reads its pid again.
    let identity = super::super::machine_gate::identify(&socket)
        .ok_or_else(|| failed("the daemon socket did not answer".into()))?;
    if identity["pid"].as_i64() != Some(i64::from(args.daemon_pid)) {
        return Err(("busy", RESTARTED.into()));
    }
    Ok(Staged { path: own, dev: opened.dev(), ino: opened.ino(), daemon })
}

/// What a daemon restarted since the Mac read its pid gives (see [`check`]).
const RESTARTED: &str = "the daemon restarted since the update read its pid";

/// The binary of the daemon listening on `socket`, which must be `pid`: the
/// kernel's peer of one connection to it (`SO_PEERCRED`, with the peer's
/// start time), read through that connection's peer authentication
/// (`platform::peer_executable_file`), so a pid reused by another process
/// never answers. No process is enumerated or found by its pid alone. A peer
/// of another pid is a daemon that restarted: `busy`.
fn daemon_binary(socket: &Path, pid: i32) -> Result<DaemonBinary, (&'static str, String)> {
    use cmux_tui_core::platform::transport::Stream as _;
    let stream = std::os::unix::net::UnixStream::connect(socket)
        .map_err(|e| ("failed", format!("cannot reach the daemon socket: {e}")))?;
    let key =
        stream.peer_process_key().ok_or(("failed", "the daemon socket names no peer".into()))?;
    let peer = key
        .strip_prefix("token:")
        .and_then(|rest| rest.split_once('.'))
        .and_then(|(peer, _)| peer.parse::<i32>().ok());
    if peer != Some(pid) {
        return Err(("busy", RESTARTED.into()));
    }
    let unreadable = |why: String| ("failed", format!("cannot read the daemon's binary: {why}"));
    let (path, file) =
        peer_binary(&key).ok_or_else(|| unreadable("its peer key is stale".into()))?;
    let ran = file.metadata().map_err(|e| unreadable(e.to_string()))?;
    drop(stream);
    Ok(DaemonBinary { path, file, id: (ran.dev(), ran.ino()) })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_binary(key: &str) -> Option<(PathBuf, std::fs::File)> {
    cmux_tui_core::platform::peer_executable_file(key)
}

/// A Cloud machine is a Linux machine; elsewhere the step refuses.
#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn peer_binary(_key: &str) -> Option<(PathBuf, std::fs::File)> {
    None
}

/// The detail of a daemon on another binary than this install.
fn foreign(pid: i32, running: &Path, install: &Path) -> String {
    format!(
        "the daemon (pid {pid}) runs {}, not this machine's {}; left as it is",
        running.display(),
        install.display(),
    )
}

/// What the kernel's link to a running binary reads for a deleted file.
const DELETED: &str = " (deleted)";

/// Whether a daemon whose binary's link reads `running` (and whose
/// file is `ran`, its device and inode) runs `install` (canonical) or an
/// earlier copy of it: the same path with the kernel's ` (deleted)` mark (a
/// binary replaced under a running daemon, by an earlier update whose stop
/// did not finish or by another upgrade), `cmux-tui.prev` or the rollback
/// link in the same folder (or either deleted), or the very file now at
/// `cmux-tui.prev`. Anything else, another folder or another name, is not
/// this install's daemon.
fn runs_this_install(running: &Path, install: &Path, ran: Option<(u64, u64)>) -> bool {
    if running == install {
        return true;
    }
    let Some(text) = running.to_str() else { return false };
    let path = Path::new(text.strip_suffix(DELETED).unwrap_or(text));
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else { return false };
    let same_folder = path.parent().is_some() && path.parent() == install.parent();
    if same_folder && matches!(name, "cmux-tui" | "cmux-tui.prev" | ".cmux-tui.rollback") {
        return true;
    }
    let previous = install.with_file_name("cmux-tui.prev");
    ran.zip(std::fs::metadata(previous).ok())
        .is_some_and(|((dev, ino), previous)| previous.dev() == dev && previous.ino() == ino)
}

/// Ends the daemon that was sent SIGTERM: waits `term` for it to exit, then
/// sends SIGKILL and waits `kill` more. True once it is gone.
fn stop(pid: i32, term: Duration, kill: Duration) -> bool {
    if wait(term, || !alive(pid)) {
        return true;
    }
    // SAFETY: as in apply; the pid was checked to serve this machine.
    unsafe { libc::kill(pid, libc::SIGKILL) };
    wait(kill, || !alive(pid))
}

/// The folder's update lock, held while this process lives.
fn lock(install: &Path) -> Option<std::fs::File> {
    lock_at(&install.with_file_name(LOCK_NAME))
}

/// The lock of one update's outcome file `result`, held by the one run of
/// that update while it lives; None while another run of it holds it.
fn claim(result: &Path) -> Option<std::fs::File> {
    lock_at(&claim_path(result))
}

/// `.cmux-tui.update-<nonce>.lock` beside `.cmux-tui.update-<nonce>.json`.
pub(crate) fn claim_path(result: &Path) -> PathBuf {
    result.with_extension("lock")
}

fn lock_at(path: &Path) -> Option<std::fs::File> {
    let file =
        std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(path).ok()?;
    // SAFETY: flock on a descriptor this function owns.
    let locked = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
    locked.then_some(file)
}

/// Puts the previous binary back over the install, atomically.
fn put_back(args: &Args, previous: &Path) -> std::io::Result<()> {
    let back = args.install.with_file_name(".cmux-tui.rollback");
    let _ = std::fs::remove_file(&back);
    std::fs::hard_link(previous, &back)?;
    std::fs::rename(&back, &args.install)
}

/// Puts the previous binary back and waits for a daemon of it to serve.
fn restore(args: &Args, previous: &Path, why: &str) -> (&'static str, String) {
    restore_by(why, || put_back(args, previous), args.daemon_pid)
}

/// Puts the previous build back with `put_back` (the previous binary, or the store link),
/// ends the new daemon and waits for a daemon of the previous build to serve.
fn restore_by(
    why: &str,
    put_back: impl FnOnce() -> std::io::Result<()>,
    old_pid: i32,
) -> (&'static str, String) {
    let restored = put_back();
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
    if serving(|build| build != new_build, old_pid) {
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

/// A file's SHA-256, lowercase hex.
pub(crate) fn file_sha256(path: &Path) -> std::io::Result<String> {
    hashed_file(path).map(|(sha256, _)| sha256)
}

/// A file's SHA-256 and the device and inode of the very file hashed (one descriptor).
fn hashed_file(path: &Path) -> std::io::Result<(String, (u64, u64))> {
    let mut file = std::fs::File::open(path)?;
    let opened = file.metadata()?;
    let mut digest = Sha256::new();
    std::io::copy(&mut file, &mut digest)?;
    let sha256 = digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    Ok((sha256, (opened.dev(), opened.ino())))
}

fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = path.with_extension("json.part");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(&temporary, path)
}

#[cfg(test)]
#[path = "apply_tests.rs"]
mod tests;
