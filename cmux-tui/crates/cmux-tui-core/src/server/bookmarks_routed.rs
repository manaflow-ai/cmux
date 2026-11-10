//! The routed `bookmarks` namespace (page-router.md "Routed namespaces"):
//! the Bookmarks page, the app's import and export, and its search reach
//! one browser profile's tree in the home session with the v2 envelope.
//! Every op is one of the `bookmarks-v1` commands' rules
//! (cmux-bookmarks-core), so the page, the CLI and the app's bar follow one
//! rule set:
//!
//! - `bookmarks.list {browser_profile_id}`: `{bookmarks_revision, bookmarks}`
//!   in listing order (as `list-bookmarks`).
//! - `bookmarks.children {browser_profile_id, parent, depth?, limit?}`:
//!   `{bookmarks_revision, bookmarks, total, truncated}`, the nodes under one
//!   root or folder down to `depth` levels (1, its children, by default) in
//!   listing order, at most `limit`; `total` counts the parent's own
//!   children. The bookmarks bar reads what it draws with it, so its cost
//!   follows the bar, not the whole tree.
//! - `bookmarks.search {browser_profile_id, text, limit?}`: `{bookmarks}`,
//!   nodes whose title or URL holds every term, tree order. `text` is at
//!   most 1 KiB and 32 terms (also for `rank`).
//! - `places: true` on `list`, `children` and `search`: each row also has
//!   `path` (its root's id, then its folders' titles) and, for a link,
//!   `display_url` (cmux-bookmarks-ops `lookup::placed`).
//! - `bookmarks.get {browser_profile_id, ids}`: `{bookmarks_revision,
//!   bookmarks}`, the placed rows of at most 1000 ids that exist.
//! - `bookmarks.status {browser_profile_id, urls}`: `{bookmarks_revision,
//!   bar_filled, matches}`, whether the bookmarks bar has anything to show
//!   and, per URL (at most 1000), the ids of links to the same page: the
//!   app's omnibar stars and bars read this, never a copy of the tree.
//! - `bookmarks.folders {browser_profile_id, bar_title, other_title}`:
//!   `{bookmarks_revision, folders: [{id, title, depth}]}`, the roots and
//!   every folder in tree order (the edit bubble's Folder menu).
//! - `bookmarks.resolve {browser_profile_id, bookmark?, folders_first?,
//!   exact?, folder?, fallback_folder?, url?, bar_title, other_title}`: what
//!   the CLI and MCP name, `{bookmark?, folder?, url?}` (each asked for):
//!   the placed node `bookmark` names (`lookup::find`; with `exact`, only an
//!   id or a link to the same page, `lookup::find_exact`, as for the focused
//!   page the app names when no argument does), the folder
//!   `folder` names (`lookup::folder`) and the URL `url` was typed as. A
//!   name that resolves to nothing is `bookmarks.not_found`,
//!   `bookmarks.not_folder` or `bookmarks.invalid_url`.
//! - `bookmarks.rank {browser_profile_id, text, limit?}`: `{matches: [{bookmark,
//!   score}]}`, URL bookmarks the omnibar way, best first, one per page.
//! - `bookmarks.export {browser_profile_id, bar_title}`: `{html, count}`, the
//!   Netscape file of the tree.
//! - `bookmarks.apply {ops}` (mutation): each op (`{"op": "create" | "update" |
//!   "move" | "delete" | "import", ...}`, the replay fingerprint shape) in turn,
//!   each keyed `<idempotency_key>.<n>` so a retry replays; `{results}`. A
//!   refusal stops there: the ops before it stay applied and the error's
//!   `details.extra.applied` counts them.
//! - `bookmarks.import_html {browser_profile_id, html, folder_title, bar_title}`
//!   (mutation): the file into one new folder at the end of the bar.
//! - `bookmarks.import_source {browser_profile_id, title, source_key, items}`
//!   (mutation): one browser source's folder, replaced in place; no items
//!   removes it. `{root_ids, count, added, duplicates, skipped, replayed,
//!   previous}` (`skipped`: items whose URL the store would refuse;
//!   `previous`: the source's folder before, as one import node that puts it
//!   back, or null, on a removal too); a removal also has `deleted`.
//! - `bookmarks.import_legacy_file {browser_profile_id, nodes}` (mutation):
//!   one batch of an older build's `bookmarks.json`, at most 256 of its rows
//!   (each with its `index` among its siblings in the file), node by node
//!   with its ids and a stable key per node. The app reads the file and sends
//!   it as an ordered stream of these batches, parents first, each well under
//!   the 4 MiB message cap, and deletes the file after the last one: a copy
//!   that stopped resumes from the start with no duplicate. `{ops}`.

