//! Raw protocol handlers for the bookmark tree of each browser profile in
//! the home session (`bookmarks-v1`, plans/cmux-next/bookmarks.md section
//! 2.1). Every mutation is one typed op (`BookmarkOp`) with an optional
//! idempotency key (`origin` + `mutation_id`); every change emits
//! `bookmarks-changed`.

use serde_json::{Value, json};

use super::Mux;
use crate::workspace_registry::{
    BookmarkImport, BookmarkImportNode, BookmarkOp, WorkspaceMutation, invalid_bookmark,
};

pub(super) fn list(mux: &Mux, profile: &str) -> anyhow::Result<Value> {
    let (revision, bookmarks) = mux.list_bookmarks(profile)?;
    Ok(json!({"bookmarks_revision": revision, "bookmarks": bookmarks}))
}

/// The idempotency key of a mutation: both halves or neither.
pub(super) fn mutation_key(
    origin: Option<String>,
    mutation_id: Option<String>,
) -> anyhow::Result<Option<WorkspaceMutation>> {
    match (origin, mutation_id) {
        (None, None) => Ok(None),
        (Some(origin), Some(mutation_id)) => WorkspaceMutation::new(mutation_id, origin)
            .map(Some)
            .map_err(|error| invalid_bookmark(error.to_string())),
        _ => Err(invalid_bookmark("origin and mutation_id must be given together")),
    }
}

pub(super) fn apply(
    mux: &Mux,
    origin: Option<String>,
    mutation_id: Option<String>,
    op: BookmarkOp,
) -> anyhow::Result<Value> {
    let key = mutation_key(origin, mutation_id)?;
    let (result, _) = mux.bookmarks_mutation(|registry| {
        let outcome = registry.apply_bookmark_op(key.as_ref(), op)?;
        Ok((outcome.result, outcome.changed))
    })?;
    Ok(result)
}

/// Decode the nodes of `import-bookmarks` into its op.
pub(super) fn import_op(
    browser_profile_id: String,
    parent: String,
    index: Option<usize>,
    source_key: Option<String>,
    replace: bool,
    nodes: Vec<Value>,
) -> anyhow::Result<BookmarkOp> {
    let nodes = nodes
        .into_iter()
        .map(serde_json::from_value::<BookmarkImportNode>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| invalid_bookmark(format!("invalid node: {error}")))?;
    Ok(BookmarkOp::Import(BookmarkImport {
        browser_profile_id,
        parent,
        index,
        source_key,
        replace,
        nodes,
    }))
}
