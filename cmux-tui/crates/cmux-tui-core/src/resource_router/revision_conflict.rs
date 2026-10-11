//! Reading a registry revision conflict, typed or as the stores raise it.

use super::ResourceError;

/// The expected and current revisions of a registry revision conflict,
/// which the stores raise as "resource revision conflict: expected E,
/// current C".
pub(super) fn revision_conflict_values(message: &str) -> Option<(u64, u64)> {
    let conflict = message.strip_prefix("resource revision conflict: expected ")?;
    let (expected, actual) = conflict.split_once(", current ")?;
    Some((expected.parse().ok()?, actual.parse().ok()?))
}

/// True when `error` is a resource revision conflict, typed or as the
/// stores raise it (the same reading as [`super::resource_operation_error`]).
pub(crate) fn is_revision_conflict(error: &anyhow::Error) -> bool {
    match error.downcast_ref::<ResourceError>() {
        Some(resource) => resource.code == "revision.conflict",
        None => revision_conflict_values(&error.to_string()).is_some(),
    }
}
