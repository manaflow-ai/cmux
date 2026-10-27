//! Test support for the request-path moves (p02-threads 220): a handler runs
//! as a request thread runs it, with blocking disallowed and the detector in
//! panic mode, so a disk, process or IPC wait left on that thread fails the
//! test at its call site (Chrome's `ScopedBlockingCall` DCHECK,
//! base/threading/scoped_blocking_call.h).
//!
//! The mode is process-wide, as `CMUX_DAEMON_BLOCKING=panic` sets it for a
//! whole daemon: any test thread that disallows blocking then panics at a
//! blocking call.

use std::sync::Arc;

use cmux_threads::blocking::{BlockingMode, set_mode, with_blocking_disallowed};
use serde_json::Value;

use super::{BoundedOutbound, Mux, OutboundItem};

/// Runs `f` on a new thread that disallows blocking, in panic mode, and
/// returns its value; a blocking call in `f` panics there and fails the test.
pub(super) fn on_request_thread<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> R {
    set_mode(BlockingMode::Panic);
    match std::thread::spawn(move || with_blocking_disallowed(f)).join() {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

/// [`on_request_thread`] with a handle to `mux`, dropped after the
/// disallowed scope ends (a last handle's drop joins the daemon's threads,
/// which a request thread never does).
pub(super) fn on_request_thread_with<R: Send + 'static>(
    mux: &Arc<Mux>,
    f: impl FnOnce(&Arc<Mux>) -> R + Send + 'static,
) -> R {
    let mux = Arc::clone(mux);
    set_mode(BlockingMode::Panic);
    let thread = std::thread::spawn(move || {
        let value = with_blocking_disallowed(|| f(&mux));
        drop(mux);
        value
    });
    match thread.join() {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

/// The next message `outbound` carries, waiting for a work item's answer.
pub(super) fn next_reply(outbound: &BoundedOutbound) -> Value {
    loop {
        match outbound.recv() {
            Some(
                OutboundItem::Text(text)
                | OutboundItem::Frame(_, text)
                | OutboundItem::Chunk { text, .. },
            ) => {
                return serde_json::from_str(&text.to_string()).unwrap();
            }
            Some(OutboundItem::Flush(flushed)) => {
                let _ = flushed.send(());
            }
            None => panic!("the connection closed before an answer"),
        }
    }
}
