//! One change to an environment that holds against a concurrent one (review F1 of #40325).
//!
//! `set-var`, `unset-var`, `add-file`, `rm-file` and `edit --network` read the environment and
//! send a whole array or object back, so two of them at once could each overwrite the other's
//! change. Each sends the `revision` it read as `expected_revision` (cmux-platform#1144): the
//! platform writes nothing and answers 409 `cloud_environment.revision_conflict` when the
//! environment changed since. The change is then made again on the environment as it is now, up
//! to [`MAX_TRIES`] times.
//!
//! `set-secret` and `unset-secret` need none of this: `set_secrets` and `remove_secrets` change
//! only the secrets they name, and the platform merges them.

use serde_json::{Value, json};

use super::daemon::Daemon;
use super::ops::Failure;

/// How many times one change is tried before it gives up.
pub(super) const MAX_TRIES: usize = 5;
pub(super) const CONFLICT: &str = "cloud_environment.revision_conflict";

/// Saves `change(record)` to `record`'s environment, then answers the environment as saved.
/// `change` makes this call's one change on the environment it is given and answers the patch;
/// it runs again on the current environment after a conflict.
pub(super) fn update(
    daemon: &mut dyn Daemon,
    record: &Value,
    change: impl Fn(&Value) -> Result<Value, Failure>,
) -> Result<Value, Failure> {
    let id = record
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            Failure::new("env.invalid_reply", "the environment came back without an id", 1)
        })?
        .to_owned();
    let mut current = record.clone();
    for _ in 0..MAX_TRIES {
        let mut patch = change(&current)?;
        // A platform from before revisions answers none: then the change is sent without a
        // precondition, as before, and a concurrent change to the same array can still be lost.
        if let Some(revision) = current.get("revision").filter(|revision| revision.is_number()) {
            patch["expected_revision"] = revision.clone();
        }
        match daemon.call("update", &json!({"id": id, "patch": patch})) {
            Err(failure) if failure.code == CONFLICT => {
                current = daemon.call("get", &json!({"id": id}))?;
            }
            saved => return saved,
        }
    }
    Err(Failure::new(
        CONFLICT,
        format!(
            "the environment kept changing while this change was saved ({MAX_TRIES} tries); nothing was saved, run it again"
        ),
        1,
    ))
}
