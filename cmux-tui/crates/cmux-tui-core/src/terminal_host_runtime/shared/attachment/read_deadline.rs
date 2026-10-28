//! The one deadline of a request read on the attachment's own reader (Kitty
//! quota adoption, the receipted Terminate before the reader is taken, the
//! wait for the exit frame). Each frame read is bounded by what is left of
//! that deadline, so a stream of unrelated frames cannot extend it, and a
//! read that times out ends the request: no read wakes on a period.

use std::io;
use std::time::{Duration, Instant};

use super::super::super::sys::HostStream;

/// Bounds the next frame read on `reader` by what is left of `deadline`.
/// `Ok(false)` once the deadline has passed (the request failed).
pub(super) fn bound_next_read(reader: &HostStream, deadline: Instant) -> io::Result<bool> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Ok(false);
    }
    // wakeup-allow: deadline the request's one deadline; a frame ends each read first and a timed-out read ends the request
    reader.set_read_timeout(Some(remaining))?;
    Ok(true)
}

/// Puts back the timeout `reader` had before the request bounded its reads.
pub(super) fn restore_read_timeout(
    reader: &HostStream,
    previous: Option<Duration>,
) -> io::Result<()> {
    // wakeup-allow: deadline the caller's own timeout from before the request, put back unchanged
    reader.set_read_timeout(previous)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_read_gets_what_is_left_of_the_deadline_and_none_after_it() {
        let (reader, _peer) = HostStream::pair().unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        assert!(bound_next_read(&reader, deadline).unwrap());
        let bound = reader.read_timeout().unwrap().expect("the read is bounded");
        assert!(bound <= Duration::from_secs(5) && bound > Duration::from_secs(4), "{bound:?}");

        let passed = Instant::now() - Duration::from_millis(1);
        assert!(!bound_next_read(&reader, passed).unwrap(), "no read after the deadline");
        assert_eq!(reader.read_timeout().unwrap(), Some(bound), "a passed deadline sets nothing");
    }

    #[test]
    fn the_caller_timeout_comes_back_after_the_request() {
        let (reader, _peer) = HostStream::pair().unwrap();
        let previous = reader.read_timeout().unwrap();
        assert!(bound_next_read(&reader, Instant::now() + Duration::from_secs(1)).unwrap());
        restore_read_timeout(&reader, previous).unwrap();
        assert_eq!(reader.read_timeout().unwrap(), None);
    }
}
