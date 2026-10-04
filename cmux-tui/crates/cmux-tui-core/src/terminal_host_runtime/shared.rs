//! Platform-neutral parts of the terminal-host runtime (cx-ko2e): code that
//! the Unix host uses today and the Windows host will share. Nothing here
//! calls a Unix API; the OS edges stay in `mod unix` behind seams.

pub(crate) mod attachment;
pub(crate) mod clipboard_read;
pub(crate) mod codec;
pub(crate) mod control_responses;
pub(crate) mod exited_drain;
pub(crate) mod host_accept;
pub(crate) mod host_crash;
pub(crate) mod host_parser;
pub(crate) mod host_refusal;
pub(crate) mod host_serve;
pub(crate) mod host_shared;
pub(crate) mod host_state;
pub(crate) mod metric_commits;
pub(crate) mod records;
pub(crate) mod renderer_grant;
pub(crate) mod unadoptable;
