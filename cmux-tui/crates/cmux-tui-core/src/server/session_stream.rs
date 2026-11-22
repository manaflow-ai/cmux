//! Session event and journal stream helpers.

use std::sync::atomic::{AtomicBool, Ordering};

use super::{MessageWriter, OutboundStream};

/// A session stream ends on cancel, on a closed connection, or when its
/// outbound closes alone (a victim of a full connection queue). The outbound
/// close fires the stream's interrupt, so a loop that does not check it here
/// returns from its wait at once on every pass and spins.
pub(super) fn stopped(
    canceled: &AtomicBool,
    writer: &MessageWriter,
    outbound: &OutboundStream,
) -> bool {
    canceled.load(Ordering::Acquire) || !writer.is_open() || !outbound.is_open()
}

#[cfg(test)]
#[path = "session_stream_tests.rs"]
mod tests;
