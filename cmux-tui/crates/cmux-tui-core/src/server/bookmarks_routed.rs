//! The routed `bookmarks` namespace (page-router.md "Routed namespaces"):
//! the Bookmarks page, the app's import and export, and its search reach
//! one browser profile's tree in the home session with the v2 envelope.
//! Every op is one of the `bookmarks-v1` commands' rules
//! (cmux-bookmarks-core), so the page, the CLI and the app's bar follow one
//! rule set:
//!
//! - `bookmarks.list {browser_profile_id}`: `{bookmarks_revision, bookmarks}`
//!   in listing order (as `list-bookmarks`).
//! - `bookmarks.search {browser_profile_id, text, limit?}`: `{bookmarks}`,
//!   nodes whose title or URL holds every term, tree order. `text` is at
//!   most 1 KiB and 32 terms (also for `rank`).
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
//!   removes it. `{root_ids, count, added, duplicates, skipped, replayed}`
//!   (`skipped`: items whose URL the store would refuse); a removal also has
//!   `deleted`.

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
/// The replay origin of routed bookmark ops.
const REPLAY_ORIGIN: &str = "bookmarks.routed";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    browser_profile_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Query {
    browser_profile_id: String,
    text: String,
    #[serde(default)]
    limit: Option<usize>,
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
            let Profile { browser_profile_id } = parse(params)?;
            let (revision, bookmarks) = read(mux, operation, &browser_profile_id)?;
            Ok(json!({"bookmarks_revision": revision, "bookmarks": bookmarks.listing()}))
        }
        "bookmarks.search" => {
            let query: Query = parse(params)?;
            query.check()?;
            let (_, tree) = read(mux, operation, &query.browser_profile_id)?;
            let mut found = search::search(&tree, &query.text);
            found.truncate(limit(query.limit));
            Ok(json!({"bookmarks": found}))
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
                object.insert("added".into(), json!(plan.added));
                object.insert("duplicates".into(), json!(plan.duplicates));
                object.insert("skipped".into(), json!(plan.skipped));
            }
            Ok(result)
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
