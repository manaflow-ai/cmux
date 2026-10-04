//! Recognizing a resource revision conflict, typed by the stores or already
//! mapped to a `ResourceError`.

use super::ResourceError;
use crate::workspace_registry::revision_conflict::RevisionConflict;

/// The expected and current revisions when `error` is a store's
/// [`RevisionConflict`].
pub(super) fn revision_conflict_values(error: &anyhow::Error) -> Option<(u64, u64)> {
    error.downcast_ref::<RevisionConflict>().map(|conflict| (conflict.expected, conflict.current))
}

/// True when `error` is a resource revision conflict, typed or as a mapped
/// `ResourceError` (the same reading as [`super::resource_operation_error`]).
pub(crate) fn is_revision_conflict(error: &anyhow::Error) -> bool {
    match error.downcast_ref::<ResourceError>() {
        Some(resource) => resource.code == "revision.conflict",
        None => revision_conflict_values(error).is_some(),
    }
}
