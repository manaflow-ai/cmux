//! Raw protocol handlers for the bookmark tree of each browser profile in
//! the home session (`bookmarks-v1`, plans/cmux-next/bookmarks.md section
//! 2.1). Every change emits `bookmarks-changed`.

use serde_json::{Value, json};

use super::Mux;
use crate::workspace_registry::{
    BookmarkImport, BookmarkImportNode, BookmarkInput, BookmarkUpdate, invalid_bookmark,
};

pub(super) fn list(mux: &Mux, profile: &str) -> anyhow::Result<Value> {
    let (revision, bookmarks) = mux.list_bookmarks(profile)?;
    Ok(json!({"bookmarks_revision": revision, "bookmarks": bookmarks}))
}

pub(super) fn create(mux: &Mux, input: BookmarkInput) -> anyhow::Result<Value> {
    let (bookmark, changed) = mux.bookmarks_mutation(|registry| {
        let (bookmark, changed) = registry.create_bookmark(input)?;
        let profile = changed.then(|| bookmark.browser_profile_id.clone());
        Ok((bookmark, profile))
    })?;
    Ok(json!({"bookmark": bookmark, "changed": changed}))
}

pub(super) fn update(mux: &Mux, id: &str, update: BookmarkUpdate) -> anyhow::Result<Value> {
    let (bookmark, changed) = mux.bookmarks_mutation(|registry| {
        let (bookmark, changed) = registry.update_bookmark(id, update)?;
        let profile = changed.then(|| bookmark.browser_profile_id.clone());
        Ok((bookmark, profile))
    })?;
    Ok(json!({"bookmark": bookmark, "changed": changed}))
}

pub(super) fn move_to(mux: &Mux, id: &str, parent: &str, index: usize) -> anyhow::Result<Value> {
    let (bookmark, changed) = mux.bookmarks_mutation(|registry| {
        let (bookmark, changed) = registry.move_bookmark(id, parent, index)?;
        let profile = changed.then(|| bookmark.browser_profile_id.clone());
        Ok((bookmark, profile))
    })?;
    Ok(json!({"bookmark": bookmark, "changed": changed}))
}

pub(super) fn delete(mux: &Mux, id: &str) -> anyhow::Result<Value> {
    let (deletion, _) = mux.bookmarks_mutation(|registry| {
        let deletion = registry.delete_bookmark(id)?;
        let profile = Some(deletion.browser_profile_id.clone());
        Ok((deletion, profile))
    })?;
    Ok(json!({"deleted": deletion.deleted}))
}

pub(super) fn import(
    mux: &Mux,
    browser_profile_id: String,
    parent: String,
    index: Option<usize>,
    source_key: Option<String>,
    replace: bool,
    nodes: Vec<Value>,
) -> anyhow::Result<Value> {
    let nodes = nodes
        .into_iter()
        .map(serde_json::from_value::<BookmarkImportNode>)
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| invalid_bookmark(format!("invalid node: {error}")))?;
    let import = BookmarkImport { browser_profile_id, parent, index, source_key, replace, nodes };
    let (result, _) = mux.bookmarks_mutation(|registry| {
        let result = registry.import_bookmarks(import)?;
        let profile = Some(result.browser_profile_id.clone());
        Ok((result, profile))
    })?;
    Ok(json!({"root_ids": result.root_ids, "count": result.count}))
}
