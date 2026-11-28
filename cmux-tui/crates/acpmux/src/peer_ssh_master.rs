//! One ssh login per host, kept across daemon restarts.
//!
//! Every ssh a peer runs (the `-W` tunnel of its link, the token read, a path probe) shares one
//! master connection per host: acpmux names the ControlPath itself, under its own home
//! (`<home>/run/ssh/<key>`), with `ControlMaster=auto` and `ControlPersist`. The first ssh to a
//! host logs in and becomes the master (ssh backgrounds it once authenticated; the foreground
//! process that acpmux owns is a mux client from then on, so ending it ends only its channel);
//! every later one is a mux client over it: no TCP connect, no key exchange, no auth.
//!
//! The key is a hash of the ssh destination alone, so it is the same in the next run: a daemon
//! that restarts (an update, a handoff, a crash) finds the masters of the one before it alive for
//! `CONTROL_PERSIST_SECS` and dials every peer with no login at all. A tagged dev build has its own
//! home, so its own masters.
//!
//! Before, a first connect was two logins (the tunnel and the token read beside it), and every
//! connect after a restart logged in again, unless the person's own ssh config happened to
//! multiplex that host. Options on the command line win over the config's, so a host the config
//! already multiplexes moves to acpmux's socket, with acpmux's persistence.
//!
//! A home too long for a unix socket's path gets no options: the ssh config decides, as before.

use super::Peer;
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::fs::TryLockError;
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long a master outlives its last channel: long enough for a daemon restart or update
/// (seconds to a minute or two) to find it, and for a link that drops and redials.
pub(crate) const CONTROL_PERSIST_SECS: u64 = 600;

/// The longest ControlPath acpmux hands ssh: a macOS `sun_path` holds 104 bytes with its NUL,
/// and ssh binds a temporary name 17 bytes longer before it renames it into place.
const SOCKET_PATH_MAX: usize = 104 - 1 - 17;

/// While another SSH login starts, check for its control socket without spawning more SSH clients.
const MASTER_POLL: Duration = Duration::from_millis(25);

/// The ssh program and where its masters' sockets live.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SshMux {
    pub(crate) program: OsString,
    /// None: no master options (the ssh config decides).
    pub(crate) dir: Option<PathBuf>,
}

impl SshMux {
    /// The daemon's: `ssh`, its masters under `<home>/run/ssh`.
    pub(crate) fn for_home(home: &Path) -> Self {
        Self { program: "ssh".into(), dir: Some(home.join("run").join("ssh")) }
    }

    /// The socket of `destination`'s master; None when the path would not fit a socket.
    pub(crate) fn control_path(&self, destination: &str) -> Option<PathBuf> {
        let path = self.dir.as_ref()?.join(key(destination));
        (path.as_os_str().len() <= SOCKET_PATH_MAX).then_some(path)
    }
}

