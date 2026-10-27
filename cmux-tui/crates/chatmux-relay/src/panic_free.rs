//! Small panic-free helpers (plans/cmux-next/rust-panic-free.md).
//!
//! [`RecoverPoison`]: a `std::sync` lock is poisoned when a thread panicked
//! while it held the lock. Unwrapping that error turns one panic into a
//! panic in every later user of the lock: the relay keeps its socket and
//! stops serving. The relay's locks guard bookkeeping tables (pending
//! requests, PTY attachments, auth snapshots, stream state) whose every
//! write is one insert, remove or assignment, so the data a panicking
//! thread left is a table some earlier write completed; serving continues
//! with it. The same rule as cmux-tui-core's `panic_free::RecoverPoison`.

use std::sync::{LockResult, PoisonError};

/// `.recover_poison()` in place of `.expect(..)` on any `LockResult`:
/// Mutex, RwLock and Condvar wait results.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}

/// The bytes a read wrote into `buffer`: `&buffer[..count]` for a read that
/// returned `Ok(count)`. Chrome's `base::span::first(count)`, which CHECKs.
#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: Read::read and AsyncRead::read guarantee that the count they return is at most the buffer's length"
)]
pub(crate) fn filled(buffer: &[u8], count: usize) -> &[u8] {
    &buffer[..count]
}

/// The symbol of `alphabet` that a random `byte` picks: `alphabet[byte % N]`.
/// An empty alphabet fails the build, not the call.
#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: N > 0 is checked at compile time, so byte % N is less than N, the array's length"
)]
pub(crate) fn alphabet_symbol<const N: usize>(alphabet: &[u8; N], byte: u8) -> char {
    const { assert!(N > 0, "alphabet_symbol needs a non-empty alphabet") };
    char::from(alphabet[usize::from(byte) % N])
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::RecoverPoison as _;

    #[test]
    fn a_poisoned_lock_still_yields_its_data() {
        let lock = Arc::new(Mutex::new(vec![1_u8]));
        let poisoner = Arc::clone(&lock);
        let joined = std::panic::catch_unwind(move || {
            let mut guard = poisoner.lock().recover_poison();
            guard.push(2);
            std::panic::panic_any("poison the lock");
        });
        assert!(joined.is_err());
        assert!(lock.is_poisoned());
        assert_eq!(*lock.lock().recover_poison(), vec![1, 2]);
    }
}
