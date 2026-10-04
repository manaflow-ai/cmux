//! Process roles (server.md 5.1): named programs from `server.json` that
//! `cmux host run` starts, restarts and stops.
//!
//! One supervisor thread owns every role's reducer
//! ([`cmux_server_core::role_proc::RoleProc`]) and child. Helper threads
//! only report facts over one channel: a waiter per child (exit), a reader
//! per child (log lines and `READY=1` / `STATUS=` notifications). The
//! supervisor blocks on that channel until the earliest armed wake, so
//! nothing polls. Health goes to `<state>/roles/status.json` after every
//! change.

mod adapter;
mod log;
mod spawn;
mod supervisor;

pub use adapter::{ProcessRoles, load_roles};
pub use log::{LOG_FILE_BYTES, LOG_FILES, log_path, tail};
pub use supervisor::{Supervisor, read_status, status_path};

use std::path::PathBuf;

/// What the supervisor needs to know about the install.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RolePaths {
    /// `<current>/bin`: where a bare `program` name resolves.
    pub store_bin: PathBuf,
    /// `<state>`: holds `roles/<name>/` and `logs/roles/`.
    pub state: PathBuf,
}

impl RolePaths {
    pub fn from_layout(layout: &cmux_server_core::layout::Layout) -> RolePaths {
        RolePaths {
            store_bin: PathBuf::from(layout.current.as_str()).join("bin"),
            state: PathBuf::from(layout.state.as_str()),
        }
    }

    /// `<state>/roles/<name>`: the role's own folder (0700).
    pub fn role_dir(&self, name: &str) -> PathBuf {
        self.state.join("roles").join(name)
    }

    pub fn log_dir(&self) -> PathBuf {
        self.state.join("logs").join("roles")
    }
}
