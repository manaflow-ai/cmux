//! The daemon history module (H3; plans/cmux-next/react-pages.md 2.2-2.3,
//! decision Q1, BROWSER-PRIVATE-DATA B1-B3): the v2 operations `history.*`.
//!
//! Owner role:
//! - Page visits: one SQLite log per browser profile (crate `cmux_history`)
//!   under `<workspace state dir>/history`, shared by every session of the
//!   machine. This module is their only writer; the hosting app reports
//!   each finished main-frame navigation with `history.visit.record`.
//! - The hides of journal history (`history.hidden`, a personal frontend
//!   projection): this module is its only writer.
//! - The location trail (`history.locations`, a personal frontend
//!   projection; cx-hnmbt.12): the hosting app records each step with
//!   `history.trail.record`; this module is its only writer.
//! - The merged read model: page visits, the location trail, agent sessions
//!   folded from the session journal, the terminal command rows, and closed
//!   items from the closed-history store.
//!
//! Every delete of page visits keeps a backup and answers its restore id
//! (RECOVERABLE-BY-DEFAULT); only `history.backups.purge`, a user-origin
//! operation, deletes a backup before the 90-day retention does. A remove or
//! clear of closed items deletes them through the closed-history store
//! (`closed.delete`, permanent; closed.rs); a remove or clear of command
//! rows deletes them in the command store. Every committed change emits
//! `history-changed`.

mod closed;
mod commands;
mod hidden_doc;
mod journal_feed;
pub(crate) mod ledger;
mod merged;
mod pages;
mod sources;
mod trail;

use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;

pub(crate) use merged::HistoryHost;
use pages::run;

/// Advertised in identify: the daemon answers `history.*` and publishes
/// `history-changed`.
pub(crate) const CAPABILITY: &str = "history-v1";
/// The one history operation only the user may run (request_origin.rs
/// gate A2): it deletes the undo of a delete.
pub(crate) const PURGE_OPERATION: &str = "history.backups.purge";
/// Page visits and their titles come from the hosting app, the verified
/// app connection (origin user): a forged visit cannot come from an agent.
pub(crate) const RECORD_OPERATION: &str = "history.visit.record";
pub(crate) const TITLE_OPERATION: &str = "history.visit.title";
/// The app hands over its own visit log from before the daemon owned page
/// history, by path: only the verified app may make the daemon read a file.
pub(crate) const IMPORT_OPERATION: &str = "history.visit.import";
/// The location trail's steps come from the hosting app (the window the
/// person moved in), the verified app connection: an agent cannot add a
/// place the person never went to.
pub(crate) const TRAIL_RECORD_OPERATION: &str = "history.trail.record";

/// `history.entries.list` answers at most this many entries.
pub(crate) const MAX_LIST: usize = 5000;
/// `history.entries.remove` takes at most this many ids.
pub(crate) const MAX_IDS: usize = 1000;
const DEFAULT_LIMIT: usize = 500;

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::HistoryEntriesList
            | ResourceOperation::HistoryEntriesRemove
            | ResourceOperation::HistorySiteRemove
            | ResourceOperation::HistoryClear
            | ResourceOperation::HistoryRestore
            | ResourceOperation::HistoryBackupsPurge
            | ResourceOperation::HistoryVisitRecord
            | ResourceOperation::HistoryVisitTitle
            | ResourceOperation::HistoryVisitRemove
            | ResourceOperation::HistoryVisitSummaries
            | ResourceOperation::HistoryVisitImport
            | ResourceOperation::HistoryTrailRecord
    )
}

