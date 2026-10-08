//! Raw protocol handlers for the bookmark tree of each browser profile in
//! the home session (`bookmarks-v1`, plans/cmux-next/bookmarks.md section
//! 2.1). Every mutation is one typed op (`BookmarkOp`) with an optional
//! idempotency key (`origin` + `mutation_id`); every change emits
//! `bookmarks-changed`.

use serde::Deserialize;
use serde_json::{Value, json};

use super::Mux;
use crate::workspace_registry::WorkspaceMutation;
use crate::workspace_registry::personal_bookmarks::{
    BookmarkError, BookmarkImport, BookmarkImportNode, BookmarkInput, BookmarkOp, BookmarkUpdate,
    invalid_bookmark,
};

/// One bookmark tree per browser profile in the home session: the
/// `*-bookmark` commands, `list-bookmarks`, `import-bookmarks` and the
/// `bookmarks-changed` event (plans/cmux-next/bookmarks.md section 2.1).
pub const BOOKMARKS_CAPABILITY: &str = "bookmarks-v1";

/// `list-bookmarks`.
#[derive(Deserialize)]
pub(super) struct ListParams {
    browser_profile_id: String,
}

/// The idempotency key every mutation takes: both halves or neither.
#[derive(Deserialize)]
struct Key {
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
}

/// `create-bookmark`. A caller-chosen `bookmark` id makes a retry return the
/// stored node. (`id` is the request envelope's.)
#[derive(Deserialize)]
pub(super) struct CreateParams {
    #[serde(flatten)]
    key: Key,
    browser_profile_id: String,
    parent: String,
    kind: String,
    title: String,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    favicon_key: Option<String>,
    #[serde(default)]
    source_key: Option<String>,
    #[serde(default)]
    created_ms: Option<u64>,
    #[serde(default)]
    bookmark: Option<String>,
}

/// `update-bookmark`. An absent field is unchanged; JSON null clears
/// `favicon_key` or `last_used_ms`.
#[derive(Deserialize)]
pub(super) struct UpdateParams {
    #[serde(flatten)]
    key: Key,
    bookmark: String,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default, deserialize_with = "super::present_nullable")]
    favicon_key: Option<Option<String>>,
    #[serde(default, deserialize_with = "super::present_nullable")]
    last_used_ms: Option<Option<u64>>,
}

/// `move-bookmark`: a final index under a parent of the same profile.
#[derive(Deserialize)]
pub(super) struct MoveParams {
    #[serde(flatten)]
    key: Key,
    bookmark: String,
    parent: String,
    index: usize,
}

/// `delete-bookmark`: the node and its subtree.
#[derive(Deserialize)]
pub(super) struct DeleteParams {
    #[serde(flatten)]
    key: Key,
    bookmark: String,
}

/// `import-bookmarks`: one tree in one transaction.
#[derive(Deserialize)]
pub(super) struct ImportParams {
    #[serde(flatten)]
    key: Key,
    browser_profile_id: String,
    parent: String,
    #[serde(default)]
    index: Option<usize>,
    #[serde(default)]
    source_key: Option<String>,
    #[serde(default)]
    replace: bool,
    nodes: Vec<Value>,
}

/// The `error_code` of a refused bookmark command.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<BookmarkError>().map(|error| error.code().to_string())
}

pub(super) fn list(mux: &Mux, params: ListParams) -> anyhow::Result<Value> {
    let (revision, bookmarks) = mux.list_bookmarks(&params.browser_profile_id)?;
    Ok(json!({"bookmarks_revision": revision, "bookmarks": bookmarks}))
}

pub(super) fn create(mux: &Mux, params: CreateParams) -> anyhow::Result<Value> {
    let input = BookmarkInput {
        id: params.bookmark,
        browser_profile_id: params.browser_profile_id,
        parent: params.parent,
        index: params.index,
        kind: params.kind,
        title: params.title,
        url: params.url,
        favicon_key: params.favicon_key,
        source_key: params.source_key,
        created_ms: params.created_ms,
    };
    apply(mux, params.key, BookmarkOp::Create(input))
}

pub(super) fn update(mux: &Mux, params: UpdateParams) -> anyhow::Result<Value> {
    let update = BookmarkUpdate {
        title: params.title,
        url: params.url,
        favicon_key: params.favicon_key,
        last_used_ms: params.last_used_ms,
    };
    apply(mux, params.key, BookmarkOp::Update { bookmark: params.bookmark, update })
}

pub(super) fn move_to(mux: &Mux, params: MoveParams) -> anyhow::Result<Value> {
    let op =
        BookmarkOp::Move { bookmark: params.bookmark, parent: params.parent, index: params.index };
    apply(mux, params.key, op)
}

pub(super) fn delete(mux: &Mux, params: DeleteParams) -> anyhow::Result<Value> {
    apply(mux, params.key, BookmarkOp::Delete { bookmark: params.bookmark })
}

pub(super) fn import(mux: &Mux, params: ImportParams) -> anyhow::Result<Value> {
    let nodes = params
        .nodes
        .into_iter()
        .map(serde_json::from_value::<BookmarkImportNode>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| invalid_bookmark(format!("invalid node: {error}")))?;
    let import = BookmarkImport {
        browser_profile_id: params.browser_profile_id,
        parent: params.parent,
        index: params.index,
        source_key: params.source_key,
        replace: params.replace,
        nodes,
    };
    apply(mux, params.key, BookmarkOp::Import(import))
}

fn apply(mux: &Mux, key: Key, op: BookmarkOp) -> anyhow::Result<Value> {
    let key = match (key.origin, key.mutation_id) {
        (None, None) => None,
        (Some(origin), Some(mutation_id)) => Some(
            WorkspaceMutation::daemon(mutation_id, origin)
                .map_err(|error| invalid_bookmark(error.to_string()))?,
        ),
        _ => return Err(invalid_bookmark("origin and mutation_id must be given together")),
    };
    let (result, _) = mux.bookmarks_mutation(|registry| {
        let outcome = registry.apply_bookmark_op(key.as_ref(), op)?;
        Ok((outcome.result, outcome.changed))
    })?;
    Ok(result)
}

#[cfg(test)]
#[path = "bookmark_tests.rs"]
mod tests;
