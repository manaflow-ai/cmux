//! Paths and settings of the bind agent. Every path is absolute in
//! production; tests run the agent under a temporary root, so each path is
//! resolved through [`Paths`].
//!
//! The file contracts are the ones the devbox supervisor
//! (`web/services/vms/images/devbox/cmux-devbox-boot`) and the bake's park
//! command (`devboxParkDaemonCommand`) already use.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The machine this agent bound the session host's identity to.
pub const BOUND_INSTANCE_FILE: &str = "/etc/cmux/daemon-instance-id";
/// The machine being snapshotted; while it matches, the agent is parked.
pub const BAKE_INSTANCE_FILE: &str = "/etc/cmux/bake-instance-id";
pub const ETC_DIR: &str = "/etc/cmux";
/// The driver writes `instance-id` here right after create.
pub const RUN_DIR: &str = "/run/cmux";
pub const DRIVER_FILE_NAME: &str = "instance-id";
pub const BAKE_FILE_NAME: &str = "bake-instance-id";
/// Starts the warm template shell's bounded wait (cmux-prompt.bash).
pub const CLONE_STARTED_FILE: &str = "/run/cmux/clone-started";
/// The template shell writes this once its first prompt is waiting.
pub const TEMPLATE_READY_FILE: &str = "/run/cmux/template-shell-ready";
/// The template terminal's bound ids, written by the session host.
pub const TEMPLATE_BOUND_FILE: &str = "/run/cmux/bound";
/// Root-only agent state: pid file and status.
pub const AGENT_DIR: &str = "/run/cmux-host";
pub const DAEMON_PID_FILE: &str = "/run/cmux-host/daemon.pid";
pub const STATUS_FILE: &str = "/run/cmux-host/status.json";
/// Operator breadcrumb: which layout the session host runs under.
pub const LAYOUT_MARKER_FILE: &str = "/etc/cmux/daemon-layout";
pub const GHOSTTY_VERSION_FILE: &str = "/etc/cmux/ghostty-version";
pub const MACHINE_ID_FILE: &str = "/etc/machine-id";
pub const DBUS_MACHINE_ID_FILE: &str = "/var/lib/dbus/machine-id";
pub const RANDOM_SEED_FILE: &str = "/var/lib/systemd/random-seed";
pub const SSH_DIR: &str = "/etc/ssh";
/// Present only when systemd is PID 1.
pub const SYSTEMD_RUNTIME_DIR: &str = "/run/systemd/system";

/// Housekeeping timers stopped at park and started 10 min after a bind
/// (the same list as cmux-devbox-boot).
pub const HOUSEKEEPING_TIMERS: [&str; 9] = [
    "apt-daily.timer",
    "apt-daily-upgrade.timer",
    "dpkg-db-backup.timer",
    "e2scrub_all.timer",
    "fstrim.timer",
    "logrotate.timer",
    "man-db.timer",
    "motd-news.timer",
    "systemd-tmpfiles-clean.timer",
];
pub const HOUSEKEEPING_DELAY: Duration = Duration::from_secs(600);
/// See [`Config::announce_interval`].
pub const DEFAULT_ANNOUNCE_INTERVAL: Duration = Duration::from_secs(30);
/// SIGTERM to SIGKILL grace for the session host.
pub const STOP_GRACE: Duration = Duration::from_secs(5);

/// Resolves absolute contract paths under a root (`/` in production).
#[derive(Clone, Debug)]
pub struct Paths {
    root: PathBuf,
}

impl Paths {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// `abs` (an absolute contract path) under the root.
    pub fn at(&self, abs: &str) -> PathBuf {
        self.root.join(abs.trim_start_matches('/'))
    }

    /// The root is `/`: the agent may touch system services.
    pub fn is_system_root(&self) -> bool {
        self.root == Path::new("/")
    }
}

/// Overrides of the session host's user and binary. Production uses none
/// and selects the layout the way `cmuxTuiLayoutSelector()` does.
#[derive(Clone, Debug, Default)]
pub struct DaemonOverride {
    pub user: Option<String>,
    /// The session host's home (its state and remote identity live here).
    pub home: Option<PathBuf>,
    pub bin: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub paths: Paths,
    pub metadata_addr: SocketAddr,
    pub metadata_attempts: u32,
    pub metadata_timeout: Duration,
    pub daemon: DaemonOverride,
    /// `CMUX_TUI_REMOTE_WS_BIND`, else the IPv4 wildcard.
    pub remote_ws_bind: String,
    /// Send the gratuitous ARP announce (off only in tests).
    pub announce: bool,
    /// `announce_interval_seconds`: repeat the announce this often while
    /// bound and not parked (one-shot timer re-armed after each announce);
    /// zero disables it. Default 30 s until the 2-hour idle reachability
    /// smoke passes; then the default becomes 0 (vm-image.md 6.4).
    pub announce_interval: Duration,
    pub rearm_delay: Duration,
    /// Append one line per executed action (tests and diagnostics).
    pub action_log: Option<PathBuf>,
    /// How to run this binary's hidden `rekey` verb: `[cmux-host]`, or
    /// `[cmux, host]` once the verb is mounted in `cmux`.
    pub self_argv: Vec<String>,
    /// `server.json` of the install layout (watched for `ConfigChanged`).
    pub server_config: Option<PathBuf>,
}

impl Config {
    pub fn production() -> Self {
        Self {
            paths: Paths::new("/"),
            metadata_addr: crate::metadata::DEFAULT_ADDR.parse().expect("static address"),
            metadata_attempts: crate::metadata::DEFAULT_ATTEMPTS,
            metadata_timeout: crate::metadata::ATTEMPT_TIMEOUT,
            daemon: DaemonOverride::default(),
            remote_ws_bind: crate::daemon_spec::DEFAULT_REMOTE_WS_BIND.to_owned(),
            announce: true,
            announce_interval: DEFAULT_ANNOUNCE_INTERVAL,
            rearm_delay: HOUSEKEEPING_DELAY,
            action_log: None,
            self_argv: Vec::new(),
            server_config: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_resolve_under_root() {
        let p = Paths::new("/tmp/x");
        assert_eq!(p.at(BOUND_INSTANCE_FILE), PathBuf::from("/tmp/x/etc/cmux/daemon-instance-id"));
        assert!(!p.is_system_root());
        assert!(Paths::new("/").is_system_root());
        assert_eq!(Paths::new("/").at(RUN_DIR), PathBuf::from("/run/cmux"));
    }
}
