//! A value that must never reach a log, a panic message or a diagnostic.

use std::fmt;
use zeroize::Zeroize;

/// A secret (an account token, an install secret, a client key). It is
/// erased when dropped, and `Debug` prints `<redacted>`. It has no
/// `Display` and no `Serialize`, so it cannot be formatted or encoded by
/// accident.
pub struct Secret<T: Zeroize>(T);

impl<T: Zeroize> Secret<T> {
    /// Wrap a value.
    pub fn new(value: T) -> Self {
        Self(value)
    }

    /// Borrow the value for the one operation that needs it.
    pub fn expose(&self) -> &T {
        &self.0
    }
}

impl<T: Zeroize> fmt::Debug for Secret<T> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("<redacted>")
    }
}

impl<T: Zeroize> Drop for Secret<T> {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}
