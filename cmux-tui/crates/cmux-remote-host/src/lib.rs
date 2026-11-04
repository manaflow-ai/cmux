//! cmux Remote on Windows and Linux (docs/cmux-remote.md, "Windows and
//! Linux"): the host the cmux-tui daemon supervises over `remote-host-v1`, its
//! Computer Use worker on upstream Cua Driver, and the approval contract of
//! docs/computer-use-approvals.md.

pub mod approval;
pub mod approver;
pub mod collectors;
pub mod config;
pub mod host;
pub mod platform;
pub mod policy;
pub mod wire;
pub mod worker;
