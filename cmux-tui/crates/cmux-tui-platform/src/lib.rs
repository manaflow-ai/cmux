//! OS-facing primitives of the cmux-tui daemon, below cmux-tui-core: paths,
//! users and peers ([`platform`]), the terminal-host executable
//! ([`host_exe`]), process identity and resource sampling, the Unix process
//! scope, and the Windows process queries. cmux-tui-core re-exports each
//! module at its old path (`cmux_tui_core::platform`, ...).

#[cfg(unix)]
pub mod host_exe;
pub mod platform;
#[cfg(unix)]
pub mod process_identity;
pub mod process_resources;
#[cfg(unix)]
pub mod unix_process_scope;
#[cfg(windows)]
mod windows_processes;
