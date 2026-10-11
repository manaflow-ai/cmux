//! `git.checkpoint.get` and `git.checkpoint.list`. Reads never take the
//! mutation lock: records and identities are written atomically, so a read
//! sees a whole file and never waits behind a running capture.

use std::sync::Arc;

use serde_json::{Value, json};

use super::ledger::{self, Identity};
use super::record::{self, Limits};
use super::scan::{self, refused};
use super::store::{Store, io_failed};
use super::{Target, not_found, target};
use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::ParsedResourceRequest;

/// Ignored paths listed beside the candidates; the rest are only counted.
const MAX_IGNORED_LISTED: usize = 200;

pub(super) fn get(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.get";
    let by_id = request.fields.get("checkpoint_id").and_then(Value::as_str);
    let key = request.fields.get("idempotency_key").and_then(Value::as_str).unwrap_or_default();
    let asked = by_id.unwrap_or(key);
    // A repository never captured has no ids yet, and so no checkpoints.
    let Some(target) = target(mux, store, request, OPERATION, false)? else {
        return Err(not_found(asked));
    };
    let checkpoint_id = match by_id {
        Some(id) => id.to_string(),
        None => {
            let identity =
                Identity { repository_id: &target.repository_id, worktree_id: &target.worktree_id };
            ledger::created(mux, key, &identity)?.ok_or_else(|| not_found(key))?
        }
    };
    let stored = store
        .load(&target.repository_id, &checkpoint_id)
        .map_err(|error| io_failed(OPERATION, &error))?
        .ok_or_else(|| not_found(asked))?;
    Ok(serde_json::to_value(&stored.record).expect("records serialize"))
}

pub(super) fn list(
    mux: &Arc<Mux>,
    store: &Store,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    const OPERATION: &str = "git.checkpoint.list";
    // A list hands its ids to the create that follows it, so it mints them
    // the first time (under the identity lock only).
    let target = target(mux, store, request, OPERATION, true)?.expect("list mints identities");
    let limit = request.fields.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
    let after = match request.fields.get("cursor").and_then(Value::as_str) {
        Some(cursor) => Some(parse_cursor(cursor)?),
        None => None,
    };
    let mut records = store
        .all(&target.repository_id)
        .map_err(|error| io_failed(OPERATION, &error))?
        .into_iter()
        .filter(|stored| stored.record.worktree_id == target.worktree_id)
        .collect::<Vec<_>>();
    records.sort_by_key(|stored| std::cmp::Reverse(stored.order_key()));
    let mut page = records
        .into_iter()
        .filter(|stored| after.as_ref().is_none_or(|after| stored.order_key() < *after))
        .take(limit + 1)
        .collect::<Vec<_>>();
    let next_cursor = (page.len() > limit).then(|| {
        page.truncate(limit);
        let (created_at_ms, checkpoint_id) = page.last().expect("a full page").order_key();
        format!("{created_at_ms}.{checkpoint_id}")
    });
    let limits = Limits::default();
    let mut value = json!({
        "repository_id": target.repository_id,
        "worktree_id": target.worktree_id,
        "checkpoints": page.iter().map(|stored| &stored.record).collect::<Vec<_>>(),
        "next_cursor": next_cursor,
        "limits": limits,
    });
    if request.fields.get("include_candidates").and_then(Value::as_bool) == Some(true) {
        let (candidates, ignored_total) = candidates(&target, limits)?;
        value["candidates"] = candidates;
        value["ignored_total"] = json!(ignored_total);
    }
    Ok(value)
}

fn parse_cursor(cursor: &str) -> Result<(u64, String), ResourceError> {
    cursor
        .split_once('.')
        .and_then(|(created, id)| Some((created.parse().ok()?, id.to_string())))
        .ok_or_else(|| {
            ResourceError::validation_invalid(Some("cursor"), "the cursor is not one list returned")
        })
}

/// The untracked paths a create could select, with their eligibility, then
/// at most [`MAX_IGNORED_LISTED`] ignored ones, in path order, and how many
/// ignored paths there are. Only untracked, nonignored paths count against
/// `max_files`.
fn candidates(target: &Target, limits: Limits) -> Result<(Value, u32), ResourceError> {
    const OPERATION: &str = "git.checkpoint.list";
    let untracked = scan::untracked(&target.repository, OPERATION)?;
    let total = untracked.len();
    if total > limits.max_files as usize {
        let message =
            format!("{total} untracked paths are more than one list shows ({})", limits.max_files);
        let extra = json!({"candidate_total":total});
        return Err(refused(OPERATION, "budget_exceeded", message, extra));
    }
    let ignored = scan::ignored(&target.repository, OPERATION)?;
    let ignored_total = record::saturate(ignored.len() as u64);
    let mut candidates = untracked
        .iter()
        .map(|candidate| {
            let mut value = json!({
                "path": String::from_utf8_lossy(&candidate.path),
                "bytes": record::saturate(candidate.size()),
                "eligible": true,
            });
            if let Some(code) = candidate.ineligible(limits.max_untracked_file_bytes) {
                value["eligible"] = json!(false);
                value["reason"] = json!(code);
            }
            (candidate.path.clone(), value)
        })
        .collect::<Vec<_>>();
    candidates.extend(ignored.into_iter().take(MAX_IGNORED_LISTED).map(|path| {
        let value = json!({
            "path": String::from_utf8_lossy(&path),
            "bytes": 0,
            "eligible": false,
            "reason": "ignored",
        });
        (path, value)
    }));
    candidates.sort_by(|left, right| left.0.cmp(&right.0));
    let candidates = candidates.into_iter().map(|(_, value)| value).collect();
    Ok((Value::Array(candidates), ignored_total))
}
