//! Test support for the request-path moves (p02-threads 220): a handler runs
//! as a request thread runs it, with blocking disallowed and the detector in
//! panic mode, so a disk, process or IPC wait left on that thread fails the
//! test at its call site (Chrome's `ScopedBlockingCall` DCHECK,
//! base/threading/scoped_blocking_call.h).

use cmux_threads::blocking::{BlockingMode, set_mode, with_blocking_disallowed};
use serde_json::Value;

use super::{BoundedOutbound, OutboundItem};

/// Runs `f` on a new thread that disallows blocking, in panic mode, and
/// returns its value; a blocking call in `f` panics there and fails the test.
pub(super) fn on_request_thread<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> R {
    set_mode(BlockingMode::Panic);
    match std::thread::spawn(move || with_blocking_disallowed(f)).join() {
        Ok(value) => value,
        Err(panic) => std::panic::resume_unwind(panic),
    }
}

/// The next message `outbound` carries, waiting for a work item's answer.
pub(super) fn next_reply(outbound: &BoundedOutbound) -> Value {
    loop {
        match outbound.recv() {
            Some(OutboundItem::Text(text)) => {
                return serde_json::from_str(&text.to_string()).unwrap();
            }
            Some(OutboundItem::Flush(flushed)) => {
                let _ = flushed.send(());
            }
            None => panic!("the connection closed before an answer"),
        }
    }
}
