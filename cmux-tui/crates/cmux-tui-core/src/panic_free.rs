//! Small helpers that replace panicking std and serde_json calls in the mux,
//! surface, state and workspace registry code
//! (plans/cmux-next/rust-panic-free.md).

use std::sync::{LockResult, PoisonError};

use serde_json::{Map, Value};

/// `lock().recover_poison()` instead of `lock().unwrap()`, for every
/// `LockResult` (Mutex, RwLock, Condvar waits, and the crate's ranked and
/// signaled mutexes).
///
/// A lock is poisoned when a thread panicked while holding it. Unwrapping
/// the poison error turns that one panic into a panic on every later request
/// that takes the lock: the daemon stays up but stops serving. The data
/// behind a poisoned lock is the data the panicking thread left; the daemon
/// keeps serving with it.
pub(crate) trait RecoverPoison<T> {
    fn recover_poison(self) -> T;
}

impl<T> RecoverPoison<T> for LockResult<T> {
    fn recover_poison(self) -> T {
        self.unwrap_or_else(PoisonError::into_inner)
    }
}

static NULL: Value = Value::Null;

/// Field access on JSON objects that never panics.
///
/// `field` is `value[key]` for a read: `Value::Null` when the key is
/// missing or the value is not an object (`Value`'s own `Index` already
/// does this; `Map`'s panics on a missing key). `set_field` is
/// `value[key] = field`: a `Null` value becomes an object first, as with
/// `IndexMut`; any other non-object is left unchanged instead of panicking.
pub(crate) trait JsonField {
    fn field(&self, key: &str) -> &Value;
    /// `value[index]` for a read: `Value::Null` when the index is out of
    /// range or the value is not an array (a map has no positions).
    fn item(&self, index: usize) -> &Value;
    fn set_field(&mut self, key: &str, field: Value);
}

impl JsonField for Value {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&NULL)
    }

    fn item(&self, index: usize) -> &Value {
        self.get(index).unwrap_or(&NULL)
    }

    fn set_field(&mut self, key: &str, field: Value) {
        if self.is_null() {
            *self = Value::Object(Map::new());
        }
        if let Some(object) = self.as_object_mut() {
            object.insert(key.to_owned(), field);
        }
    }
}

impl JsonField for Map<String, Value> {
    fn field(&self, key: &str) -> &Value {
        self.get(key).unwrap_or(&NULL)
    }

    fn item(&self, _index: usize) -> &Value {
        &NULL
    }

    fn set_field(&mut self, key: &str, field: Value) {
        self.insert(key.to_owned(), field);
    }
}
