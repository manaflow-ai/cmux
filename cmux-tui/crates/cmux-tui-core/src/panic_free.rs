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
