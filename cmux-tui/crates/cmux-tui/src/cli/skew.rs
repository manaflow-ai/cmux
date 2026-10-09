//! Version skew: a CLI at a dead end runs the CLI of the daemon it reached
//! (plans/cmux-next/version-skew.md step 3).
//!
//! A dead end is a command this CLI does not know, or a daemon without a
//! capability the command needs. When the daemon reports another build
//! (`identify`'s `build_id` and `cli_path`, capability `daemon-build-v1`),
//! this process execs that daemon's CLI once with the same arguments. The
//! daemon and its CLI are one binary, so that CLI speaks the daemon's
//! protocol.
//!
//! Every check below must pass, else nothing runs and the caller prints its
//! own error plus [`fix_command`]:
//! - the loop guard [`GUARD_ENV`] is not set (a re-exec'd process never
//!   re-execs again);
//! - the daemon is local: the socket peer has this process's uid and is the
//!   process `identify` names (an SSH or relay forward has another peer);
//!   never for `--machine` (remote) routes;
//! - the path is absolute (never a PATH lookup), a regular file (not a
//!   symlink), inside `<name>.app/Contents/Resources/bin/` of a cmux bundle
//!   (an installed app or a tagged DerivedData product) of the same install
//!   family as this CLI (release apps, or DEV builds), and neither the
//!   file nor any directory from it up to the bundle is writable by group or
//!   other or owned by another user;
//! - on a Team-signed build the target has the same Team ID;
//! - one line on stderr names each re-exec.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use super::GlobalArgs;

/// Set on the re-exec'd process to the build id it was started for.
pub(super) const GUARD_ENV: &str = "CMUX_CLI_REEXEC";

/// The capability that advertises `build_id` and `cli_path`.
const DAEMON_BUILD_CAPABILITY: &str = "daemon-build-v1";

const IDENTIFY_TIMEOUT: Duration = Duration::from_secs(2);

/// What `identify` says about the daemon's build.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct DaemonBuild {
    pub build_id: String,
    pub cli_path: PathBuf,
    pub pid: u32,
}

impl DaemonBuild {
    /// `None` unless the daemon advertises `daemon-build-v1` with a build id,
    /// a CLI path and its pid.
    pub(super) fn from_identity(identity: &Value) -> Option<Self> {
        let advertised = identity["capabilities"]
            .as_array()
            .is_some_and(|values| values.iter().any(|value| value == DAEMON_BUILD_CAPABILITY));
        if !advertised {
            return None;
        }
        Some(Self {
            build_id: identity["build_id"].as_str().filter(|id| !id.is_empty())?.to_owned(),
            cli_path: PathBuf::from(identity["cli_path"].as_str()?),
            pid: u32::try_from(identity["pid"].as_u64()?).ok()?,
        })
    }
}

/// Where the daemon was reached.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Route {
    /// A local Unix socket whose peer has `peer_uid` and pid `peer_pid`
    /// (`None` when the kernel did not say).
    Local { peer_uid: u32, peer_pid: Option<u32> },
}

/// Why a dead end does not re-exec.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum Refusal {
    /// This process was itself started by a re-exec.
    LoopGuard,
    /// The daemon is this build: its CLI would fail the same way.
    SameBuild,
    OtherUser {
        uid: u32,
    },
    /// The socket peer is not the process `identify` names (a forward).
    NotTheDaemon,
    NotAbsolute,
    NotRegularFile,
    NotInCmuxBundle,
    /// This CLI is not in a cmux bundle, or the target is in a bundle of
    /// another install family (a release app and a DEV build).
    OtherInstallFamily,
    Writable(PathBuf),
    OtherOwner(PathBuf),
    TeamId(String),
    Unreadable(String),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LoopGuard => f.write_str("this CLI was already started by a re-exec"),
            Self::SameBuild => f.write_str("the daemon is this build"),
            Self::OtherUser { uid } => write!(f, "the daemon runs as uid {uid}"),
            Self::NotTheDaemon => f.write_str("the socket peer is not the daemon process"),
            Self::NotAbsolute => f.write_str("the daemon's CLI path is not absolute"),
            Self::NotRegularFile => f.write_str("the daemon's CLI is not a regular file"),
            Self::NotInCmuxBundle => {
                f.write_str("the daemon's CLI is not inside a cmux app's Contents/Resources/bin")
            }
            Self::OtherInstallFamily => {
                f.write_str("the daemon's CLI belongs to another cmux install family")
            }
            Self::Writable(path) => write!(f, "{} is writable by group or other", path.display()),
            Self::OtherOwner(path) => write!(f, "{} belongs to another user", path.display()),
            Self::TeamId(why) => {
                write!(f, "the daemon's CLI is not signed by this build's team: {why}")
            }
            Self::Unreadable(why) => write!(f, "the daemon's CLI cannot be checked: {why}"),
        }
    }
}