/// Answers one `history.*` request. Reads answer at once; a mutation runs
/// once per idempotency key (a retry answers the first result and changes
/// nothing again), then emits `history-changed` for the kinds it changed.
pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    let operation = request.envelope.operation.wire_name();
    let fields = &request.fields;
    let now_ms = now_ms();
    let day_start_ms = day_start_ms(fields, now_ms)?;
    if !request.envelope.operation.is_mutation() {
        return match request.envelope.operation {
            ResourceOperation::HistoryEntriesList => {
                merged::list(mux, fields, now_ms, day_start_ms)
            }
            _ => pages::with_stores(mux, operation, |stores| {
                run(stores, operation, fields, now_ms, day_start_ms)
            }),
        };
    }
    let key = request.envelope.idempotency_key.as_deref().ok_or_else(|| {
        ResourceError::validation_invalid(Some("idempotency_key"), "mutations need a key")
    })?;
    let fingerprint = ledger::fingerprint(operation, fields);
    // A retry answers the first result and changes nothing again.
    let actor = &request.actor;
    if ledger::seen(mux, key, operation)? {
        if operation == TRAIL_RECORD_OPERATION {
            trail::log(mux, "replayed (idempotency key seen): the first answer, no change");
        }
        return ledger::commit(mux, key, operation, &fingerprint, &Value::Null, actor);
    }
    let (value, changed) =
        merged::mutate(mux, key, actor, operation, fields, now_ms, day_start_ms)?;
    let reply = ledger::commit(mux, key, operation, &fingerprint, &value, actor)?;
    if !changed.is_empty() {
        mux.history.changed(mux, &changed);
    }
    Ok(reply)
}

/// `history.entries.list` for a test, with no request envelope.
#[cfg(test)]
pub(crate) fn list_for_test(
    mux: &Arc<Mux>,
    fields: &Map<String, Value>,
) -> Result<Value, ResourceError> {
    let now_ms = now_ms();
    merged::list(mux, fields, now_ms, local_day_start_ms(now_ms))
}

/// Saves the agent fold as if it had never been saved, the way the history
/// feed does after a fold, and returns the cursor it saved.
#[cfg(test)]
pub(crate) fn resave_agent_fold_for_test(mux: &Mux) -> u64 {
    let _turn = mux.history.turn();
    let cursor = mux.history.mark_unsaved_for_test();
    mux.history.save(mux);
    cursor
}

/// Logs a `history.trail.record` the origin rules refused on `client` (the
/// trail's failure log, cx-hnmbt.14).
pub(crate) fn log_trail_refusal(mux: &Mux, client: u64, error: &ResourceError) {
    let (code, message, details) = (&error.code, &error.message, &error.details);
    trail::log(mux, format!("refused on client {client} ({code}: {message} {details})"));
}

fn invalid(field: &str, reason: impl Into<String>) -> ResourceError {
    ResourceError::validation_invalid(Some(field), reason)
}

/// The clock the module uses.
pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
}

/// The local start of today for range `today`: the caller's
/// `local_day_start_ms` (a page knows the person's time zone), else the
/// daemon's own local midnight.
fn day_start_ms(fields: &Map<String, Value>, now_ms: i64) -> Result<i64, ResourceError> {
    match fields.get("local_day_start_ms") {
        None | Some(Value::Null) => Ok(local_day_start_ms(now_ms)),
        Some(value) => value
            .as_str()
            .and_then(|text| text.parse::<i64>().ok())
            .filter(|start| *start >= 0)
            .ok_or_else(|| {
                invalid(
                    "local_day_start_ms",
                    "local_day_start_ms must be an unsigned decimal string",
                )
            }),
    }
}

/// Local midnight of today in the daemon's time zone.
#[cfg(unix)]
fn local_day_start_ms(now_ms: i64) -> i64 {
    let secs = now_ms.div_euclid(1000) as libc::time_t;
    // SAFETY: localtime_r writes only into `tm`, which outlives the call.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are valid for the call; the result is checked.
    if unsafe { libc::localtime_r(&secs, &mut tm) }.is_null() {
        return now_ms - now_ms.rem_euclid(86_400_000);
    }
    let into_day = i64::from(tm.tm_hour) * 3600 + i64::from(tm.tm_min) * 60 + i64::from(tm.tm_sec);
    (now_ms.div_euclid(1000) - into_day) * 1000
}

/// UTC midnight: no local time zone lookup on this platform yet.
#[cfg(not(unix))]
fn local_day_start_ms(now_ms: i64) -> i64 {
    now_ms - now_ms.rem_euclid(86_400_000)
}

/// A failure of the history store as `operation.failed`.
fn store_failed(operation: &str, error: impl std::fmt::Display) -> ResourceError {
    ResourceError::operation_failed(operation, error.to_string(), json!({}))
}
