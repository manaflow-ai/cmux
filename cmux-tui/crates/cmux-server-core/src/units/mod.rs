//! Service definitions that run the frozen command `<current>/bin/cmux host
//! run` (server.md 3, 4.3; lane 1 vm-image.md 4.5).
//!
//! Renderers take a [`Layout`] and return file contents or argv. Every value
//! that reaches a file is validated or escaped for that file's syntax.

mod launchd;
mod systemd;
mod windows;

pub use launchd::{launch_agent_plist, launch_daemon_plist};
pub use systemd::{systemd_system_unit, systemd_user_unit};
pub use windows::{scheduled_task_xml, windows_service_create_argv, windows_service_failure_argv};

use crate::layout::Layout;

/// The frozen arguments after the binary.
pub const HOST_RUN_ARGS: [&str; 2] = ["host", "run"];
/// System-mode service user on Linux (server.md 4.3).
pub const SERVICE_USER: &str = "cmux";

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum UnitError {
    /// The layout is for another platform or mode than the unit kind.
    WrongLayout,
    /// A path holds a character the unit syntax cannot carry safely.
    UnsafePath(&'static str),
    BadUser,
}

/// The full frozen command line as argv.
pub fn host_run_argv(layout: &Layout) -> Vec<String> {
    let mut argv = vec![layout.current_cmux.to_string()];
    argv.extend(HOST_RUN_ARGS.iter().map(|s| (*s).to_owned()));
    argv
}
