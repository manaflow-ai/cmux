//! OS-facing primitives of the cmux-tui daemon, below cmux-tui-core: paths,
//! users and peers ([`platform`]), the terminal-host executable
//! ([`host_exe`]), process identity and resource sampling, the Unix process
//! scope, the Windows process queries, and file birth times ([`file_birth`]). cmux-tui-core re-exports each
//! module at its old path (`cmux_tui_core::platform`, ...).

pub mod codex_config_lock;
pub mod file_birth;
#[cfg(unix)]
pub mod host_exe;
mod kinfo_proc;
pub mod platform;
#[cfg(unix)]
pub mod process_identity;
pub mod process_resources;
pub mod task_role;
#[cfg(unix)]
pub mod unix_process_scope;
#[cfg(windows)]
mod windows_processes;
pub mod write_budget;
