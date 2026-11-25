//! Bookmarks of the home session (capability `bookmarks-v1`,
//! plans/cmux-next/bookmarks.md sections 1 and 2.1): one bookmark tree
//! per browser profile. The two roots, the Bookmarks Bar (`bar`) and Other
//! Bookmarks (`other`), are reserved parent values, not rows. Every other
//! node is a row with a dense 0-based `position` among its siblings.
//!
//! Each change bumps the `bookmarks_revision` meta counter (separate from
//! `personal_revision`, so bookmark churn does not refetch `list-personal`)
//! and appends one advisory `state` journal record in the same transaction.
//! The journal records ids and counts only, never titles or URLs.

use std::collections::BTreeMap;

use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

// The rules, limits and op types live in cmux-bookmarks-core, which the app
// also links for its optimistic view (layer-ownership.md V-11); this module
// keeps the SQLite rows, the replay ledger and the journal.
pub use cmux_bookmarks_core::{
    BOOKMARKS_BAR, Bookmark, BookmarkError, BookmarkImport, BookmarkImportNode, BookmarkInput,
    BookmarkOp, BookmarkUpdate, MAX_BOOKMARK_DEPTH, MAX_BOOKMARKS_PER_PROFILE, OTHER_BOOKMARKS,
    is_root, stored_ms, validate_bookmark_id, validate_import_nodes, validate_key,
    validate_kind_url, validate_profile_shape, validate_title, validate_url,
};

use super::personal_store::subject;
use super::presentation_store::append_presentation_record;
use super::{JournalSubject, new_uuid_v4, unix_epoch_ms};

const REVISION_META_KEY: &str = "bookmarks_revision";
/// Keyed ops whose replay records are kept; older keys are forgotten.
pub const BOOKMARK_REPLAY_RETENTION: i64 = 10_000;

/// The additive table, its index and the revision counter. Idempotent: it
/// runs at every open, so a registry migrated before this capability gains
/// it, and older binaries ignore it.
pub(super) fn create_bookmark_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS bookmarks (
           bookmark_id TEXT PRIMARY KEY NOT NULL,
           browser_profile_id TEXT NOT NULL,
           parent_id TEXT NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('url','folder')),
           position INTEGER NOT NULL CHECK(position >= 0),
           title TEXT NOT NULL,
           url TEXT,
           favicon_key TEXT,
           source_key TEXT,
           created_ms INTEGER NOT NULL,
           last_used_ms INTEGER
         );
         CREATE INDEX IF NOT EXISTS bookmarks_parent
           ON bookmarks(browser_profile_id, parent_id, position);
         CREATE INDEX IF NOT EXISTS bookmarks_parent_id ON bookmarks(parent_id);
         CREATE TABLE IF NOT EXISTS bookmark_mutations (
           seq INTEGER PRIMARY KEY,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           operation TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           UNIQUE(origin, mutation_id)
         );",
    )?;
    // P8 landing 3b: the actor of a keyed op; a row without one is legacy.
    super::mutation_ledger::add_nullable_column(transaction, "bookmark_mutations", "actor")?;
    // `bookmark-icon-v1`: a folder's icon (the shared icon string).
    super::mutation_ledger::add_nullable_column(transaction, "bookmarks", "icon")?;
    transaction
        .execute("INSERT OR IGNORE INTO meta(key, value) VALUES(?1, '0')", [REVISION_META_KEY])?;
    Ok(())
}

// MARK: Errors

/// A refused op as the command's error (`invalid_params`).
pub fn invalid_bookmark(message: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(BookmarkError::invalid(message))
}

fn not_found(message: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(BookmarkError::not_found(message))
}

macro_rules! ensure_valid {
    ($condition:expr, $($message:tt)+) => {
        if !$condition {
            return Err(invalid_bookmark(format!($($message)+)));
        }
    };
}

// MARK: Outcomes

/// A committed (or replayed) op: the wire result, with `replayed`, and,
/// when it changed a tree, that browser profile and the committed
/// `bookmarks_revision`.
#[derive(Debug, Clone, PartialEq)]
pub struct BookmarkOutcome {
    pub result: Value,
    pub changed: Option<(String, u64)>,
}

// MARK: Ids

