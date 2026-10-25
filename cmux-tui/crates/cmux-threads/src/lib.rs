//! Thread rules for the cmux daemon, after Chromium's //base threading model
//! (plans/cmux-next/chrome-parity/p02-threads.md, section 3F).
//!
//! - [`blocking`]: the blocking detector (`disallow_blocking`, the
//!   [`AllowReason`] friend list, `scoped_blocking_call`, the site table).
//! - [`checked`]: checked forms of the blocking std primitives.

pub mod blocking;
pub mod checked;

pub use blocking::{
    AllowReason, BlockingKind, BlockingMode, BlockingSite, BlockingSnapshot, allow_blocking,
    assert_blocking_allowed, disallow_blocking, scoped_blocking_call, with_blocking_disallowed,
};
#[cfg(unix)]
pub use blocking::{own_fd_read, own_fd_write, own_fd_write_all};
