//! The share host (cmuxterm-hq docs/design/remote-screen-share-zero-touch.md, Z1, Z2, Z5): on a
//! joined Mac the daemon, which launchd keeps alive with the app closed, is this Mac's one device
//! hub device and serves screen shares with no app running.
//!
//! - Identity: a software P-256 device in `<acpmux home>/share-host/` (0700, its files 0600),
//!   beside the machine credential it signs in with (`POST /v1/auth/machine`), registered as
//!   platform `macos` with `shareByJoin` from the join.
//! - The link ([`link`]): the User DO socket, held as `cmux-rd linux-host` holds it; each host
//!   ticket is routed once ([`route`]): the daemon serves a Mac viewer through a session process,
//!   the app serves an iPhone viewer, and every push reaches the app's device channel with
//!   `servedBy` on host tickets.
//! - A session process per share ([`session`], `acpmux share-host session`): its own session
//!   (`setsid`), so it outlives a daemon handoff; its record under `sessions/` lets the next
//!   daemon adopt it.
//! - The app's device channel ([`channel`], `device.sock`): the JSON lines cmux Remote's worker
//!   speaks, so the app signs and opens with this same device.
//!
//! A machine that is not joined, or whose join record was copied from another box, runs none of
//! it: no socket, no process.
//!
//! On a joined Linux machine the host is cmux-rd's (`cmux-rd linux-host`), which the daemon sets
//! up at its start ([`linux`]); `share-host status` says how that went.

pub(crate) mod cli;

pub use cli::{OffHere, share_off_here};

#[cfg(unix)]
pub(crate) mod approval;
#[cfg(unix)]
mod channel;
#[cfg(unix)]
mod helper;
#[cfg(unix)]
mod link;
#[cfg(unix)]
pub(crate) mod linux;
#[cfg(unix)]
mod records;
#[cfg(unix)]
mod route;
#[cfg(unix)]
mod session;
#[cfg(unix)]
mod state;
#[cfg(unix)]
mod verbs;

#[cfg(all(test, unix))]
mod tests;

#[cfg(unix)]
use std::path::{Path, PathBuf};

/// The folder under the acpmux home that holds the device, the session records and the app's
/// device channel.
#[cfg(unix)]
pub(crate) const DIR: &str = "share-host";
/// The app's device channel in [`DIR`].
#[cfg(unix)]
pub(crate) const SOCKET: &str = "device.sock";
/// The prefix of this host's log lines.
#[cfg(unix)]
pub(crate) const LOG: &str = "share-host";

#[cfg(unix)]
pub(crate) fn dir(home: &Path) -> PathBuf {
    home.join(DIR)
}

/// The device hub of the cmux-platform deployment a machine credential was joined at
/// (`MachineCredential::hub_origin` is the platform's origin, not the device hub's): each
/// deployment's own, from the table cmux-rd reads too (`cmux_hub_host::deployment`), so the
/// daemon and the host it sets up pick the same hub for a credential. None for an origin no
/// deployment has.
#[cfg(unix)]
pub(crate) fn device_hub_origin(platform_origin: &str) -> Option<String> {
    cmux_hub_host::deployment::device_hub_of(platform_origin).map(str::to_owned)
}

/// This machine's join as the share host reads it.
#[cfg(unix)]
pub(crate) enum Join {
    /// Joined here: its credential.
    Joined(Box<crate::machine_record::MachineCredential>),
    /// No join record.
    NotJoined,
    /// The record was copied here from another box: its credential is never used here.
    Cloned,
    /// The hub revoked this machine.
    Revoked,
}

#[cfg(unix)]
pub(crate) fn join() -> Join {
    match crate::machine_record::load() {
        Ok(Some(record)) if record.revoked => Join::Revoked,
        Ok(Some(_)) => match crate::machine_record::machine_credential() {
            Ok(Some(credential)) => Join::Joined(Box::new(credential)),
            Ok(None) | Err(_) => Join::Cloned,
        },
        Ok(None) | Err(_) => Join::NotJoined,
    }
}

/// This machine's credential and the device hub of its deployment, when it is joined here (not
/// copied from another box, not revoked).
#[cfg(unix)]
pub(crate) fn joined() -> Result<(Box<crate::machine_record::MachineCredential>, String), NotRunning>
{
    let credential = match join() {
        Join::Joined(credential) => credential,
        Join::NotJoined => return Err(NotRunning::new("not_joined", "this machine is not joined")),
        Join::Cloned => {
            return Err(NotRunning::new(
                "cloned",
                "this machine's join record was copied from another box; join it again here",
            ));
        }
        Join::Revoked => return Err(NotRunning::new("revoked", "the hub revoked this machine")),
    };
    let Some(origin) = device_hub_origin(&credential.hub_origin) else {
        return Err(NotRunning::new(
            "no_device_hub",
            &format!("no device hub serves {}", cmux_hub_host::printable(&credential.hub_origin)),
        ));
    };
    Ok((credential, origin))
}