pub fn new_bookmark_id() -> String {
    format!("bm_{}", new_uuid_v4().replace('-', ""))
}

// MARK: Reads

const COLUMNS: &str = "bookmark_id, browser_profile_id, parent_id, kind, position, title, url,
                       favicon_key, source_key, created_ms, last_used_ms, icon";

fn row_bookmark(row: &rusqlite::Row<'_>) -> rusqlite::Result<Bookmark> {
    Ok(Bookmark {
        id: row.get(0)?,
        browser_profile_id: row.get(1)?,
        parent: row.get(2)?,
        kind: row.get(3)?,
        index: usize::try_from(row.get::<_, i64>(4)?).unwrap_or_default(),
        title: row.get(5)?,
        url: row.get(6)?,
        favicon_key: row.get(7)?,
        source_key: row.get(8)?,
        created_ms: u64::try_from(row.get::<_, i64>(9)?).unwrap_or_default(),
        last_used_ms: row
            .get::<_, Option<i64>>(10)?
            .map(|value| u64::try_from(value).unwrap_or_default()),
        icon: row.get(11)?,
    })
}

fn read_bookmark(connection: &Connection, id: &str) -> anyhow::Result<Option<Bookmark>> {
    Ok(connection
        .query_row(
            &format!("SELECT {COLUMNS} FROM bookmarks WHERE bookmark_id = ?1"),
            [id],
            row_bookmark,
        )
        .optional()?)
}

fn existing_bookmark(connection: &Connection, id: &str) -> anyhow::Result<Bookmark> {
    read_bookmark(connection, id)?.ok_or_else(|| not_found(format!("unknown bookmark {id}")))
}

pub(super) fn bookmarks_revision(connection: &Connection) -> anyhow::Result<u64> {
    let value = connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [REVISION_META_KEY], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    Ok(value.map(|value| value.parse()).transpose()?.unwrap_or(0))
}

/// The profile must exist in `browser_profiles`.
fn ensure_profile(connection: &Connection, profile: &str) -> anyhow::Result<()> {
    validate_profile_shape(profile)?;
    let exists = connection
        .query_row(
            "SELECT 1 FROM browser_profiles WHERE browser_profile_id = ?1",
            [profile],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !exists {
        return Err(not_found(format!("unknown browser profile {profile}")));
    }
    Ok(())
}

/// Depth of a node: a child of a root is 1.
fn node_depth(connection: &Connection, id: &str) -> anyhow::Result<usize> {
    let mut depth = 0;
    let mut current = id.to_string();
    while !is_root(&current) {
        depth += 1;
        anyhow::ensure!(depth <= MAX_BOOKMARK_DEPTH + 1, "bookmark {id} has a broken parent chain");
        current = connection
            .query_row(
                "SELECT parent_id FROM bookmarks WHERE bookmark_id = ?1",
                [&current],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("bookmark {id} has a missing ancestor"))?;
    }
    Ok(depth)
}

/// Every ancestor of a node, nearest first, roots excluded.
fn ancestors(connection: &Connection, id: &str) -> anyhow::Result<Vec<String>> {
    let mut chain = Vec::new();
    let mut current = id.to_string();
    while !is_root(&current) {
        anyhow::ensure!(
            chain.len() <= MAX_BOOKMARK_DEPTH + 1,
            "bookmark {id} has a broken parent chain"
        );
        chain.push(current.clone());
        current = connection
            .query_row(
                "SELECT parent_id FROM bookmarks WHERE bookmark_id = ?1",
                [&current],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("bookmark {id} has a missing ancestor"))?;
    }
    Ok(chain)
}

/// A valid parent in `profile`: a root, or a folder of that profile. Returns
/// the parent's depth (0 for a root).
fn resolve_parent(connection: &Connection, profile: &str, parent: &str) -> anyhow::Result<usize> {
    if is_root(parent) {
        return Ok(0);
    }
    ensure_valid!(
        validate_bookmark_id(parent).is_ok(),
        "parent must be \"bar\", \"other\" or a folder id"
    );
    let folder = read_bookmark(connection, parent)?;
    ensure_valid!(
        folder
            .as_ref()
            .is_some_and(|folder| folder.kind == "folder" && folder.browser_profile_id == profile),
        "parent {parent} is not a folder of browser profile {profile}"
    );
    node_depth(connection, parent)
}

const SUBTREE: &str = "WITH RECURSIVE subtree(id, level) AS (
                         SELECT ?1, 1
                         UNION
                         SELECT bookmarks.bookmark_id, subtree.level + 1
                         FROM bookmarks JOIN subtree ON bookmarks.parent_id = subtree.id
                         WHERE subtree.level <= 66
                       )";

