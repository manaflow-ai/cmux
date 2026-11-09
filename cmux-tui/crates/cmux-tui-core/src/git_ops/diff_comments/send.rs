//! `diff.comments.send`: one review handed to an acpmux chat as one queued
//! prompt, then the sent comments cleared.
//!
//! A key is bound to its request before anything leaves: the request's
//! fingerprint is written to a reservation file (`diff-comments/sends/<sha256
//! of the key>.json`) under a per-key lock, and a request under the same key
//! with other arguments is `idempotency.conflict` from then on. So a send
//! whose acknowledgement was lost can only be retried as itself, and acpmux's
//! duplicate acknowledgement never clears comments it did not receive.
//! Attempts under one key run one at a time; the root's lock is taken only
//! for the clear. The reservation is marked `maybe_delivered` before each
//! prompt goes out, so once an attempt may have reached acpmux (no answer
//! came, or the daemon stopped mid hand-over) a later refusal keeps it:
//! acpmux may hold that prompt id. The reservation goes once the ledger
//! holds the result, or when acpmux refused the prompt and no earlier attempt
//! under the key could have reached it.
//!
//! The acpmux prompt id is derived from the operation, this daemon session's
//! durable public id and the key, so two sessions that use the same key
//! against one chat never share a prompt id.

use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::{
    Store, acp_session, cleared, fingerprint, ids, io_failed, mutate, prompt, versions,
};
use crate::Mux;
use crate::git_ops::checkpoint::ledger;
use crate::git_ops::checkpoint::store::{hex, private_directory, read_json, write_json};
use crate::mux::agent_message_pump::Handover;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

const OPERATION: &str = "diff.comments.send";
/// The reservations' folder, under the diff comment store.
const RESERVATIONS: &str = "sends";

/// A key's reservation: the request it was first used for.
#[derive(Serialize, Deserialize)]
struct Reservation {
    key: String,
    fingerprint: Value,
    /// An attempt under the key went out with no answer: acpmux may hold
    /// its prompt id, so the key never frees until the ledger answers it.
    #[serde(default)]
    maybe_delivered: bool,
}

/// Hands the review to its acpmux session through `acp_prompt`.
pub(super) fn send(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
    root: &str,
) -> Result<Value, ResourceError> {
    send_with(mux, store, request, root, |session, prompt_id, text, meta| {
        mux.acp_prompt(session, prompt_id, text, meta)
    })
}

/// Hands `text` to the acpmux session `acp_session` through `hand_over` as
/// one queued prompt, then removes the sent comments, as a delete with the
/// same `ids` and `versions` does. Returns `{sent, cleared}`.
pub(super) fn send_with(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
    root: &str,
    hand_over: impl FnOnce(&str, &str, String, Value) -> Handover,
) -> Result<Value, ResourceError> {
    let acp_session = acp_session(&request.fields)?;
    let text = prompt(&request.fields)?;
    let ids = ids(&request.fields)?;
    if ids.is_empty() {
        return Err(ResourceError::validation_invalid(Some("ids"), "a send names at least one id"));
    }
    let versions = versions(&request.fields)?;
    let key = crate::git_ops::checkpoint::mutation_key(request);
    let fingerprint = fingerprint(request);
    let reservation = reservation_path(store, &key);
    one_attempt_per_key(&reservation, || {
        // A retry of a send that finished answers as the first did and sends nothing.
        if let Some(replayed) = ledger::prior(mux, &key, OPERATION, &fingerprint)? {
            return Ok(replayed);
        }
        let maybe_delivered = reserve(&reservation, &key, &fingerprint)?;
        // Marked before the prompt leaves, so a stop mid hand-over keeps the key bound.
        write_reservation(&reservation, &key, &fingerprint, true)?;
        // A refusal frees the key only when no attempt under it could have reached acpmux.
        let refused = |reservation: &Path| {
            if !maybe_delivered {
                release(reservation);
            }
        };
        let prompt_id = prompt_id(mux, &key);
        // Queued behind a running turn, never steered into it, and marked a
        // resend so acpmux answers a prompt id it already took, even from
        // its log, without running it again.
        let meta = json!({"steer": false, "promptId": prompt_id, "resend": true});
        match hand_over(acp_session, &prompt_id, text.to_owned(), meta) {
            Handover::Delivered => {}
            Handover::Unreachable => {
                refused(&reservation);
                let message = format!(
                    "nothing was sent: acpmux on this machine is not running or runs no \
                     session {acp_session}"
                );
                return Err(failed("no_session", message));
            }
            Handover::Failed(error) => {
                refused(&reservation);
                return Err(failed("send_failed", format!("acpmux refused the prompt: {error}")));
            }
            // The key stays bound to this request: only the same send may retry it.
            Handover::Unsettled(why) => {
                let message = format!(
                    "{why}; the agent may have taken the prompt, and a retry with the same \
                     idempotency key runs it once"
                );
                return Err(failed("send_unsettled", message));
            }
        }
        let sent = ids.len();
        let value =
            mutate(mux, store, request, root, |file, _| Ok(cleared(file, &ids, &versions, sent)))?;
        // The ledger answers the key from here on.
        release(&reservation);
        Ok(value)
    })
}

