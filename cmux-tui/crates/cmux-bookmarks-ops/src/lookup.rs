//! What the app reads from one profile's tree beyond a listing
//! (plans/cmux-next/bookmarks.md section 3): a node's place (its folder
//! path), the omnibar star's and the bookmarks bar's status for the pages
//! a window shows, the folder choices of the edit bubble, how the CLI and
//! MCP name a bookmark or a folder, an import's undo draft and an older
//! build's `bookmarks.json`. The app keeps no copy of the tree: it asks the
//! daemon, which answers with these.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

use crate::search::{display_text, parse_typed, rank, search, url_key};
use cmux_bookmarks_core::{
    BOOKMARKS_BAR, Bookmark, BookmarkImportNode, BookmarkInput, BookmarkOp, BookmarkUpdate,
    MAX_BOOKMARK_DEPTH, OTHER_BOOKMARKS, Tree, is_root,
};

/// The titles from `id`'s root to its parent: the root's id (`bar` or
/// `other`) first, then each folder's title; empty for an unknown id.
pub fn path(tree: &Tree, id: &str) -> Vec<String> {
    let mut path = Vec::new();
    let Some(node) = tree.get(id) else { return path };
    let mut current = node.parent.as_str();
    // A parent chain is at most the depth limit; the bound keeps a damaged chain finite.
    for _ in 0..=MAX_BOOKMARK_DEPTH {
        if is_root(current) {
            path.push(current.to_string());
            break;
        }
        let Some(folder) = tree.get(current) else { break };
        path.push(folder.title.clone());
        current = folder.parent.as_str();
    }
    path.reverse();
    path
}

/// A node's row with its place: the stored fields, `path` ([`path`]) and,
/// for a link, `display_url` (the URL as a list shows it).
pub fn placed(tree: &Tree, node: &Bookmark) -> Value {
    let mut row = serde_json::to_value(node).unwrap_or(Value::Null);
    if let Some(object) = row.as_object_mut() {
        object.insert("path".into(), Value::from(path(tree, &node.id)));
        if let Some(url) = &node.url {
            object.insert("display_url".into(), Value::from(display_text(url)));
        }
    }
    row
}

/// The bookmarks bar has something to show: an item of its own, or Other
/// Bookmarks (its trailing button). An empty bar takes no room (#38046).
pub fn bar_filled(tree: &Tree) -> bool {
    !tree.children(BOOKMARKS_BAR).is_empty() || !tree.children(OTHER_BOOKMARKS).is_empty()
}

/// For each of `urls`, the ids of the links to the same page
/// ([`url_key`]), in listing order: the omnibar star of a tab on that
/// page is on when there is one, and edits the first.
pub fn matches(tree: &Tree, urls: &[String]) -> Vec<Vec<String>> {
    let wanted = urls.iter().map(|url| url_key(url)).collect::<Vec<_>>();
    let mut found = wanted.iter().map(|key| (key.as_str(), Vec::new())).collect::<HashMap<_, _>>();
    for node in tree.listing() {
        let Some(url) = node.url.as_deref() else { continue };
        if let Some(ids) = found.get_mut(url_key(url).as_str()) {
            ids.push(node.id);
        }
    }
    wanted.iter().map(|key| found.get(key.as_str()).cloned().unwrap_or_default()).collect()
}

/// One folder a bookmark can go to, indented by `depth` below its root.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct FolderChoice {
    pub id: String,
    pub title: String,
    pub depth: usize,
}

/// Every folder in tree order, each root first (the app names the roots):
/// the edit bubble's Folder menu.
pub fn folders(tree: &Tree, bar_title: &str, other_title: &str) -> Vec<FolderChoice> {
    let mut choices = Vec::new();
    for (root, title) in [(BOOKMARKS_BAR, bar_title), (OTHER_BOOKMARKS, other_title)] {
        choices.push(FolderChoice { id: root.to_string(), title: title.to_string(), depth: 0 });
        let mut stack =
            tree.children(root).into_iter().rev().map(|node| (node, 1usize)).collect::<Vec<_>>();
        while let Some((node, depth)) = stack.pop() {
            if node.kind != "folder" {
                continue;
            }
            choices.push(FolderChoice { id: node.id.clone(), title: node.title.clone(), depth });
            if depth < MAX_BOOKMARK_DEPTH {
                stack.extend(
                    tree.children(&node.id).into_iter().rev().map(|child| (child, depth + 1)),
                );
            }
        }
    }
    choices
}

/// Why a name was not resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unresolved {
    /// No bookmark has that id, URL or text.
    NotFound,
    /// The folder argument names no root or folder.
    NotFolder,
    /// The URL argument is not one a bookmark may hold.
    InvalidUrl,
}

impl Unresolved {
    pub fn code(self) -> &'static str {
        match self {
            Self::NotFound => "not_found",
            Self::NotFolder => "not_folder",
            Self::InvalidUrl => "invalid_url",
        }
    }
}

