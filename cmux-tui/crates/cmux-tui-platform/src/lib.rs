//! OS-facing primitives of the cmux-tui daemon, below cmux-tui-core: paths,
//! users and peers ([`platform`]), the terminal-host executable
//! ([`host_exe`]), process identity and resource sampling, the Unix process
//! scope, the Windows process queries, and file birth times ([`file_birth`]). cmux-tui-core re-exports each
//! module at its old path (`cmux_tui_core::platform`, ...). [`ended_children`]
//! says if this process keeps the process ids of its ended children.

pub mod codex_config_lock;
pub mod ended_children;
pub mod file_birth;
#[cfg(unix)]
pub mod host_exe;
mod kinfo_proc;
pub mod platform;
#[cfg(unix)]
pub mod process_identity;
pub mod process_resources;
#[cfg(all(unix, any(test, feature = "test-support")))]
mod read_wait;
#[cfg(unix)]
pub mod unix_process_scope;
#[cfg(windows)]
mod windows_processes;
pub mod write_budget;

#[cfg(all(unix, any(test, feature = "test-support")))]
pub use read_wait::{ReadWait, read_timeout_or_ended};