/// This process's side of the decision.
pub(super) struct Own<'a> {
    pub build_id: &'a str,
    /// This CLI's own (canonical) executable.
    pub exe: &'a Path,
    pub uid: u32,
    /// The value of [`GUARD_ENV`], if set.
    pub guard: Option<&'a str>,
    /// Checks the target's code signature against this build's team.
    pub team: &'a dyn Fn(&Path) -> Result<(), String>,
}

/// The daemon's CLI to exec, or why not.
pub(super) fn vet(daemon: &DaemonBuild, route: Route, own: &Own<'_>) -> Result<PathBuf, Refusal> {
    if own.guard.is_some() {
        return Err(Refusal::LoopGuard);
    }
    let Route::Local { peer_uid, peer_pid } = route;
    if peer_uid != own.uid {
        return Err(Refusal::OtherUser { uid: peer_uid });
    }
    if peer_pid != Some(daemon.pid) {
        return Err(Refusal::NotTheDaemon);
    }
    if daemon.build_id == own.build_id {
        return Err(Refusal::SameBuild);
    }
    let path = &daemon.cli_path;
    if !path.is_absolute() {
        return Err(Refusal::NotAbsolute);
    }
    let metadata =
        std::fs::symlink_metadata(path).map_err(|error| Refusal::Unreadable(error.to_string()))?;
    if !metadata.file_type().is_file() {
        return Err(Refusal::NotRegularFile);
    }
    let bundle = cmux_bundle_of(path).ok_or(Refusal::NotInCmuxBundle)?;
    let own_bundle = cmux_bundle_of(own.exe).ok_or(Refusal::OtherInstallFamily)?;
    if install_family(&own_bundle) != install_family(&bundle) {
        return Err(Refusal::OtherInstallFamily);
    }
    for checked in path.ancestors().take_while(|ancestor| ancestor.starts_with(&bundle)) {
        let metadata = std::fs::symlink_metadata(checked)
            .map_err(|error| Refusal::Unreadable(error.to_string()))?;
        if metadata.file_type().is_symlink() {
            return Err(Refusal::NotRegularFile);
        }
        if metadata.permissions().mode() & 0o022 != 0 {
            return Err(Refusal::Writable(checked.to_path_buf()));
        }
        if metadata.uid() != own.uid && metadata.uid() != 0 {
            return Err(Refusal::OtherOwner(checked.to_path_buf()));
        }
    }
    (own.team)(path).map_err(Refusal::TeamId)?;
    Ok(path.clone())
}

/// The `<name>.app` bundle when `path` is `<name>.app/Contents/Resources/bin/<file>`
/// and the bundle's name starts with `cmux` (cmux, cmux NIGHTLY, cmux DEV <tag>).
fn cmux_bundle_of(path: &Path) -> Option<PathBuf> {
    let bin = path.parent()?;
    let resources = bin.parent()?;
    let contents = resources.parent()?;
    let bundle = contents.parent()?;
    let named = |dir: &Path, name: &str| dir.file_name().is_some_and(|value| value == name);
    let is_cmux_app = bundle
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("cmux") && name.ends_with(".app"));
    (named(bin, "bin")
        && named(resources, "Resources")
        && named(contents, "Contents")
        && is_cmux_app)
        .then(|| bundle.to_path_buf())
}

/// `true` for a tagged DEV build (`cmux DEV <tag>.app`, in DerivedData or
/// installed), `false` for a release channel app (cmux, NIGHTLY, RC, ...).
fn install_family(bundle: &Path) -> bool {
    bundle
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.starts_with("cmux DEV"))
}

/// The stderr line for one re-exec.
pub(super) fn reexec_line(daemon: &DaemonBuild, own_build: &str) -> String {
    format!(
        "cmux: this CLI (build {own_build}) does not match the daemon (build {}); running the daemon's CLI {}",
        daemon.build_id,
        daemon.cli_path.display()
    )
}

/// The one command that fixes a skew this CLI cannot resolve itself: stop
/// the daemon (its terminals survive the handoff) and start it with this
/// CLI's binary.
pub(super) fn fix_command(own_exe: &Path, socket: &Path) -> String {
    let exe = shell_quote(&own_exe.to_string_lossy());
    let socket = shell_quote(&socket.to_string_lossy());
    format!("{exe} daemon stop --socket {socket} && {exe} daemon ensure --socket {socket}")
}

fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// The daemon `global` routes to, its build, and how it was reached; `None`
/// when no local daemon answers (nothing is started) and always for a
/// `--machine` (remote) route, which is never probed. SSH, relay and Cloud
/// forwards that end in a local socket fail the peer pid check in [`vet`].
fn probe(global: &GlobalArgs) -> Option<(PathBuf, DaemonBuild, Route)> {
    if global.machine.is_some() {
        return None;
    }
    let (socket, _) = super::wire::resolve_socket_with_origin(global).ok()?;
    probe_socket(socket)
}

fn probe_socket(socket: PathBuf) -> Option<(PathBuf, DaemonBuild, Route)> {
    let stream = UnixStream::connect(&socket).ok()?;
    let peer_uid = cmux_tui_core::platform::unix_peer_uid(&stream).ok()?;
    let peer_pid = cmux_tui_core::platform::transport::Stream::peer_process_key(&stream)
        .and_then(|key| key.strip_prefix("token:")?.split('.').next()?.parse().ok());
    let _ = stream.set_read_timeout(Some(IDENTIFY_TIMEOUT));
    let _ = stream.set_write_timeout(Some(IDENTIFY_TIMEOUT));
    let mut writer = stream.try_clone().ok()?;
    let request = json!({"id":"cli-skew","cmd":"identify"});
    writer.write_all(format!("{request}\n").as_bytes()).ok()?;
    // One identify reply; a daemon that sends more is cut off.
    let mut line = String::new();
    let read =
        BufReader::new(std::io::Read::take(stream, 1024 * 1024)).read_line(&mut line).ok()?;
    if read == 0 {
        return None;
    }
    let response: Value = serde_json::from_str(&line).ok()?;
    if response["id"] != "cli-skew" || response["ok"] != true {
        return None;
    }
    let daemon = DaemonBuild::from_identity(&response["data"])?;
    Some((socket, daemon, Route::Local { peer_uid, peer_pid }))
}

fn own_build_id() -> &'static str {
    cmux_remote::ssh_bootstrap::BUILD_IDENTITY
}

fn team_check(path: &Path) -> Result<(), String> {
    cmux_link::app_caller::same_team_as_this_build(path).map(|_| ())
}

/// At a dead end: exec the daemon's CLI with this process's own arguments
/// (never returns on success). `Err` carries the line to add to the
/// caller's error, or `None` when no daemon of another build answers.
pub(super) fn reexec_at_dead_end(
    global: &GlobalArgs,
) -> Result<std::convert::Infallible, Option<String>> {
    reexec_with(probe(global))
}

/// [`reexec_at_dead_end`] for a daemon socket the caller resolved itself
/// (the Chief's home daemon).
pub(super) fn reexec_at_dead_end_on(
    socket: &Path,
) -> Result<std::convert::Infallible, Option<String>> {
    reexec_with(probe_socket(socket.to_path_buf()))
}

fn reexec_with(
    probed: Option<(PathBuf, DaemonBuild, Route)>,
) -> Result<std::convert::Infallible, Option<String>> {
    let Some((socket, daemon, route)) = probed else {
        return Err(None);
    };
    let guard = std::env::var(GUARD_ENV).ok();
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let exe = std::env::current_exe().and_then(std::fs::canonicalize).unwrap_or_default();
    let own = Own {
        build_id: own_build_id(),
        exe: &exe,
        uid,
        guard: guard.as_deref(),
        team: &team_check,
    };
    let path = match vet(&daemon, route, &own) {
        Ok(path) => path,
        Err(Refusal::SameBuild | Refusal::LoopGuard) => return Err(None),
        Err(refusal) => {
            return Err(Some(format!(
                "cmux: the daemon runs build {} and its CLI cannot be used ({refusal}); fix: {}",
                daemon.build_id,
                fix_command(&exe, &socket)
            )));
        }
    };
    eprintln!("{}", reexec_line(&daemon, own.build_id));
    use std::os::unix::process::CommandExt;
    let error = std::process::Command::new(&path)
        .args(std::env::args_os().skip(1))
        .env(GUARD_ENV, &daemon.build_id)
        .exec();
    Err(Some(format!("cmux: could not run {}: {error}", path.display())))
}

#[cfg(test)]
#[path = "skew/tests.rs"]
mod tests;