use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

use super::Mux;
use crate::Actor;
use crate::resource::ResourceError;
use crate::workspace_registry::WorkspaceMutation;
use crate::workspace_registry::personal_bookmarks::{BookmarkError, BookmarkOp};
use cmux_bookmarks_core::Tree;
use cmux_bookmarks_ops::import_plan::{self, SourceItem};
use cmux_bookmarks_ops::lookup::{self, Unresolved};
use cmux_bookmarks_ops::{netscape, search};

/// The routed owner's name in spec/page-router.json.
pub(super) const OWNER: &str = "bookmarks.tree";
/// Most rows `bookmarks.search` and `bookmarks.rank` return.
const MAX_LIMIT: usize = 1000;
/// Most ops in one `bookmarks.apply`.
const MAX_OPS: usize = 256;
/// The ledger's bound on a replay key (`validate_identifier`).
const MAX_KEY_BYTES: usize = 128;
/// The prefix of a hashed per-op key ([`op_key`]).
const HASHED_KEY_PREFIX: &str = "sha256:";
/// Most bytes of a search or rank query.
const MAX_QUERY_BYTES: usize = 1024;
/// Most rows one `bookmarks.children` returns (a folder menu's subtree).
const MAX_CHILDREN_LIMIT: usize = 20_000;
/// Most ids of one `bookmarks.get`, and URLs of one `bookmarks.status`.
const MAX_LOOKUPS: usize = 1000;
/// The replay origin of routed bookmark ops.
const REPLAY_ORIGIN: &str = "bookmarks.routed";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct List {
    browser_profile_id: String,
    #[serde(default)]
    places: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Query {
    browser_profile_id: String,
    text: String,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    places: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Get {
    browser_profile_id: String,
    ids: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Status {
    browser_profile_id: String,
    urls: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Folders {
    browser_profile_id: String,
    bar_title: String,
    other_title: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resolve {
    browser_profile_id: String,
    #[serde(default)]
    bookmark: Option<String>,
    #[serde(default)]
    folders_first: bool,
    /// Only an id or a link to the same page names the bookmark.
    #[serde(default)]
    exact: bool,
    /// Present (even null) asks for a folder: null is the default folder.
    #[serde(default, deserialize_with = "present")]
    folder: Option<Option<String>>,
    #[serde(default)]
    fallback_folder: Option<String>,
    #[serde(default)]
    url: Option<String>,
    bar_title: String,
    other_title: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyFile {
    browser_profile_id: String,
    /// At most [`MAX_OPS`] rows of the file, in its order.
    nodes: Vec<cmux_bookmarks_core::Bookmark>,
    /// Every mutation carries one; this op keys each node by its id instead
    /// (`lookup::legacy_nodes`), so a copy that stopped replays what it did.
    #[serde(rename = "idempotency_key")]
    _idempotency_key: String,
}

/// An absent field is `None`; a present one, null included, is `Some`.
fn present<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(deserializer).map(Some)
}

impl Query {
    /// A query is at most [`MAX_QUERY_BYTES`] and
    /// [`search::MAX_TERMS`] terms: each one is matched against every node.
    fn check(&self) -> Result<(), ResourceError> {
        if self.text.len() > MAX_QUERY_BYTES {
            return Err(ResourceError::validation_invalid(
                Some("text"),
                format!("at most {MAX_QUERY_BYTES} bytes"),
            ));
        }
        if self.text.split_whitespace().count() > search::MAX_TERMS {
            return Err(ResourceError::validation_invalid(
                Some("text"),
                format!("at most {} terms", search::MAX_TERMS),
            ));
        }
        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Children {
    browser_profile_id: String,
    parent: String,
    #[serde(default)]
    depth: Option<usize>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    places: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Export {
    browser_profile_id: String,
    bar_title: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Apply {
    ops: Vec<BookmarkOp>,
    idempotency_key: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportHtml {
    browser_profile_id: String,
    html: String,
    folder_title: String,
    bar_title: String,
    idempotency_key: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportSource {
    browser_profile_id: String,
    title: String,
    source_key: String,
    items: Vec<SourceItem>,
    idempotency_key: String,
}

/// Runs one routed `bookmarks.*` operation for `client`.
pub(super) fn routed(
    mux: &Mux,
    client: u64,
    operation: &str,
    params: Map<String, Value>,
) -> Result<Value, ResourceError> {
    let params = Value::Object(params);
    match operation {
        "bookmarks.list" => {
            let List { browser_profile_id, places } = parse(params)?;
            let (revision, tree) = read(mux, operation, &browser_profile_id)?;
            let rows = rows(&tree, tree.listing(), places);
            Ok(json!({"bookmarks_revision": revision, "bookmarks": rows}))
        }
        "bookmarks.get" => {
            let Get { browser_profile_id, ids } = parse(params)?;
            bounded("ids", ids.len())?;
            let (revision, tree) = read(mux, operation, &browser_profile_id)?;
            let rows = ids
                .iter()
                .filter_map(|id| tree.get(id))
                .map(|node| lookup::placed(&tree, node))
                .collect::<Vec<_>>();
            Ok(json!({"bookmarks_revision": revision, "bookmarks": rows}))
        }
        "bookmarks.status" => {
            let Status { browser_profile_id, urls } = parse(params)?;
            bounded("urls", urls.len())?;
            let (revision, tree) = read(mux, operation, &browser_profile_id)?;
            Ok(json!({
                "bookmarks_revision": revision,
                "bar_filled": lookup::bar_filled(&tree),
                "matches": lookup::matches(&tree, &urls),
            }))
        }
        "bookmarks.folders" => {
            let request: Folders = parse(params)?;
            let (revision, tree) = read(mux, operation, &request.browser_profile_id)?;
            let folders = lookup::folders(&tree, &request.bar_title, &request.other_title);
            Ok(json!({"bookmarks_revision": revision, "folders": folders}))
        }
        "bookmarks.resolve" => {
            let request: Resolve = parse(params)?;
            let (_, tree) = read(mux, operation, &request.browser_profile_id)?;
            resolve(&tree, request).map_err(|unresolved| unresolved_error(operation, unresolved))
        }
        "bookmarks.children" => {
            let request: Children = parse(params)?;
            let (revision, tree) = read(mux, operation, &request.browser_profile_id)?;
            let depth =
                request.depth.unwrap_or(1).clamp(1, cmux_bookmarks_core::MAX_BOOKMARK_DEPTH);
            let limit = request.limit.unwrap_or(MAX_LIMIT).min(MAX_CHILDREN_LIMIT);
            let (bookmarks, truncated) =
                subtree(&tree, &request.parent, depth, limit, request.places);
            Ok(json!({
                "bookmarks_revision": revision,
                "bookmarks": bookmarks,
                "total": tree.children(&request.parent).len(),
                "truncated": truncated,
            }))
        }
        "bookmarks.search" => {
            let query: Query = parse(params)?;
            query.check()?;
            let (_, tree) = read(mux, operation, &query.browser_profile_id)?;
            let mut found = search::search(&tree, &query.text);
            found.truncate(limit(query.limit));
            Ok(json!({"bookmarks": rows(&tree, found, query.places)}))
        }
        "bookmarks.rank" => {
            let query: Query = parse(params)?;
            query.check()?;
            let (_, tree) = read(mux, operation, &query.browser_profile_id)?;
            let listing = tree.listing();
            let matches = search::rank(&listing, &query.text, now_ms(), limit(query.limit));
            Ok(json!({"matches": matches}))
        }
        "bookmarks.export" => {
            let export: Export = parse(params)?;
            let (_, tree) = read(mux, operation, &export.browser_profile_id)?;
            Ok(json!({"html": netscape::write(&tree, &export.bar_title), "count": tree.len()}))
        }
        "bookmarks.apply" => {
            let apply: Apply = parse(params)?;
            if apply.ops.len() > MAX_OPS {
                return Err(ResourceError::validation_invalid(
                    Some("ops"),
                    format!("at most {MAX_OPS} ops at once"),
                ));
            }
            let actor = super::origin_gate::connection_actor(mux, client);
            let mut results = Vec::with_capacity(apply.ops.len());
            for (index, op) in apply.ops.into_iter().enumerate() {
                let key = op_key(&apply.idempotency_key, index);
                match one(mux, &actor, &key, op) {
                    Ok(result) => results.push(result),
                    Err(error) => return Err(failure(operation, &error, Some(index))),
                }
            }
            Ok(json!({"results": results}))
        }
        "bookmarks.import_html" => {
            let import: ImportHtml = parse(params)?;
            let Some(plan) = import_plan::html(
                &import.browser_profile_id,
                &import.html,
                &import.folder_title,
                &import.bar_title,
            )
            .map_err(|error| failure(operation, &error.into(), None))?
            else {
                return Err(ResourceError::operation_failed(
                    operation,
                    "the file holds no bookmarks",
                    json!({"code": "bookmarks.empty"}),
                ));
            };
            let actor = super::origin_gate::connection_actor(mux, client);
            one(mux, &actor, &import.idempotency_key, BookmarkOp::Import(plan))
                .map_err(|error| failure(operation, &error, None))
        }
        "bookmarks.import_source" => {
            let import: ImportSource = parse(params)?;
            let actor = super::origin_gate::connection_actor(mux, client);
            let key = import.idempotency_key.as_str();
            // The folder as it is before this import replaces or removes it: the import's undo
            // puts it back.
            let (_, before) = read(mux, operation, &import.browser_profile_id)?;
            let previous = lookup::source_draft(&before, &import.source_key);
            if import.items.is_empty() {
                // No items: the source's folder goes (a re-import of an emptied source). The
                // lookup, the delete and the replay record are one transaction.
                let mutation = WorkspaceMutation::new(key, REPLAY_ORIGIN, actor)
                    .map_err(|error| failure(operation, &error, None))?;
                let (profile, source_key) = (&import.browser_profile_id, &import.source_key);
                let (mut result, _) = mux
                    .bookmarks_mutation(|registry| {
                        let outcome =
                            registry.remove_bookmark_source(&mutation, profile, source_key)?;
                        Ok((outcome.result, outcome.changed))
                    })
                    .map_err(|error| failure(operation, &error, None))?;
                if let Some(object) = result.as_object_mut() {
                    for field in ["count", "added", "duplicates", "skipped"] {
                        object.insert(field.into(), json!(0));
                    }
                    object.insert("root_ids".into(), json!([]));
                    object.insert("previous".into(), json!(previous));
                }
                return Ok(result);
            }
            let plan = import_plan::source(
                &import.browser_profile_id,
                &import.title,
                &import.source_key,
                &import.items,
            )
            .map_err(|error| failure(operation, &error.into(), None))?;
            let mut result = one(mux, &actor, key, BookmarkOp::Import(plan.import))
                .map_err(|error| failure(operation, &error, None))?;
            if let Some(object) = result.as_object_mut() {
                object.insert("previous".into(), json!(previous));
                object.insert("added".into(), json!(plan.added));
                object.insert("duplicates".into(), json!(plan.duplicates));
                object.insert("skipped".into(), json!(plan.skipped));
            }
            Ok(result)
        }
        "bookmarks.import_legacy_file" => {
            let LegacyFile { browser_profile_id, nodes, .. } = parse(params)?;
            if nodes.len() > MAX_OPS {
                return Err(ResourceError::validation_invalid(
                    Some("nodes"),
                    format!("at most {MAX_OPS} nodes at once"),
                ));
            }
            let ops = lookup::legacy_nodes(&browser_profile_id, nodes);
            let actor = super::origin_gate::connection_actor(mux, client);
            let count = ops.len();
            // Each node has its own stable key: a copy that stopped replays what it did.
            for lookup::LegacyOp { key, op } in ops {
                one(mux, &actor, &key, op).map_err(|error| failure(operation, &error, None))?;
            }
            Ok(json!({"ops": count}))
        }
        _ => Err(ResourceError::operation_failed(
            operation,
            "unknown bookmarks operation",
            json!({"code": "bookmarks.unknown_operation"}),
        )),
    }
}

/// The replay key of op `index` of a batch keyed `key`: `<key>.<index>`, or,
/// when that would pass the ledger's identifier bound, the key's SHA-256
/// (hex) in its place, so every valid envelope key works and a retry gets
/// the same keys.
fn op_key(key: &str, index: usize) -> String {
    let plain = format!("{key}.{index}");
    // A caller's key that already looks hashed is hashed too, so a plain key
    // never equals another key's hashed form.
    if plain.len() <= MAX_KEY_BYTES && !key.starts_with(HASHED_KEY_PREFIX) {
        return plain;
    }
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(key.as_bytes());
    let hex = digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    format!("{HASHED_KEY_PREFIX}{hex}.{index}")
}

fn parse<T: DeserializeOwned>(params: Value) -> Result<T, ResourceError> {
    serde_json::from_value(params)
        .map_err(|error| ResourceError::validation_invalid(Some("params"), error.to_string()))
}

fn limit(limit: Option<usize>) -> usize {
    limit.unwrap_or(MAX_LIMIT).clamp(1, MAX_LIMIT)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// The nodes under `parent` down to `depth` levels, depth-first in listing
/// order, at most `limit`; true when more were left out.
fn subtree(
    tree: &Tree,
    parent: &str,
    depth: usize,
    limit: usize,
    places: bool,
) -> (Vec<Value>, bool) {
    let mut rows = Vec::new();
    let mut stack: Vec<(&cmux_bookmarks_core::Bookmark, usize)> =
        tree.children(parent).into_iter().rev().map(|node| (node, 1)).collect();
    while let Some((node, level)) = stack.pop() {
        if rows.len() == limit {
            return (rows, true);
        }
        rows.push(if places { lookup::placed(tree, node) } else { json!(node) });
        if level < depth {
            stack.extend(tree.children(&node.id).into_iter().rev().map(|child| (child, level + 1)));
        }
    }
    (rows, false)
}

/// `nodes` as rows, placed ([`lookup::placed`]) when asked.
fn rows(tree: &Tree, nodes: Vec<cmux_bookmarks_core::Bookmark>, places: bool) -> Value {
    if places {
        Value::from(nodes.iter().map(|node| lookup::placed(tree, node)).collect::<Vec<_>>())
    } else {
        json!(nodes)
    }
}

/// At most [`MAX_LOOKUPS`] ids or URLs at once.
fn bounded(field: &str, count: usize) -> Result<(), ResourceError> {
    if count > MAX_LOOKUPS {
        return Err(ResourceError::validation_invalid(
            Some(field),
            format!("at most {MAX_LOOKUPS} at once"),
        ));
    }
    Ok(())
}

/// `bookmarks.resolve`: each part asked for, or the first that names nothing.
fn resolve(tree: &Tree, request: Resolve) -> Result<Value, Unresolved> {
    let mut answer = Map::new();
    if let Some(text) = &request.bookmark {
        let node = if request.exact {
            lookup::find_exact(tree, text)
        } else {
            lookup::find(tree, text, request.folders_first, now_ms())
        }
        .ok_or(Unresolved::NotFound)?;
        answer.insert("bookmark".into(), lookup::placed(tree, &node));
    }
    if let Some(folder) = &request.folder {
        let id = lookup::folder(
            tree,
            folder.as_deref(),
            request.fallback_folder.as_deref(),
            &request.bar_title,
            &request.other_title,
        )?;
        answer.insert("folder".into(), Value::from(id));
    }
    if let Some(url) = &request.url {
        answer.insert("url".into(), Value::from(lookup::typed_url(url)?));
    }
    Ok(Value::Object(answer))
}

fn unresolved_error(operation: &str, unresolved: Unresolved) -> ResourceError {
    let message = match unresolved {
        Unresolved::NotFound => "no bookmark has that id, URL or name",
        Unresolved::NotFolder => "no folder has that id or name",
        Unresolved::InvalidUrl => "not a URL a bookmark can hold",
    };
    ResourceError::operation_failed(
        operation,
        message,
        json!({"code": format!("bookmarks.{}", unresolved.code())}),
    )
}

/// The profile's stored tree and its revision.
fn read(mux: &Mux, operation: &str, profile: &str) -> Result<(u64, Tree), ResourceError> {
    let (revision, bookmarks) =
        mux.list_bookmarks(profile).map_err(|error| failure(operation, &error, None))?;
    Ok((revision, Tree::from_listing(profile, bookmarks)))
}

/// One op with its replay key, as the raw command runs it.
fn one(mux: &Mux, actor: &Actor, key: &str, op: BookmarkOp) -> anyhow::Result<Value> {
    let key = WorkspaceMutation::new(key, REPLAY_ORIGIN, actor.clone())?;
    let (result, _) = mux.bookmarks_mutation(|registry| {
        let outcome = registry.apply_bookmark_op(Some(&key), op)?;
        Ok((outcome.result, outcome.changed))
    })?;
    Ok(result)
}

/// A refusal as `operation.failed`: the rule's code and reason in
/// `details.extra`, and how many ops of an apply ran before it.
fn failure(operation: &str, error: &anyhow::Error, applied: Option<usize>) -> ResourceError {
    let mut extra = match error.downcast_ref::<BookmarkError>() {
        Some(refusal) => {
            json!({"code": format!("bookmarks.{}", refusal.code()), "reason": refusal.reason()})
        }
        None => json!({"code": "bookmarks.failed"}),
    };
    if let (Some(applied), Some(object)) = (applied, extra.as_object_mut()) {
        object.insert("applied".into(), json!(applied));
    }
    let message = match error.downcast_ref::<BookmarkError>() {
        Some(refusal) => refusal.message().to_string(),
        None => error.to_string(),
    };
    ResourceError::operation_failed(operation, message, extra)
}

#[cfg(test)]
#[path = "bookmarks_routed_tests.rs"]
mod tests;
