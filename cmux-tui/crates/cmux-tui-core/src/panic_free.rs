//! Small panic-free helpers (plans/cmux-next/rust-panic-free.md).
//!
//! [`RecoverPoison`]: a `std::sync` lock is poisoned when a thread panicked while it held the
//! lock. Unwrapping that error turns one panic into a panic in every later
//! user of the lock: the daemon or terminal host keeps its socket and stops
//! serving. The data is what the panicking thread left; serving continues
//! with it.

use std::sync::{LockResult, PoisonError};

use serde_json::Value;

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

/// Panic-free stand-ins for serde_json's `value[key]` read and write.
pub(crate) trait JsonFields {
    /// `value[key]` without the index operator: Null when the key is absent
    /// or the value is not an object.
    fn field(&self, key: &str) -> &Value;
    /// `value[key] = field` without the panic: Null becomes an object (as
    /// `IndexMut` does); any other non-object value is left unchanged.
    fn insert(&mut self, key: &str, field: Value);
}

static JSON_NULL: Value = Value::Null;

impl JsonFields for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&JSON_NULL)
    }

    fn insert(&mut self, key: &str, field: Value) {
        if self.is_null() {
            *self = Value::Object(serde_json::Map::new());
        }
        if let Some(object) = self.as_object_mut() {
            object.insert(key.to_owned(), field);
        }
    }
}

/// The longest prefix of `text` of at most `max_bytes`, cut on a character
/// boundary.
#[allow(
    clippy::string_slice,
    clippy::indexing_slicing,
    reason = "INVARIANT: floor_char_boundary returns a character boundary <= text.len()"
)]
pub(crate) fn utf8_prefix(text: &str, max_bytes: usize) -> &str {
    &text[..text.floor_char_boundary(max_bytes)]
}

/// The longest suffix of `text` of at most `max_bytes`, cut on a character
/// boundary.
#[allow(
    clippy::string_slice,
    clippy::indexing_slicing,
    reason = "INVARIANT: ceil_char_boundary returns a character boundary <= text.len()"
)]
pub(crate) fn utf8_suffix(text: &str, max_bytes: usize) -> &str {
    &text[text.ceil_char_boundary(text.len().saturating_sub(max_bytes))..]
}

/// `bytes` split around its first `separator`; `None` when it has none.
pub(crate) fn split_once_byte(bytes: &[u8], separator: u8) -> Option<(&[u8], &[u8])> {
    let mut parts = bytes.splitn(2, |byte| *byte == separator);
    let head = parts.next()?;
    parts.next().map(|tail| (head, tail))
}

#[cfg(test)]
mod tests {
    use super::{split_once_byte, utf8_prefix, utf8_suffix};

    #[test]
    fn split_once_byte_splits_at_the_first_separator() {
        assert_eq!(split_once_byte(b"a;b;c", b';'), Some((&b"a"[..], &b"b;c"[..])));
        assert_eq!(split_once_byte(b";", b';'), Some((&b""[..], &b""[..])));
        assert_eq!(split_once_byte(b"abc", b';'), None);
        assert_eq!(split_once_byte(b"", b';'), None);
    }

    #[test]
    fn utf8_cuts_never_split_a_character() {
        let text = "aé€😀z"; // 1 + 2 + 3 + 4 + 1 bytes
        let prefixes: Vec<&str> = (0..=12).map(|max| utf8_prefix(text, max)).collect();
        assert_eq!(prefixes[0], "");
        assert_eq!(prefixes[2], "a");
        assert_eq!(prefixes[3], "aé");
        assert_eq!(prefixes[9], "aé€");
        assert_eq!(prefixes[10], "aé€😀");
        assert_eq!(prefixes[12], text);
        assert_eq!(utf8_suffix(text, 0), "");
        assert_eq!(utf8_suffix(text, 1), "z");
        assert_eq!(utf8_suffix(text, 4), "z");
        assert_eq!(utf8_suffix(text, 5), "😀z");
        assert_eq!(utf8_suffix(text, 100), text);
    }
}
