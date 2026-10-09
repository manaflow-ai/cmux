//! Platform-neutral parts of the terminal-host runtime (cx-ko2e): code that
//! the Unix host uses today and the Windows host will share. Nothing here
//! calls a Unix API; the OS edges stay in `mod unix` behind seams.

pub(crate) mod attachment;
pub(crate) mod clipboard_read;
pub(crate) mod codec;
pub(crate) mod control_responses;
pub(crate) mod host_state;
