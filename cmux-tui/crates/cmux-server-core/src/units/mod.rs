//! Service definitions that run the frozen command `<current>/bin/cmux host
//! run` (server.md 3, 4.3; lane 1 vm-image.md 4.5).
//!
//! Renderers take a [`Layout`] and return file contents or argv. Every value
//! that reaches a file is validated or escaped for that file's syntax.

mod launchd;
mod systemd;
mod windows;

pub use launchd::{
    APP_BUNDLE_PROGRAM, app_service_agent_plist, launch_agent_plist, launch_daemon_plist,
};
pub use systemd::{
    systemd_app_server_template, systemd_system_unit, systemd_update_path_unit,
    systemd_update_service_unit, systemd_user_unit,
};
pub use windows::{scheduled_task_xml, windows_service_create_argv, windows_service_failure_argv};

use crate::layout::Layout;
use crate::platform::InstallMode;

/// The frozen arguments after the binary. Every unit appends `--mode
/// <user|system>` (launchd through [`host_run_argv_with_mode`]); none sets
/// CMUX_SERVER_MODE.
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
    /// The bundle id is not a plain reverse-DNS name
    /// (`^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$`).
    BadBundleId,
}

/// The full frozen command line as argv, without the mode (callers that
/// add their own `--mode`).
pub fn host_run_argv(layout: &Layout) -> Vec<String> {
    let mut argv = vec![layout.current_cmux.to_string()];
    argv.extend(HOST_RUN_ARGS.iter().map(|s| (*s).to_owned()));
    argv
}

/// `<program> host run --mode <user|system>`. The mode is an argument, not
/// an environment variable, because a service environment reaches every
/// child of the server, including the user's shells.
pub fn host_run_argv_with_mode(program: &str, mode: InstallMode) -> Vec<String> {
    let mode = match mode {
        InstallMode::User => "user",
        InstallMode::System => "system",
    };
    let mut argv = vec![program.to_owned()];
    argv.extend(HOST_RUN_ARGS.iter().map(|s| (*s).to_owned()));
    argv.extend(["--mode".to_owned(), mode.to_owned()]);
    argv
}