/// A short stable name for a destination: the same in every run, never an ssh `%` token.
pub(crate) fn key(destination: &str) -> String {
    let digest = Sha256::digest(destination.as_bytes());
    digest.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// The master options for `path`, with its directory made private (0700); None when the
/// directory cannot be made.
///
/// They carry the tunnel's keepalive (`tunnel_argv`): the master's connection takes the options
/// of whichever ssh logged in, and a token read that runs before the tunnel (a redial after the
/// remote restarted) becomes the master. Without them that master never probes its connection,
/// so after a network change it stays up, dead, and every mux client of it hangs. A mux client
/// ignores them: its channel rides the master's connection.
pub(crate) fn options(path: &Path) -> Option<[String; 10]> {
    let dir = path.parent()?;
    crate::home_fs::private_dir(dir).ok()?;
    // ssh expands `%` and `~` in ControlPath: a literal `%` is written `%%`.
    let path = path.to_str()?.replace('%', "%%");
    Some([
        "-o".into(),
        "ControlMaster=auto".into(),
        "-S".into(),
        path,
        "-o".into(),
        format!("ControlPersist={CONTROL_PERSIST_SECS}"),
        "-o".into(),
        format!("ServerAliveInterval={}", crate::peer::SSH_ALIVE_INTERVAL_SECS),
        "-o".into(),
        format!("ServerAliveCountMax={}", crate::peer::SSH_ALIVE_COUNT_MAX),
    ])
}

// test-hook-allow: keyed by peer name and never cleared: each test registers its own peer
// names (peer_ssh_master_tests.rs), so no test can replace or clear another's entry
#[cfg(test)]
static OVERRIDES: std::sync::Mutex<Option<std::collections::HashMap<String, SshMux>>> =
    std::sync::Mutex::new(None);

/// A test's ssh program and socket directory for the peer named `peer` (never PATH, which
/// every test shares).
#[cfg(test)]
pub(crate) fn override_for_tests(peer: &str, mux: SshMux) {
    let mut overrides = OVERRIDES.lock().unwrap_or_else(|e| e.into_inner());
    overrides.get_or_insert_with(Default::default).insert(peer.to_owned(), mux);
}

impl Peer {
    /// This peer's ssh program and socket directory.
    pub(in crate::peer) fn ssh_mux(&self) -> SshMux {
        #[cfg(test)]
        {
            // A test that set none runs no master options: no socket under a real home.
            let overrides = OVERRIDES.lock().unwrap_or_else(|e| e.into_inner());
            overrides
                .as_ref()
                .and_then(|o| o.get(&self.name))
                .cloned()
                .unwrap_or(SshMux { program: "ssh".into(), dir: None })
        }
        #[cfg(not(test))]
        SshMux::for_home(&crate::config::home())
    }

    /// The socket of this peer's host's master, when it has one.
    pub(in crate::peer) fn master_path(&self) -> Option<PathBuf> {
        let (destination, _) = self.ssh_parts()?;
        self.ssh_mux().control_path(&destination)
    }

    /// `ssh` with this host's master options, when they fit.
    pub(in crate::peer) fn ssh_with_master(&self) -> tokio::process::Command {
        let mux = self.ssh_mux();
        let mut ssh = tokio::process::Command::new(&mux.program);
        if let Some((destination, _)) = self.ssh_parts()
            && let Some(path) = mux.control_path(&destination)
            && let Some(options) = options(&path)
        {
            ssh.args(options);
        }
        ssh
    }

    /// Spawns one of this peer's ssh hops: under its host's cap, recorded beside the masters'
    /// sockets (`<home>/run/ssh-hops`) until it exits, so a daemon that goes without dropping it
    /// leaves nothing the next one cannot end (`ssh_hops.rs`).
    pub(in crate::peer) fn spawn_hop(
        &self,
        spawn: impl FnOnce() -> io::Result<tokio::process::Child>,
    ) -> io::Result<tokio::process::Child> {
        let host = self.ssh_parts().map(|(destination, _)| destination).unwrap_or_default();
        let ledger =
            self.ssh_mux().dir.as_deref().and_then(Path::parent).map(|run| run.join("ssh-hops"));
        crate::ssh_hops::spawn(spawn, &host, ledger.as_deref())
    }

    /// The first SSH process establishes the shared transport. A per-socket advisory lock
    /// also covers a second daemon starting during handoff. The lock is released on exit
    /// or cancellation, and a warm multiplexed channel only needs a socket existence check.
    pub(in crate::peer) async fn begin_ssh_login(
        &self,
        command: &tokio::process::Command,
    ) -> io::Result<Option<MasterLogin>> {
        // ssh_with_master adds -S only if the path can be used by OpenSSH.
        let path =
            self.master_path().filter(|_| command.as_std().get_args().any(|arg| arg == "-S"));
        let Some(path) = path.filter(|path| !path.exists()) else {
            return Ok(None);
        };
        let lock = match crate::home_fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path.with_extension("lock"))
        {
            Ok(lock) => lock,
            Err(_) => return Ok(None), // Preserve ordinary SSH when locking is unavailable.
        };
        let mut stopped = self.stopped();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(self.ssh_connect_secs());
        loop {
            if *stopped.borrow() {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "peer stopped"));
            }
            if path.exists() {
                return Ok(None);
            }
            match lock.try_lock() {
                Ok(()) => return Ok(Some(MasterLogin { path, _lock: lock })),
                Err(TryLockError::WouldBlock) if tokio::time::Instant::now() < deadline => {}
                Err(TryLockError::WouldBlock) => {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "waiting for peer SSH master to log in",
                    ));
                }
                Err(TryLockError::Error(_)) => return Ok(None),
            }
            tokio::select! {
                _ = stopped.changed() => {}
                () = tokio::time::sleep(MASTER_POLL) => {}
            }
        }
    }
}

/// Owns the first channel's login until the control socket is ready for other channels.
pub(in crate::peer) struct MasterLogin {
    path: PathBuf,
    _lock: std::fs::File,
}

impl MasterLogin {
    pub(in crate::peer) async fn wait(
        self,
        peer: &Peer,
        child: &mut tokio::process::Child,
    ) -> io::Result<()> {
        let mut stopped = peer.stopped();
        // OpenSSH publishes the socket after authentication. On failure, pass the child's
        // status and stderr back to the caller immediately. Keep the lock bounded even if
        // a proxy command never produces a socket.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(peer.ssh_connect_secs());
        while !self.path.exists() && tokio::time::Instant::now() < deadline {
            tokio::select! {
                status = child.wait() => return status.map(|_| ()),
                _ = stopped.wait_for(|stopped| *stopped) => {
                    return Err(io::Error::new(io::ErrorKind::Interrupted, "peer stopped"));
                }
                () = tokio::time::sleep(MASTER_POLL) => {}
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "peer_ssh_master_tests.rs"]
mod tests;
