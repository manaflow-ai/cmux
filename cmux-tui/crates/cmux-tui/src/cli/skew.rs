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
//! own error plus the daemon's CLI with the same arguments
//! ([`run_with_daemon_cli`]; never a daemon stop, which ends the user's
//! terminals):
//! - the loop guard [`GUARD_ENV`] is not set (a re-exec'd process never
//!   re-execs again);
//! - the daemon is local: the socket peer has this process's uid and is the
//!   process `identify` names (an SSH or relay forward has another peer);
//!   never for `--machine` (remote) routes; a tunnel socket to another
//!   machine's daemon gets that daemon's build and, for an SSH route, the
//!   exact `cmux remote ssh … --upgrade` command instead (cx-ytw1);
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
use super::fix_command::run_with_daemon_cli;

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
        let m = &crate::localization::catalog().skew;
        let text = match self {
            Self::LoopGuard => m.loop_guard.to_owned(),
            Self::SameBuild => m.same_build.to_owned(),
            Self::OtherUser { uid } => m.other_user.replace("{uid}", &uid.to_string()),
            Self::NotTheDaemon => m.not_the_daemon.to_owned(),
            Self::NotAbsolute => m.not_absolute.to_owned(),
            Self::NotRegularFile => m.not_regular_file.to_owned(),
            Self::NotInCmuxBundle => m.not_in_cmux_bundle.to_owned(),
            Self::OtherInstallFamily => m.other_install_family.to_owned(),
            Self::Writable(path) => m.writable.replace("{path}", &path.display().to_string()),
            Self::OtherOwner(path) => m.other_owner.replace("{path}", &path.display().to_string()),
            Self::TeamId(why) => m.team_id.replace("{why}", why),
            Self::Unreadable(why) => m.unreadable.replace("{why}", why),
        };
        f.write_str(&text)
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
    let metadata = cmux_blocking::fs::symlink_metadata(path)
        .map_err(|error| Refusal::Unreadable(error.to_string()))?;
    if !metadata.file_type().is_file() {
        return Err(Refusal::NotRegularFile);
    }
    let bundle = cmux_bundle_of(path).ok_or(Refusal::NotInCmuxBundle)?;
    let own_bundle = cmux_bundle_of(own.exe).ok_or(Refusal::OtherInstallFamily)?;
    if install_family(&own_bundle) != install_family(&bundle) {
        return Err(Refusal::OtherInstallFamily);
    }
    for checked in path.ancestors().take_while(|ancestor| ancestor.starts_with(&bundle)) {
        let metadata = cmux_blocking::fs::symlink_metadata(checked)
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
    crate::localization::catalog()
        .skew
        .reexec
        .replace("{own}", own_build)
        .replace("{daemon}", &daemon.build_id)
        .replace("{cli}", &daemon.cli_path.display().to_string())
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

/// The line for a daemon of another build behind a tunnel socket.
fn remote_skew(daemon: &DaemonBuild, own_build: &str, socket: &Path) -> String {
    let m = &crate::localization::catalog().skew;
    let text = match tunnel_ssh_destination(socket) {
        Some(destination) => {
            m.remote_build.replace("{fix}", &format!("cmux remote ssh {destination} --upgrade"))
        }
        None => m.remote_build_no_ssh.to_owned(),
    };
    text.replace("{daemon}", &daemon.build_id).replace("{own}", own_build)
}

/// `[USER@]HOST[:PORT]` of the SSH route the client runtime recorded next to
/// `socket` (`remote_runtime::tunnel_route_record`). The record must be this
/// user's and writable by nobody else, and the destination one plain word
/// (no option, path, query or space), since it is printed as a command.
fn tunnel_ssh_destination(socket: &Path) -> Option<String> {
    let record = crate::remote_runtime::tunnel_route_record(socket);
    let metadata = cmux_blocking::fs::symlink_metadata(&record).ok()?;
    let uid = cmux_tui_core::platform::effective_uid();
    if !metadata.file_type().is_file() || metadata.uid() != uid || metadata.mode() & 0o022 != 0 {
        return None;
    }
    let route = cmux_blocking::fs::read_to_string(&record).ok()?;
    let destination = route.trim().strip_prefix("ssh://")?;
    let plain = !destination.is_empty()
        && !destination.starts_with('-')
        && destination.len() <= 255
        && destination.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '@' | ':' | '[' | ']')
        });
    plain.then(|| destination.to_owned())
}

fn own_build_id() -> &'static str {
    cmux_build_identity::BUILD_IDENTITY
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
    let uid = cmux_tui_core::platform::effective_uid();
    let exe = std::env::current_exe().and_then(cmux_blocking::fs::canonicalize).unwrap_or_default();
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
        // The socket tunnels to a daemon on another machine (`cmux remote
        // ssh`): its CLI is a remote path, never run. Name its build and,
        // for an SSH route, the exact upgrade command (cx-ytw1).
        Err(Refusal::NotTheDaemon) if daemon.build_id == own.build_id => return Err(None),
        Err(Refusal::NotTheDaemon) => {
            return Err(Some(remote_skew(&daemon, own.build_id, &socket)));
        }
        Err(refusal) => {
            return Err(Some(
                crate::localization::catalog()
                    .skew
                    .refused
                    .replace("{daemon}", &daemon.build_id)
                    .replace("{why}", &refusal.to_string())
                    .replace(
                        "{fix}",
                        &run_with_daemon_cli(&daemon.cli_path, std::env::args_os().skip(1)),
                    ),
            ));
        }
    };
    eprintln!("{}", reexec_line(&daemon, own.build_id));
    let error = cmux_process::Command::new(&path)
        .args(std::env::args_os().skip(1))
        .env(GUARD_ENV, &daemon.build_id)
        .exec();
    Err(Some(
        crate::localization::catalog()
            .skew
            .could_not_run
            .replace("{path}", &path.display().to_string())
            .replace("{error}", &error.to_string()),
    ))
}
