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
use crate::protocol::peer_state::DialFail;
use sha2::{Digest, Sha256};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// How long a master outlives its last channel: long enough for a daemon restart or update
/// (seconds to a minute or two) to find it, and for a link that drops and redials.
pub(crate) const CONTROL_PERSIST_SECS: u64 = 600;

/// The longest ControlPath acpmux hands ssh: a macOS `sun_path` holds 104 bytes with its NUL,
/// and ssh binds a temporary name 17 bytes longer before it renames it into place.
const SOCKET_PATH_MAX: usize = 104 - 1 - 17;

/// How often a token read that waits for the tunnel's master looks for its socket.
const MASTER_POLL: Duration = Duration::from_millis(25);

/// How long `ssh -O exit` may take to drop a master that stopped answering.
const EXIT_FOR: Duration = Duration::from_secs(2);

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
pub(crate) fn options(path: &Path) -> Option<[String; 6]> {
    let dir = path.parent()?;
    private_dir(dir).ok()?;
    // ssh expands `%` and `~` in ControlPath: a literal `%` is written `%%`.
    let path = path.to_str()?.replace('%', "%%");
    Some([
        "-o".into(),
        "ControlMaster=auto".into(),
        "-o".into(),
        format!("ControlPath={path}"),
        "-o".into(),
        format!("ControlPersist={CONTROL_PERSIST_SECS}"),
    ])
}

fn private_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        let meta = std::fs::metadata(dir)?;
        if meta.permissions().mode() & 0o077 != 0 {
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(dir)
    }
}

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

    /// The tokens for a connect (`connect_tokens`). With `tunnel_logging_in` (a first connect's
    /// tunnel started beside the read, `peer_carriers.rs`), a read that goes over ssh waits,
    /// up to ssh's connect timeout, for that tunnel's login to leave its master, and rides it:
    /// one login for the host, not two. Past the wait it runs anyway, with a login of its own.
    pub(in crate::peer) async fn connect_tokens_after(
        &self,
        tunnel_logging_in: bool,
    ) -> Result<(crate::peer::tokens::Tokens, bool), String> {
        let reads =
            (self.token.is_none() || self.peer_token.is_none()) && self.read_tokens.get().is_none();
        if tunnel_logging_in
            && reads
            && let Some(path) = self.master_path()
        {
            self.wait_for_master(&path, Duration::from_secs(self.ssh_connect_secs())).await;
        }
        self.connect_tokens().await
    }

    /// Until `path` (a master's socket) exists, the tunnel that would make it ends, the peer
    /// stops, or `within` passes. No process: the socket file is looked for.
    async fn wait_for_master(&self, path: &Path, within: Duration) {
        let deadline = tokio::time::Instant::now() + within;
        let mut stopped = self.stop_changed.subscribe();
        while !path.exists() && tokio::time::Instant::now() < deadline {
            if self.tunnel.try_lock().is_ok_and(|tunnel| tunnel.is_none()) {
                return;
            }
            tokio::select! {
                _ = stopped.wait_for(|stopped| *stopped) => return,
                () = tokio::time::sleep(MASTER_POLL) => {}
            }
        }
    }

    /// `note_ssh_failure`, and a master that let an attempt time out with no word from ssh
    /// (a network that changed under it, a machine that paused) is dropped (`ssh -O exit`, no
    /// login), so the next attempt logs in again instead of waiting on it until its keepalives
    /// give up.
    pub(in crate::peer) async fn note_ssh_failure_over_master(
        &self,
        reason: Option<&str>,
        fail: Option<DialFail>,
    ) {
        self.note_ssh_failure(reason);
        if reason.is_none() && fail == Some(DialFail::Timeout) {
            self.drop_master().await;
        }
    }

    /// Ends this host's master, when there is one, within `EXIT_FOR`.
    pub(in crate::peer) async fn drop_master(&self) {
        let (Some(path), Some((destination, _))) = (self.master_path(), self.ssh_parts()) else {
            return;
        };
        let Some(options) = path.exists().then(|| options(&path)).flatten() else { return };
        let exit = tokio::process::Command::new(self.ssh_mux().program)
            .args(&options[2..4])
            .args(["-O", "exit", "--", destination.as_str()])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .status();
        match tokio::time::timeout(EXIT_FOR, exit).await {
            Ok(Ok(status)) => {
                tracing::info!(peer = %self.name, %status, "dropped the ssh master an attempt timed out on")
            }
            Ok(Err(e)) => tracing::warn!(peer = %self.name, "ssh -O exit: {e}"),
            Err(_) => tracing::warn!(peer = %self.name, "ssh -O exit did not answer in time"),
        }
    }
}

#[cfg(test)]
#[path = "peer_ssh_master_tests.rs"]
mod tests;
