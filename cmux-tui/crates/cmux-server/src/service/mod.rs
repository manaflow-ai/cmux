//! Service registration (server.md 4.3 row "service", 4.4, 7.4).
//!
//! Every unit and plist text comes from `cmux_server_core::units`; this
//! module writes them, enables and starts them through `systemctl` or
//! `launchctl bootstrap gui/<uid>`, and removes them on uninstall. It never
//! runs `sudo`: a step that needs root is reported with the one command to
//! run.

mod launchd;
mod systemd;

use std::path::PathBuf;

use cmux_server_core::layout::{Layout, ServiceKind};

use crate::error::{Error, Result};
use crate::process::Runner;

pub use systemd::linger_state;

/// What an install or start did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ServiceReport {
    /// The main unit or plist path.
    pub unit: PathBuf,
    /// Some unit file was written (its content changed).
    pub changed: bool,
    pub restarted: bool,
    /// Linux user mode: linger is on (`None` elsewhere).
    pub linger: Option<bool>,
    /// Steps that need the user (for example the one `sudo` command).
    pub warnings: Vec<String>,
}

/// Loaded and running state, as far as the service manager reports it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ServiceState {
    pub installed: bool,
    pub active: Option<bool>,
    pub enabled: Option<bool>,
}

/// The service manager for one layout.
pub struct Services<'a> {
    pub layout: &'a Layout,
    pub runner: &'a dyn Runner,
    /// The installing user (`loginctl`, `launchctl gui/<uid>`).
    pub uid: u32,
    pub user: String,
}

fn unsupported(kind: &ServiceKind) -> Error {
    Error::rejected(format!(
        "service kind {kind:?} is not supported by this build yet (server.md steps 7 and 8)"
    ))
}

impl Services<'_> {
    /// The main unit or plist path.
    pub fn unit_path(&self) -> Result<PathBuf> {
        match &self.layout.service {
            ServiceKind::SystemdUser { unit_path } | ServiceKind::SystemdSystem { unit_path } => {
                Ok(PathBuf::from(unit_path.as_str()))
            }
            ServiceKind::LaunchAgent { plist_path } => Ok(PathBuf::from(plist_path.as_str())),
            other => Err(unsupported(other)),
        }
    }

    /// Writes the units, enables them and starts the server. With
    /// `restart`, a running server is restarted (a new generation); its
    /// session host hands off and keeps terminal hosts (`KillMode=process`).
    pub fn install(&self, restart: bool) -> Result<ServiceReport> {
        match &self.layout.service {
            ServiceKind::SystemdUser { .. } | ServiceKind::SystemdSystem { .. } => {
                systemd::install(self, restart)
            }
            ServiceKind::LaunchAgent { .. } => launchd::install(self, restart),
            other => Err(unsupported(other)),
        }
    }

    /// Restarts a running server (rollback, upgrade); a stopped one starts.
    pub fn restart(&self) -> Result<()> {
        match &self.layout.service {
            ServiceKind::SystemdUser { .. } | ServiceKind::SystemdSystem { .. } => {
                systemd::restart(self)
            }
            ServiceKind::LaunchAgent { .. } => launchd::restart(self),
            other => Err(unsupported(other)),
        }
    }

    /// Stops, disables and removes every unit this crate writes. Returns
    /// the removed paths.
    pub fn uninstall(&self) -> Result<Vec<PathBuf>> {
        match &self.layout.service {
            ServiceKind::SystemdUser { .. } | ServiceKind::SystemdSystem { .. } => {
                systemd::uninstall(self)
            }
            ServiceKind::LaunchAgent { .. } => launchd::uninstall(self),
            other => Err(unsupported(other)),
        }
    }

    /// Every unit or plist file of the layout with its core-rendered text.
    pub fn unit_files(&self) -> Result<Vec<(PathBuf, String)>> {
        match &self.layout.service {
            ServiceKind::SystemdUser { .. } | ServiceKind::SystemdSystem { .. } => {
                systemd::files(self)
            }
            ServiceKind::LaunchAgent { .. } => Ok(vec![(self.unit_path()?, launchd::plist(self)?)]),
            other => Err(unsupported(other)),
        }
    }

    pub fn state(&self) -> ServiceState {
        match &self.layout.service {
            ServiceKind::SystemdUser { .. } | ServiceKind::SystemdSystem { .. } => {
                systemd::state(self)
            }
            ServiceKind::LaunchAgent { .. } => launchd::state(self),
            _ => ServiceState::default(),
        }
    }
}
