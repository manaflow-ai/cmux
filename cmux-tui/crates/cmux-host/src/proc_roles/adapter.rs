//! Process roles as one [`Role`] of the bind agent (server.md 5.1): the
//! agent's lifecycle events drive the supervisor. On macOS and a plain
//! server [`crate::run_roles`] drives the same supervisor directly.

use std::path::PathBuf;

use cmux_server::config::ServerConfig;
use cmux_server_core::role::{HostEvent, Role, RoleContext, RoleError, StopContext};
use cmux_server_core::role_spec::{RoleSet, parse_roles};

use super::privilege::WorkUser;
use super::{RolePaths, Supervisor};

/// Reads the process roles from `server.json`. A config that cannot be
/// read is one invalid entry, so status shows why nothing runs.
pub fn load_roles(config_file: &std::path::Path) -> RoleSet {
    if let Err(reason) = trusted_as_root(config_file) {
        return RoleSet {
            roles: Vec::new(),
            invalid: vec![cmux_server_core::role_spec::InvalidRole {
                name: "roles".to_owned(),
                reason,
            }],
        };
    }
    match ServerConfig::load(config_file) {
        Ok(cfg) => parse_roles(cfg.roles()),
        Err(error) => RoleSet {
            roles: Vec::new(),
            invalid: vec![cmux_server_core::role_spec::InvalidRole {
                name: "roles".to_owned(),
                reason: error.to_string(),
            }],
        },
    }
}

/// Run as root (system mode), roles would run as root: the config file and
/// its folder must then belong to root and be writable by no one else, or
/// no role runs (a work user who could edit it would gain root).
#[cfg(unix)]
fn trusted_as_root(config_file: &std::path::Path) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } != 0 {
        return Ok(());
    }
    let dir = config_file.parent().unwrap_or(std::path::Path::new("/"));
    for path in [config_file, dir] {
        match std::fs::symlink_metadata(path) {
            Ok(meta)
                if meta.uid() == 0
                    && meta.mode() & 0o022 == 0
                    && !meta.file_type().is_symlink() => {}
            Ok(_) => {
                return Err(format!(
                    "{} must belong to root and be writable only by root when roles run as root",
                    path.display()
                ));
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("{}: {e}", path.display())),
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn trusted_as_root(_config_file: &std::path::Path) -> Result<(), String> {
    Ok(())
}

/// The `process-roles` role.
pub struct ProcessRoles {
    supervisor: Option<Supervisor>,
    config_file: Option<PathBuf>,
    /// Under a root supervisor, the user roles run as.
    work_user: Option<WorkUser>,
}

impl ProcessRoles {
    pub fn new(work_user: Option<WorkUser>) -> ProcessRoles {
        ProcessRoles { supervisor: None, config_file: None, work_user }
    }

    fn reload(&self) {
        if let (Some(sup), Some(file)) = (&self.supervisor, &self.config_file) {
            sup.apply(load_roles(file));
        }
    }

    fn stop_by(&self, deadline: std::time::Instant) -> Result<(), RoleError> {
        let Some(sup) = &self.supervisor else { return Ok(()) };
        let left = sup.stop_all(deadline);
        if left.is_empty() {
            Ok(())
        } else {
            Err(RoleError(format!("still running at the deadline: {}", left.join(", "))))
        }
    }
}

impl Role for ProcessRoles {
    fn name(&self) -> &str {
        "process-roles"
    }

    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError> {
        if self.supervisor.is_none() {
            let paths = RolePaths { work_user: self.work_user.clone(), ..RolePaths::from_layout(&ctx.layout) };
            self.supervisor =
                Some(Supervisor::start(paths).map_err(|e| RoleError(format!("supervisor: {e}")))?);
        }
        self.config_file = Some(PathBuf::from(ctx.layout.config_file.as_str()));
        self.reload();
        Ok(())
    }

    fn stop(&mut self, ctx: &StopContext) -> Result<(), RoleError> {
        self.stop_by(ctx.deadline)
    }

    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
        match event {
            // The agent stops every role when a rebind starts and starts
            // them at its commit (then `Bound`), so a clone never keeps the
            // source machine's role processes; here only reread the config.
            HostEvent::ConfigChanged | HostEvent::Bound { .. } => {
                self.reload();
                Ok(())
            }
            HostEvent::Parked { deadline } | HostEvent::Shutdown { deadline } => {
                self.stop_by(*deadline)
            }
            _ => Ok(()),
        }
    }
}
