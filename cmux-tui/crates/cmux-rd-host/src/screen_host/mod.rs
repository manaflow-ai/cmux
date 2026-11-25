//! What `cmux-rd linux-host` (src/linux_host/) and `cmux-rd windows-host` (src/windows_host.rs)
//! share on top of the device hub client and session serving (the cmux-hub-host crate): this
//! machine's own consent file and the pending viewer requests, and the names each host
//! registers and prints.
//!
//!   consent   this machine's own consent file and the pending viewer requests
//!   requests  (Windows) the person's answers to viewers waiting for them (`requests|approve|deny`)
//!   serving   (Windows) the running host: the hub socket's pushes, consent, one session at a time
//!
//! linux-host keeps its own copies of `requests` and `serving` in src/linux_host/ (with the
//! virtual display and the machine credential's renewal, which Windows does not have).

pub mod consent;
#[cfg(windows)]
pub mod requests;
#[cfg(windows)]
pub mod serving;

/// The platform this PC registers with the hub as (`POST /v1/devices`); linux-host names its own.
#[cfg(windows)]
pub const PLATFORM: &str = "windows";

/// This host's command, named in next steps the person reads.
#[cfg(target_os = "linux")]
pub const COMMAND: &str = "cmux-rd linux-host";
#[cfg(windows)]
pub const COMMAND: &str = "cmux-rd windows-host";

/// The prefix of this host's log lines.
#[cfg(windows)]
pub const TAG: &str = "windows-host";
