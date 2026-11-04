//! The local protected collectors (docs/computer-use-approvals.md, "Collectors").

#[cfg(target_os = "linux")]
pub mod polkit;

#[cfg(windows)]
pub mod hello;