/// The acpmux prompt id of `key`'s send from this daemon session: stable
/// across retries and restarts, distinct between sessions.
pub(super) fn prompt_id(mux: &Mux, key: &str) -> String {
    let session = mux
        .workspace_registry
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .session_id()
        .as_str()
        .to_owned();
    let digest = Sha256::digest(format!("{OPERATION}\0{session}\0{key}").as_bytes());
    format!("dcs_{}", hex(digest.get(..16).unwrap_or_default()))
}

fn reservation_path(store: &Store, key: &str) -> PathBuf {
    let name = format!("{}.json", hex(&Sha256::digest(key.as_bytes())));
    store.directory.join(RESERVATIONS).join(name)
}

/// Binds `key` to `fingerprint`, or `idempotency.conflict` when it is
/// already bound to another request. Returns whether an earlier attempt
/// under the key may have reached acpmux; the caller writes the binding.
fn reserve(path: &Path, key: &str, fingerprint: &Value) -> Result<bool, ResourceError> {
    let existing: Option<Reservation> =
        read_json(path).map_err(|error| io_failed(OPERATION, &error))?;
    match existing {
        Some(reservation) if reservation.key == key && reservation.fingerprint == *fingerprint => {
            Ok(reservation.maybe_delivered)
        }
        Some(_) => Err(ResourceError::idempotency_conflict(key, OPERATION)),
        None => Ok(false),
    }
}

fn write_reservation(
    path: &Path,
    key: &str,
    fingerprint: &Value,
    maybe_delivered: bool,
) -> Result<(), ResourceError> {
    let write = || -> io::Result<()> {
        private_directory(path.parent().unwrap_or(path))?;
        let reservation =
            Reservation { key: key.to_owned(), fingerprint: fingerprint.clone(), maybe_delivered };
        write_json(path, &reservation)
    };
    write().map_err(|error| io_failed(OPERATION, &error))
}

/// Drops a reservation. A leftover one only binds its key to its first
/// request, which the ledger then does anyway.
fn release(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// Runs `body` as the only attempt of the key `reservation` stands for, in
/// every connection of this daemon.
fn one_attempt_per_key<T>(reservation: &Path, body: impl FnOnce() -> T) -> T {
    static LOCKS: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
    let locks = LOCKS.get_or_init(Mutex::default);
    let lock = locks
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .entry(reservation.to_path_buf())
        .or_default()
        .clone();
    let result = {
        let _guard = lock.lock().unwrap_or_else(PoisonError::into_inner);
        body()
    };
    // The map keeps a key's lock only while an attempt holds or waits on it.
    let mut held = locks.lock().unwrap_or_else(PoisonError::into_inner);
    if Arc::strong_count(&lock) <= 2 {
        held.remove(reservation);
    }
    result
}

fn failed(reason: &str, message: String) -> ResourceError {
    ResourceError::operation_failed(OPERATION, reason, json!({"message": message}))
}

