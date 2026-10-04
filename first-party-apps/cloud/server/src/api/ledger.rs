//! Replay records of mutations (OWNERSHIP-PRINCIPLES invariant 5: replaying
//! an op with the same key has no further effect).
//!
//! An attempt is recorded before the Cloud API call, so the same key with
//! another op or other args is a conflict even after a failure. A success
//! also records the result, which a retry gets back with no call. A failed or
//! lost call may be retried with the same key: the Cloud API dedups create,
//! restore and fork by the derived key [`upstream_key`]. The ledger lives as
//! long as the server process (data class `ephemeral`).

use crate::api::{CloudError, codes};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};

const CAPACITY: usize = 512;

struct Entry {
    op: String,
    /// SHA-256 of the canonical args: a file write's data can be 16 MiB, so
    /// the ledger keeps a digest, not the args.
    args: [u8; 32],
    result: Option<Value>,
}

fn digest(args: &Value) -> [u8; 32] {
    Sha256::digest(args.to_string().as_bytes()).into()
}

#[derive(Default)]
pub(crate) struct Ledger {
    entries: HashMap<String, Entry>,
    order: VecDeque<String>,
}

/// The key sent to the Cloud API: SHA-256 of the op, the canonical args and
/// the caller's key (64 hex characters). The Cloud API matches keys per team
/// without comparing the op or the body, so the derived key keeps a create
/// key from replaying as a fork, and other args from replaying a machine,
/// also after this process restarts.
pub fn upstream_key(op: &str, args: &Value, key: &str) -> String {
    let canonical = json!([op, args, key]).to_string();
    Sha256::digest(canonical.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

impl Ledger {
    /// The recorded result for `key` when the same op with the same args
    /// succeeded; `None` when it never ran or did not finish. The same key
    /// with another op or other args is a conflict.
    pub(crate) fn replay(
        &self,
        key: &str,
        op: &str,
        args: &Value,
    ) -> Result<Option<Value>, CloudError> {
        let Some(entry) = self.entries.get(key) else { return Ok(None) };
        if entry.op != op || entry.args != digest(args) {
            return Err(CloudError::new(
                codes::IDEMPOTENCY_CONFLICT,
                format!("this idempotency key was already used for {}", entry.op),
            ));
        }
        Ok(entry.result.clone())
    }

    /// True when the same op with the same args was attempted with `key`
    /// and has no recorded result (it failed or its answer was lost).
    pub(crate) fn unfinished(&self, key: &str, op: &str, args: &Value) -> bool {
        self.entries
            .get(key)
            .is_some_and(|e| e.op == op && e.args == digest(args) && e.result.is_none())
    }

    /// Records an attempt before the call.
    pub(crate) fn attempt(&mut self, key: &str, op: &str, args: &Value) {
        if self.entries.contains_key(key) {
            return;
        }
        if self.entries.len() >= CAPACITY
            && let Some(oldest) = self.order.pop_front()
        {
            self.entries.remove(&oldest);
        }
        self.order.push_back(key.to_owned());
        self.entries
            .insert(key.to_owned(), Entry { op: op.to_owned(), args: digest(args), result: None });
    }

    /// Drops an attempt that changed nothing (refused arguments).
    pub(crate) fn forget(&mut self, key: &str) {
        if self.entries.remove(key).is_some() {
            self.order.retain(|k| k != key);
        }
    }

    /// Records the result of a successful attempt.
    pub(crate) fn succeed(&mut self, key: &str, result: Value) {
        if let Some(entry) = self.entries.get_mut(key) {
            entry.result = Some(result);
        }
    }
}