/// A node and its descendants, the node first.
fn subtree_ids(connection: &Connection, id: &str) -> anyhow::Result<Vec<String>> {
    let mut statement = connection
        .prepare(&format!("{SUBTREE} SELECT id FROM subtree ORDER BY level ASC, id ASC"))?;
    Ok(statement.query_map([id], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
}

/// Levels of a subtree: 1 for a node without children.
fn subtree_height(connection: &Connection, id: &str) -> anyhow::Result<usize> {
    let height = connection.query_row(
        &format!("{SUBTREE} SELECT MAX(level) FROM subtree"),
        [id],
        |row| row.get::<_, i64>(0),
    )?;
    Ok(usize::try_from(height)?)
}

fn profile_count(connection: &Connection, profile: &str) -> anyhow::Result<usize> {
    let count = connection.query_row(
        "SELECT COUNT(*) FROM bookmarks WHERE browser_profile_id = ?1",
        [profile],
        |row| row.get::<_, i64>(0),
    )?;
    Ok(usize::try_from(count)?)
}

fn sibling_ids(
    connection: &Connection,
    profile: &str,
    parent: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT bookmark_id FROM bookmarks WHERE browser_profile_id = ?1 AND parent_id = ?2
         ORDER BY position ASC, bookmark_id ASC",
    )?;
    Ok(statement
        .query_map(params![profile, parent], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

fn ensure_capacity(
    connection: &Connection,
    profile: &str,
    removed: usize,
    added: usize,
) -> anyhow::Result<()> {
    let total = profile_count(connection, profile)?.saturating_sub(removed).saturating_add(added);
    ensure_valid!(
        total <= MAX_BOOKMARKS_PER_PROFILE,
        "a profile holds at most {MAX_BOOKMARKS_PER_PROFILE} bookmarks"
    );
    Ok(())
}

/// Add `delta` to the position of every sibling at or after `from`.
fn shift(
    connection: &Connection,
    profile: &str,
    parent: &str,
    from: usize,
    delta: i64,
) -> anyhow::Result<()> {
    connection.execute(
        "UPDATE bookmarks SET position = position + ?4
         WHERE browser_profile_id = ?1 AND parent_id = ?2 AND position >= ?3",
        params![profile, parent, i64::try_from(from)?, delta],
    )?;
    Ok(())
}

fn write_sibling_order(connection: &Connection, order: &[String]) -> anyhow::Result<()> {
    for (position, id) in order.iter().enumerate() {
        connection.execute(
            "UPDATE bookmarks SET position = ?2 WHERE bookmark_id = ?1",
            params![id, i64::try_from(position)?],
        )?;
    }
    Ok(())
}

/// The tree of one profile in depth-first pre-order: the `bar` tree, then
/// the `other` tree; each folder is followed by its subtree, siblings by
/// index. Rows that no root reaches (none, while the invariants hold) follow
/// grouped by parent.
pub(super) fn read_bookmarks(
    connection: &Connection,
    profile: &str,
) -> anyhow::Result<Vec<Bookmark>> {
    let mut statement = connection.prepare(&format!(
        "SELECT {COLUMNS} FROM bookmarks WHERE browser_profile_id = ?1
         ORDER BY parent_id ASC, position ASC, bookmark_id ASC"
    ))?;
    let rows = statement.query_map([profile], row_bookmark)?.collect::<Result<Vec<_>, _>>()?;
    let mut children = BTreeMap::<String, Vec<Bookmark>>::new();
    for row in rows {
        children.entry(row.parent.clone()).or_default().push(row);
    }
    let mut ordered = Vec::new();
    let mut stack = Vec::new();
    for root in [OTHER_BOOKMARKS, BOOKMARKS_BAR] {
        if let Some(nodes) = children.remove(root) {
            stack.extend(nodes.into_iter().rev());
        }
    }
    while let Some(node) = stack.pop() {
        if let Some(nodes) = children.remove(&node.id) {
            stack.extend(nodes.into_iter().rev());
        }
        ordered.push(node);
    }
    ordered.extend(children.into_values().flatten());
    Ok(ordered)
}

// MARK: Commit

/// Bump `bookmarks_revision` and append the journal fact of one bookmark
/// mutation, in the caller's transaction. Returns the new revision.
pub(super) fn commit_bookmarks(
    transaction: &Transaction<'_>,
    kind: &str,
    profile: &str,
    mut subjects: Vec<JournalSubject>,
    payload: Value,
) -> anyhow::Result<u64> {
    let revision = bookmarks_revision(transaction)?.saturating_add(1);
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![REVISION_META_KEY, revision.to_string()],
    )?;
    let mut payload = payload;
    if let Some(object) = payload.as_object_mut() {
        object.insert("browser_profile_id".into(), json!(profile));
        object.insert("bookmarks_revision".into(), json!(revision));
    }
    subjects.insert(0, subject("browser_profile", profile));
    append_presentation_record(transaction, kind, subjects, &payload)?;
    Ok(revision)
}

/// Delete every bookmark of a browser profile (`delete-browser-profile`).
/// Returns how many were deleted and, when any were, the new revision.
pub(super) fn delete_profile_bookmarks(
    transaction: &Transaction<'_>,
    profile: &str,
) -> anyhow::Result<(usize, Option<u64>)> {
    let deleted =
        transaction.execute("DELETE FROM bookmarks WHERE browser_profile_id = ?1", [profile])?;
    if deleted == 0 {
        return Ok((0, None));
    }
    let revision = commit_bookmarks(
        transaction,
        "personal.bookmark.profile_cleared",
        profile,
        Vec::new(),
        json!({"deleted_count": deleted}),
    )?;
    Ok((deleted, Some(revision)))
}

const INSERT_ROW: &str =
    "INSERT INTO bookmarks(bookmark_id, browser_profile_id, parent_id, kind, position, title,
                           url, favicon_key, source_key, created_ms)
     VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)";

/// Insert one row with a statement prepared from `INSERT_ROW`.
#[allow(clippy::too_many_arguments)]
fn insert_row(
    statement: &mut rusqlite::Statement<'_>,
    id: &str,
    profile: &str,
    parent: &str,
    kind: &str,
    position: usize,
    title: &str,
    url: Option<&str>,
    favicon_key: Option<&str>,
    source_key: Option<&str>,
    created_ms: i64,
) -> anyhow::Result<()> {
    statement.execute(params![
        id,
        profile,
        parent,
        kind,
        i64::try_from(position)?,
        title,
        url,
        favicon_key,
        source_key,
        created_ms
    ])?;
    Ok(())
}

/// Insert imported nodes under `parent` from `start`; `nodes[0]` carries
/// `source_key` when it is a folder. Returns the ids of `nodes`.
fn insert_import_nodes(
    statement: &mut rusqlite::Statement<'_>,
    profile: &str,
    parent: &str,
    start: usize,
    nodes: &[BookmarkImportNode],
    source_key: Option<&str>,
    now: i64,
) -> anyhow::Result<Vec<String>> {
    let mut ids = Vec::with_capacity(nodes.len());
    for (offset, node) in nodes.iter().enumerate() {
        let id = new_bookmark_id();
        let created_ms = node.created_ms.map(|value| stored_ms("created_ms", value)).transpose()?;
        insert_row(
            statement,
            &id,
            profile,
            parent,
            &node.kind,
            start + offset,
            &node.title,
            node.url.as_deref(),
            None,
            source_key.filter(|_| offset == 0 && node.kind == "folder"),
            created_ms.unwrap_or(now),
        )?;
        if let Some(children) = &node.children {
            insert_import_nodes(statement, profile, &id, 0, children, None, now)?;
        }
        ids.push(id);
    }
    Ok(ids)
}

fn now_ms() -> anyhow::Result<i64> {
    Ok(i64::try_from(unix_epoch_ms()?)?)
}

// The ops come last: they use `ensure_valid!`, which must precede them.
mod ops;
