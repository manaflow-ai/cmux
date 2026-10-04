//! Replay records of finished mutations (OWNERSHIP-PRINCIPLES invariant 5:
//! replaying an op with the same key has no further effect).
//!
//! Only successes are recorded: a failed or lost call may be retried with the
//! same key, and the Cloud API dedups create, restore and fork by that key.
//! The ledger lives as long as the server process (data class `ephemeral`).

use crate::api::{CloudError, codes};
use serde_json::Value;
use std::collections::{HashMap, VecDeque};

const CAPACITY: usize = 512;

struct Entry {
    op: String,
    args: Value,
    result: Value,
}

#[derive(Default)]
pub(crate) struct Ledger {
    entries: HashMap<String, Entry>,
    order: VecDeque<String>,
}

impl Ledger {
    /// The recorded result for `key`, if the same op with the same args ran.
    /// The same key with another op or other args is a conflict.
    pub(crate) fn replay(
        &self,
        key: &str,
        op: &str,
        args: &Value,
    ) -> Result<Option<Value>, CloudError> {
        let Some(entry) = self.entries.get(key) else { return Ok(None) };
        if entry.op != op || entry.args != *args {
            return Err(CloudError::new(
                codes::IDEMPOTENCY_CONFLICT,
                format!("this idempotency key was already used for {}", entry.op),
            ));
        }
        Ok(Some(entry.result.clone()))
    }

    pub(crate) fn record(&mut self, key: &str, op: &str, args: &Value, result: Value) {
        if self.entries.len() >= CAPACITY
            && let Some(oldest) = self.order.pop_front()
        {
            self.entries.remove(&oldest);
        }
        self.order.push_back(key.to_owned());
        self.entries
            .insert(key.to_owned(), Entry { op: op.to_owned(), args: args.clone(), result });
    }
}
