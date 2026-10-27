//! `std::thread::sleep` through [`scoped_blocking_call`]. Called as
//! `cmux_blocking::thread::sleep(`, so the wakeup audit's `thread::sleep(`
//! rule still judges the caller.

use std::time::Duration;

use crate::{BlockingKind, scoped_blocking_call};

#[track_caller]
pub fn sleep(duration: Duration) {
    scoped_blocking_call("thread::sleep", BlockingKind::Sleep, || {
        // wakeup-allow: deadline the caller's own sleep, passed through; the audit judges the caller's thread::sleep(
        std::thread::sleep(duration);
    });
}