/// The bookmark `text` names, the way the CLI and MCP name one: an id, else
/// a link to the same page when it is an absolute URL, else (with
/// `folders_first`, for the folder icon actions) a folder of that title in
/// any case, else the omnibar's best match, else the first node whose title
/// or URL holds every word.
pub fn find(tree: &Tree, text: &str, folders_first: bool, now_ms: u64) -> Option<Bookmark> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if let Some(node) = tree.get(text) {
        return Some(node.clone());
    }
    let listing = tree.listing();
    if folders_first {
        let folded = text.to_lowercase();
        if let Some(folder) =
            listing.iter().find(|node| node.kind == "folder" && node.title.to_lowercase() == folded)
        {
            return Some(folder.clone());
        }
    }
    if cmux_bookmarks_core::has_url_scheme(text) {
        let key = url_key(text);
        if let Some(link) =
            listing.iter().find(|node| node.url.as_deref().is_some_and(|url| url_key(url) == key))
        {
            return Some(link.clone());
        }
    }
    if let Some(best) = rank(&listing, text, now_ms, 1).into_iter().next() {
        return Some(best.bookmark);
    }
    search(tree, text).into_iter().next()
}

/// The bookmark `text` names exactly: an id, else a link to the same page
/// when it is an absolute URL. No title or text match: the app asks this for
/// the focused page, so a page with no bookmark of its own names none (a
/// substring match would name another page's bookmark).
pub fn find_exact(tree: &Tree, text: &str) -> Option<Bookmark> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if let Some(node) = tree.get(text) {
        return Some(node.clone());
    }
    if !cmux_bookmarks_core::has_url_scheme(text) {
        return None;
    }
    let key = url_key(text);
    tree.listing()
        .into_iter()
        .find(|node| node.url.as_deref().is_some_and(|url| url_key(url) == key))
}

/// The folder `text` names: `bar`, `other`, a folder id, a root's title or a
/// folder's title (the first in tree order, any case). No text is the
/// `fallback` (the last folder used) while it is still a folder, else the bar.
pub fn folder(
    tree: &Tree,
    text: Option<&str>,
    fallback: Option<&str>,
    bar_title: &str,
    other_title: &str,
) -> Result<String, Unresolved> {
    let container =
        |id: &str| is_root(id) || tree.get(id).is_some_and(|node| node.kind == "folder");
    let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
        return Ok(fallback.filter(|id| container(id)).unwrap_or(BOOKMARKS_BAR).to_string());
    };
    if container(text) {
        return Ok(text.to_string());
    }
    let folded = text.to_lowercase();
    if folded == bar_title.to_lowercase() {
        return Ok(BOOKMARKS_BAR.to_string());
    }
    if folded == other_title.to_lowercase() {
        return Ok(OTHER_BOOKMARKS.to_string());
    }
    tree.listing()
        .into_iter()
        .find(|node| node.kind == "folder" && node.title.to_lowercase() == folded)
        .map(|node| node.id)
        .ok_or(Unresolved::NotFolder)
}

/// A URL the person typed (`example.com` takes `https://`), or the refusal.
pub fn typed_url(text: &str) -> Result<String, Unresolved> {
    parse_typed(text).ok_or(Unresolved::InvalidUrl)
}

/// The folder an import of `source_key` made, as import nodes that put it
/// back as it is now (an import's undo); `None` when there is none.
pub fn source_draft(tree: &Tree, source_key: &str) -> Option<BookmarkImportNode> {
    let folder = tree
        .listing()
        .into_iter()
        .find(|node| node.kind == "folder" && node.source_key.as_deref() == Some(source_key))?;
    Some(draft(tree, &folder, 1))
}

fn draft(tree: &Tree, node: &Bookmark, depth: usize) -> BookmarkImportNode {
    let children = (node.kind == "folder").then(|| {
        if depth >= MAX_BOOKMARK_DEPTH {
            return Vec::new();
        }
        tree.children(&node.id).into_iter().map(|child| draft(tree, child, depth + 1)).collect()
    });
    BookmarkImportNode {
        kind: node.kind.clone(),
        title: node.title.clone(),
        url: node.url.clone(),
        created_ms: Some(node.created_ms),
        children,
    }
}

/// One op of an older build's file copy, with its replay key.
#[derive(Debug, Clone)]
pub struct LegacyOp {
    pub key: String,
    pub op: BookmarkOp,
}

/// The ops that copy one batch of an older build's `bookmarks.json` into
/// `profile`, node by node in the batch's order with the same ids and each
/// node's `index` among its siblings in the file (the app reads the file and
/// sends it in bounded batches, parents first). A copy that stopped resumes
/// whatever its batches: a create with a stored id changes nothing, and each
/// op has a stable key (`migrate-file-<id>.create`, `.used` for its last use).
pub fn legacy_nodes(profile: &str, nodes: Vec<Bookmark>) -> Vec<LegacyOp> {
    let mut ops = Vec::with_capacity(nodes.len());
    for node in nodes {
        let key = format!("migrate-file-{}", node.id);
        ops.push(LegacyOp { key: format!("{key}.create"), op: create(profile, &node, node.index) });
        if let Some(used) = node.last_used_ms {
            let update =
                BookmarkUpdate { last_used_ms: Some(Some(used)), ..BookmarkUpdate::default() };
            ops.push(LegacyOp {
                key: format!("{key}.used"),
                op: BookmarkOp::Update { bookmark: node.id.clone(), update },
            });
        }
    }
    ops
}

fn create(profile: &str, node: &Bookmark, index: usize) -> BookmarkOp {
    BookmarkOp::Create(BookmarkInput {
        id: Some(node.id.clone()),
        browser_profile_id: profile.to_string(),
        parent: node.parent.clone(),
        index: Some(index),
        kind: node.kind.clone(),
        title: node.title.clone(),
        url: node.url.clone(),
        favicon_key: node.favicon_key.clone(),
        source_key: node.source_key.clone(),
        created_ms: Some(node.created_ms),
    })
}
