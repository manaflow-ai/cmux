//! Small panic-free helpers (plans/cmux-next/rust-panic-free.md).
//!
//! A `std::sync` lock is poisoned when a thread panicked while it held the
//! lock. Unwrapping that error turns one panic into a panic in every later
//! user of the lock: the relay keeps its socket and stops serving. The relay
//! takes a poisoned lock one of two ways, chosen by what the lock's critical
//! sections write:
//!
//! - [`RecoverPoison`]: every critical section makes at most one write (one
//!   map insert, remove, retain or clear, or one assignment of a whole
//!   value). A panic leaves the data as a completed write left it, so the
//!   next user takes it as it is: the tables of pending requests, PTY
//!   attachments, opening reservations, shell sessions, per-transport auth,
//!   the event handlers, the session auth snapshot (assigned whole) and the
//!   process completion state (each section writes one counter or the exit
//!   code).
//! - [`LockRevalidated`]: a critical section writes more than one field (a
//!   queue and its byte count). A panic between the writes leaves the state
//!   torn, so the next user rebuilds every derived field from the fields
//!   that define it ([`Revalidate`]), clears the poison and logs one
//!   `lock_poison` line in the panic log's record format.

use std::panic::Location;
use std::sync::{LockResult, Mutex, MutexGuard, PoisonError};

/// `.recover_poison()` in place of `.expect(..)` on the `LockResult` of a
/// lock whose every critical section makes at most one write.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}

/// State whose critical sections write more than one field.
pub(crate) trait Revalidate {
    /// The lock's name in the poison record.
    const LOCK: &'static str;

    /// Recompute every field derived from another (a byte count from its
    /// queue), so the state is one a completed critical section could leave.
    fn revalidate(&mut self);
}

/// `.lock_revalidated()` in place of `.lock()` on a lock over [`Revalidate`]
/// state.
pub(crate) trait LockRevalidated<T: Revalidate> {
    fn lock_revalidated(&self) -> MutexGuard<'_, T>;
}

impl<T: Revalidate> LockRevalidated<T> for Mutex<T> {
    #[track_caller]
    fn lock_revalidated(&self) -> MutexGuard<'_, T> {
        match self.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                guard.revalidate();
                // Later users get the repaired state, not a poison to repair again.
                self.clear_poison();
                report_poison(T::LOCK, &Location::caller().to_string());
                guard
            }
        }
    }
}

/// One line in the panic log's record format (`cmux_panic_log::record`) on
/// stderr, the relay's log, after the line of the panic that poisoned it.
fn report_poison(lock: &str, location: &str) {
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "chatmux-relay".into());
    fields.insert("kind".into(), "lock_poison".into());
    fields.insert("lock".into(), lock.into());
    let thread = std::thread::current().name().unwrap_or("unnamed").to_owned();
    let message = format!("{lock} was poisoned by a panic; its derived fields were rebuilt");
    let line = cmux_panic_log::record(&fields, &message, location, &thread, false, String::new());
    eprintln!("{line}");
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

    use super::{LockRevalidated as _, RecoverPoison as _, Revalidate};

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

    struct Counted {
        items: Vec<u8>,
        count: usize,
    }

    impl Revalidate for Counted {
        const LOCK: &'static str = "Counted";

        fn revalidate(&mut self) {
            self.count = self.items.len();
        }
    }

    #[test]
    fn a_poisoned_multi_field_lock_is_rebuilt_once_and_unpoisoned() {
        let lock = Arc::new(Mutex::new(Counted { items: vec![1], count: 1 }));
        let poisoner = Arc::clone(&lock);
        let joined = std::panic::catch_unwind(move || {
            let mut guard = poisoner.lock_revalidated();
            guard.items.push(2);
            std::panic::panic_any("panic between the two writes");
        });
        assert!(joined.is_err());
        assert!(lock.is_poisoned());
        {
            let repaired = lock.lock_revalidated();
            assert_eq!((repaired.items.as_slice(), repaired.count), (&[1, 2][..], 2));
        }
        assert!(!lock.is_poisoned(), "the repair clears the poison");
    }
}
