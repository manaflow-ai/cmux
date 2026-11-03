//! Panic-free helpers for the daemon (plans/cmux-next/rust-panic-free.md).
//!
//! A poisoned lock only means another thread panicked while it held the
//! lock; the data is still there. Recovering it keeps one failed request
//! from turning every later request into a panic.
//!
//! `value["key"] = x` panics when `value` is not an object or null (an
//! array, a string from a peer). [`JsonExt::set`] inserts into an object,
//! turns null into an object, and leaves any other value as it is.

use std::sync::{Mutex, MutexGuard, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Lock without panicking on poison.
pub trait LockExt<T: ?Sized> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T>;
}

impl<T: ?Sized> LockExt<T> for Mutex<T> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T> {
        self.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Read or write an `RwLock` without panicking on poison.
pub trait RwLockExt<T: ?Sized> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T>;
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T>;
}

impl<T: ?Sized> RwLockExt<T> for RwLock<T> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T> {
        self.read().unwrap_or_else(PoisonError::into_inner)
    }
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T> {
        self.write().unwrap_or_else(PoisonError::into_inner)
    }
}

/// Non-panicking `serde_json::Value` writes: the shared [`cmux_json::JsonSet`]
/// under the name the daemon already imports.
pub use cmux_json::JsonSet as JsonExt;
