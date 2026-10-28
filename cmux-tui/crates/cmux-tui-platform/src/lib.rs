//! OS-facing primitives of the cmux-tui daemon, below cmux-tui-core: paths,
//! users and peers ([`platform`]), the terminal-host executable
//! ([`host_exe`]), process identity and resource sampling, backtraces of a
//! busy thread ([`thread_backtrace`]), the priority of idle helpers
//! ([`process_priority`]), the Unix process scope, the Windows
//! process queries, the request-path blocking notes ([`request_path`]) and
//! the request QoS with its lock-holder boost ([`qos`]).
//! cmux-tui-core re-exports each module at its old path
//! (`cmux_tui_core::platform`, ...).

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

#[cfg(unix)]
pub mod host_exe;
mod kinfo_proc;
pub mod platform;
#[cfg(unix)]
pub mod process_identity;
pub mod process_priority;
pub mod process_resources;
pub mod qos;
pub mod request_path;
pub mod thread_backtrace;
#[cfg(unix)]
pub mod unix_process_scope;
#[cfg(windows)]
mod windows_processes;
