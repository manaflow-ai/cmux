//! What `cmux-rd linux-host` (src/linux_host/) and `cmux-rd windows-host` (src/windows_host.rs)
//! share on top of the device hub client (the cmux-hub-host crate): this machine's own consent
//! file and the pending viewer requests, and the names each host registers and prints.
//!
//!   consent   this machine's own consent file and the pending viewer requests

// Windows serves no session yet (docs/device-hub/windows-host.md, step 4): the session-side
// consent calls are Linux's until then.
#![cfg_attr(windows, allow(dead_code))]

pub mod consent;

/// The platform this PC registers with the hub as (`POST /v1/devices`); linux-host names its own.
#[cfg(windows)]
pub const PLATFORM: &str = "windows";

/// This host's command, named in next steps the person reads.
#[cfg(target_os = "linux")]
pub const COMMAND: &str = "cmux-rd linux-host";
#[cfg(windows)]
pub const COMMAND: &str = "cmux-rd windows-host";
