//! Small panic-free helpers (plans/cmux-next/rust-panic-free.md), the same
//! as cmux-tui-core's `panic_free` module.
//!
//! [`RecoverPoison`]: a `std::sync` lock is poisoned when a thread panicked
//! while it held the lock. Unwrapping that error turns one panic into a panic
//! in every later user of the lock: the client stops drawing, the input lanes
//! stop forwarding keys. The data is what the panicking thread left; the
//! panic itself already reached the panic log, and serving continues with it.
//!
//! [`reported_prefix`]: the bytes one `read` or `write` call reported, as a
//! typed error when the call broke its contract instead of a slice-index
//! panic.
//!
//! [`rest_after`]: an argument list after its first `index` words.
//!
//! [`first_line`]: the bytes of a buffered read up to its first newline.

use std::io;
use std::sync::{LockResult, PoisonError};

/// `.recover_poison()` in place of `.unwrap()` on any `LockResult`: Mutex,
/// RwLock and Condvar wait results.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}

/// The first `count` bytes of `buffer`: the bytes a `read` into it or a
/// `write` from it reported. A call that reports more than the buffer holds
/// broke the `Read`/`Write` contract: that is an `InvalidData` error to the
/// caller, never a panic and never a silently shortened chunk.
pub(crate) fn reported_prefix(buffer: &[u8], count: usize) -> io::Result<&[u8]> {
    buffer.get(..count).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("a call reported {count} bytes of a {}-byte buffer", buffer.len()),
        )
    })
}

/// The items after the first `index` (`items[index..]`), empty when there
/// are no more: the rest of an argument list after its leading words.
pub(crate) fn rest_after<T>(items: &[T], index: usize) -> &[T] {
    items.get(index..).unwrap_or_default()
}

/// The bytes of `available` up to and including its first newline, and
/// whether a newline ended them; all of `available` (and `false`) when it
/// holds no newline yet.
pub(crate) fn first_line(available: &[u8]) -> (&[u8], bool) {
    match available.iter().position(|byte| *byte == b'\n').and_then(|end| available.get(..=end)) {
        Some(line) => (line, true),
        None => (available, false),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::{RecoverPoison, first_line, reported_prefix, rest_after};

    #[test]
    fn a_poisoned_lock_yields_the_data_the_panicking_thread_left() {
        let shared = Arc::new(Mutex::new(1_u32));
        let writer = Arc::clone(&shared);
        let joined = std::thread::spawn(move || {
            let mut value = writer.lock().recover_poison();
            *value = 2;
            panic!("poison the lock while it is held");
        })
        .join();
        assert!(joined.is_err());
        assert!(shared.is_poisoned());
        assert_eq!(*shared.lock().recover_poison(), 2);
    }

    #[test]
    fn reported_prefix_refuses_a_count_past_the_buffer() {
        let buffer = [1_u8, 2, 3];
        assert_eq!(reported_prefix(&buffer, 2).ok(), Some(&buffer[..2]));
        assert_eq!(reported_prefix(&buffer, 3).ok(), Some(&buffer[..]));
        let error = reported_prefix(&buffer, 4).err().map(|error| error.kind());
        assert_eq!(error, Some(std::io::ErrorKind::InvalidData));
    }

    #[test]
    fn rest_after_is_empty_past_the_end() {
        let words = ["a", "b"];
        assert_eq!(rest_after(&words, 0), &words[..]);
        assert_eq!(rest_after(&words, 1), &["b"]);
        assert!(rest_after(&words, 2).is_empty());
        assert!(rest_after(&words, 3).is_empty());
    }

    #[test]
    fn first_line_stops_after_the_first_newline() {
        assert_eq!(first_line(b"ab\ncd\n"), (&b"ab\n"[..], true));
        assert_eq!(first_line(b"\n"), (&b"\n"[..], true));
        assert_eq!(first_line(b"abc"), (&b"abc"[..], false));
        assert_eq!(first_line(b""), (&b""[..], false));
    }
}
