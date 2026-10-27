//! Remove and Clear of the merged history's Closed rows (cx-gzh.30). The
//! history module lists closed items (`closed:daemon:<closed id>`, read from
//! the closed-history store), so its remove and clear act on them too: one
//! behavior for every host, no host-side `closed.delete` call. The writer
//! stays the closed-history store: each delete is a `closed.delete` commit
//! (`Mux::state_delete_closed`: serialized with `closed.reopen`, recorded in
//! the mutation ledger), so a deleted group cannot be reopened by id or by
//! Cmd-Shift-T. A closed delete is permanent: no restore id, as Delete
//! Permanently.
//!
//! Each delete's mutation id derives from the history request's key and the
//! group, so a retry after a partial failure replays the deletes that
//! already committed instead of failing on them.

use std::sync::Arc;

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::Mux;
use crate::resource::ResourceError;
use crate::resource_router::resource_operation_error;
use crate::state::closed_history_delete::DeleteRequest;
use crate::workspace_registry::{Actor, WorkspaceMutation};

/// The prefix of a closed entry id (sources.rs `closed_entry`).
pub(super) const PREFIX: &str = "closed:daemon:";
const ORIGIN: &str = "cmux-history";

/// Deletes the closed groups `ids` name (`closed:daemon:<closed id>`, other
/// ids ignored), a page's row with every other close of that page (the list
/// shows a page once). A group that is already gone (reopened, deleted, aged
/// out) counts nothing. Answers how many groups it deleted.
pub(super) fn remove(
    mux: &Arc<Mux>,
    key: &str,
    actor: &Actor,
    ids: &[&str],
) -> Result<u64, ResourceError> {
    let ids: Vec<&str> = ids.iter().copied().filter(|id| id.starts_with(PREFIX)).collect();
    if ids.is_empty() {
        return Ok(0);
    }
    let items = mux
        .read_registry_state(crate::state::closed_history_query::closed_items)
        .map_err(resource_operation_error)?;
    let rows: Vec<String> =
        ids.iter().flat_map(|id| super::sources::closed_ids_of(&items, id)).collect();
    let mut groups: Vec<&str> = rows.iter().filter_map(|id| id.strip_prefix(PREFIX)).collect();
    groups.sort_unstable();
    groups.dedup();
    let mut deleted = 0;
    for group in groups.into_iter().filter(|group| !group.is_empty()) {
        let request = DeleteRequest { closed: Some(group.to_owned()), ..DeleteRequest::default() };
        match delete(mux, key, actor, group, &request) {
            Ok(count) => deleted += count,
            Err(error) if error.code == "resource.not_found" => {}
            Err(error) => return Err(error),
        }
    }
    Ok(deleted)
}

/// Deletes every closed group closed at or after `since_ms` (every group
/// when `None`). Answers how many groups it deleted.
pub(super) fn clear(
    mux: &Arc<Mux>,
    key: &str,
    actor: &Actor,
    since_ms: Option<i64>,
) -> Result<u64, ResourceError> {
    let request = DeleteRequest { all: true, since_ms, ..DeleteRequest::default() };
    // The scope names the bound: the range start moves with the clock, and a
    // retry with another bound must not meet the first commit's fingerprint.
    let scope = format!("\u{0}all\u{0}{}", since_ms.map_or(String::new(), |ms| ms.to_string()));
    delete(mux, key, actor, &scope, &request)
}

/// One `closed.delete` commit; the number of groups it deleted.
fn delete(
    mux: &Arc<Mux>,
    key: &str,
    actor: &Actor,
    scope: &str,
    request: &DeleteRequest,
) -> Result<u64, ResourceError> {
    let mut digest = Sha256::new();
    digest.update(key.as_bytes());
    digest.update([0]);
    digest.update(scope.as_bytes());
    let hash: String =
        digest.finalize().iter().take(16).map(|byte| format!("{byte:02x}")).collect();
    let mutation = WorkspaceMutation::new(format!("history-closed-{hash}"), ORIGIN, actor.clone())
        .map_err(resource_operation_error)?;
    let commit =
        mux.state_delete_closed(&mutation, None, request).map_err(resource_operation_error)?;
    Ok(commit.result.get("deleted").and_then(Value::as_array).map_or(0, |ids| ids.len() as u64))
}