/// The hub client a share-host process signs in with: this Mac's device and the machine
/// credential, at the device hub of the credential's deployment. The device is made (and saved)
/// when `create` and there is none yet.
#[cfg(unix)]
pub(crate) fn machine_hub(
    home: &Path,
    create: bool,
) -> Result<cmux_hub_host::hub::Hub, NotRunning> {
    use cmux_hub_host::hub::{Hub, Renewal};
    use cmux_hub_host::identity::{self, Device};
    let (credential, origin) = joined()?;
    let folder = dir(home);
    let failed = |e: Box<dyn std::error::Error + Send + Sync>| {
        NotRunning::new("identity_unreadable", &format!("{}: {e}", folder.display()))
    };
    identity::private_dir(&folder).map_err(failed)?;
    let device = match Device::load(&folder).map_err(failed)? {
        Some(device) => device,
        None if create => {
            let device = Device::generate(&computer_name()).map_err(failed)?;
            device.save(&folder).map_err(failed)?;
            device
        }
        None => {
            return Err(NotRunning::new(
                "not_registered",
                "the daemon has not made this Mac's device yet",
            ));
        }
    };
    let renewal = Renewal::Machine { credential: credential.credential };
    Hub::with_renewal(&origin, device, None, renewal).map_err(failed)
}

/// Why the share host does not run: a code and one line for a person.
#[cfg(unix)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct NotRunning {
    pub code: &'static str,
    pub detail: String,
}

#[cfg(unix)]
impl NotRunning {
    pub(crate) fn new(code: &'static str, detail: &str) -> Self {
        Self { code, detail: detail.to_owned() }
    }
}

#[cfg(unix)]
impl std::fmt::Display for NotRunning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.detail)
    }
}

#[cfg(unix)]
impl std::error::Error for NotRunning {}

/// This Mac's name for a new device: its ComputerName (what Sharing settings shows), else the
/// host name.
#[cfg(unix)]
fn computer_name() -> String {
    #[cfg(target_os = "macos")]
    {
        let name = cmux_process::Command::new("/usr/sbin/scutil")
            .args(["--get", "ComputerName"])
            .stdin(cmux_process::Stdio::null())
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_owned())
            .filter(|name| !name.is_empty());
        if let Some(name) = name {
            return name;
        }
    }
    let mut buffer = [0_u8; 256];
    // SAFETY: gethostname writes at most `buffer.len()` bytes into the live buffer.
    let ok = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0;
    let end = buffer.iter().position(|b| *b == 0).unwrap_or(buffer.len());
    let name = buffer.get(..end).map(String::from_utf8_lossy).unwrap_or_default();
    if ok && !name.trim().is_empty() { name.trim().to_owned() } else { "Mac".to_owned() }
}

/// Starts the share host with the daemon, as tasks of `scope` (the hub's), so it ends with the
/// daemon: the app's device channel and the hub link on its own thread (the hub client is
/// blocking). Session processes are left running when the daemon stops: the next daemon adopts
/// them, and with no daemon the hub ends them after its offline grace.
#[cfg(unix)]
#[cfg_attr(
    not(target_os = "macos"),
    allow(
        dead_code,
        reason = "the daemon starts it on macOS; elsewhere it is compiled and tested"
    )
)]
pub(crate) fn start(scope: &cmux_scope::Scope) {
    let home = crate::config::home();
    let hub = match machine_hub(&home, true) {
        Ok(hub) => hub,
        Err(why) => {
            tracing::info!("{LOG}: not running: {why}");
            state::not_running(why);
            return;
        }
    };
    let shared = state::Shared::install(home.clone(), hub);
    scope.spawn_until_cancelled(
        "share-host-device-channel",
        channel::serve(shared.clone(), dir(&home).join(SOCKET)),
    );
    let token = scope.token();
    scope.spawn_named("share-host-link", async move {
        let (done, ended) = tokio::sync::oneshot::channel::<()>();
        let spawned = std::thread::Builder::new().name("share-host-link".into()).spawn(move || {
            link::run(&shared, &token);
            let _ = done.send(());
        });
        match spawned {
            Ok(_) => {
                let _ = ended.await;
            }
            Err(e) => tracing::warn!("{LOG}: the hub link did not start: {e}"),
        }
    });
}

/// What the device hub says of machine `host`'s screen (`peers`' `deviceHub` on a row only the
/// mesh hub reaches): read from the running share host's device list; None when no share host
/// runs here or it has not read the list yet.
pub(crate) fn device_hub_of(host: &str) -> Option<serde_json::Value> {
    #[cfg(unix)]
    {
        state::device_hub_of(host)
    }
    #[cfg(not(unix))]
    {
        let _ = host;
        None
    }
}

/// `_acpmux/share_host_status`: what `acpmux share-host status` prints.
pub(crate) fn status_now() -> serde_json::Value {
    #[cfg(unix)]
    {
        state::status_now()
    }
    #[cfg(not(unix))]
    {
        serde_json::json!({"schema": "acpmux.share-host.status/1", "running": false,
            "state": "unsupported", "detail": "the share host runs on macOS and Linux"})
    }
}
