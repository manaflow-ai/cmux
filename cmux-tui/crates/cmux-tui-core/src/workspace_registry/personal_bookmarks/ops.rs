//! The bookmark ops (`bookmarks-v1`): each op validates and writes in the
//! caller's transaction, and `WorkspaceRegistry::apply_bookmark_op` runs one
//! op with its replay record in one transaction.

use rusqlite::{OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::super::{WorkspaceMutation, WorkspaceRegistry};
use super::*;

// MARK: Ops on a transaction

/// Create a node at `index` among its siblings (default last). An
/// existing id returns the stored node with `false`, so a retry is
/// idempotent.
fn create_in(tx: &Transaction<'_>, input: BookmarkInput) -> anyhow::Result<(Bookmark, bool)> {
    let id = match input.id {
        Some(id) => {
            validate_bookmark_id(&id)?;
            id
        }
        None => new_bookmark_id(),
    };
    validate_profile_shape(&input.browser_profile_id)?;
    validate_kind_url(&input.kind, input.url.as_deref())?;
    validate_title(&input.title)?;
    validate_key("favicon_key", input.favicon_key.as_deref())?;
    validate_key("source_key", input.source_key.as_deref())?;
    ensure_valid!(
        input.source_key.is_none() || input.kind == "folder",
        "source_key marks an imported folder; a url has none"
    );
    let created_ms = match input.created_ms {
        Some(value) => stored_ms("created_ms", value)?,
        None => now_ms()?,
    };
    if let Some(existing) = read_bookmark(tx, &id)? {
        return Ok((existing, false));
    }
    let profile = input.browser_profile_id.as_str();
    ensure_profile(tx, profile)?;
    let parent_depth = resolve_parent(tx, profile, &input.parent)?;
    ensure_valid!(
        parent_depth < MAX_BOOKMARK_DEPTH,
        "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
    );
    ensure_capacity(tx, profile, 0, 1)?;
    let count = sibling_ids(tx, profile, &input.parent)?.len();
    let index = input.index.unwrap_or(count).min(count);
    shift(tx, profile, &input.parent, index, 1)?;
    insert_row(
        &mut tx.prepare(INSERT_ROW)?,
        &id,
        profile,
        &input.parent,
        &input.kind,
        index,
        &input.title,
        input.url.as_deref(),
        input.favicon_key.as_deref(),
        input.source_key.as_deref(),
        created_ms,
    )?;
    let bookmark = existing_bookmark(tx, &id)?;
    commit_bookmarks(
        tx,
        "personal.bookmark.created",
        profile,
        vec![subject("bookmark", &id)],
        json!({"bookmark_id": id, "parent": bookmark.parent, "kind": bookmark.kind,
               "index": bookmark.index}),
    )?;
    Ok((bookmark, true))
}

/// Change the title, URL (URL nodes only), favicon key or last use of a
/// node.
fn update_in(
    tx: &Transaction<'_>,
    id: &str,
    update: BookmarkUpdate,
) -> anyhow::Result<(Bookmark, bool)> {
    validate_bookmark_id(id)?;
    if let Some(title) = &update.title {
        validate_title(title)?;
    }
    if let Some(url) = &update.url {
        validate_url(url)?;
    }
    validate_key("favicon_key", update.favicon_key.as_ref().and_then(Option::as_deref))?;
    if let Some(Some(last_used_ms)) = update.last_used_ms {
        stored_ms("last_used_ms", last_used_ms)?;
    }
    let before = existing_bookmark(tx, id)?;
    ensure_valid!(update.url.is_none() || before.kind == "url", "a folder has no url");
    let mut after = before.clone();
    if let Some(title) = update.title {
        after.title = title;
    }
    if let Some(url) = update.url {
        after.url = Some(url);
    }
    if let Some(favicon_key) = update.favicon_key {
        after.favicon_key = favicon_key;
    }
    if let Some(last_used_ms) = update.last_used_ms {
        after.last_used_ms = last_used_ms;
    }
    let changed = after != before;
    if changed {
        tx.execute(
            "UPDATE bookmarks SET title = ?2, url = ?3, favicon_key = ?4, last_used_ms = ?5
             WHERE bookmark_id = ?1",
            params![
                id,
                after.title,
                after.url,
                after.favicon_key,
                after.last_used_ms.map(|value| stored_ms("last_used_ms", value)).transpose()?
            ],
        )?;
        commit_bookmarks(
            tx,
            "personal.bookmark.updated",
            &after.browser_profile_id,
            vec![subject("bookmark", id)],
            json!({"bookmark_id": id}),
        )?;
    }
    Ok((after, changed))
}

/// Move a node to `parent` in the same profile. `index` is the node's
/// final position among the destination's children after the move,
/// clamped, in the same parent too.
fn move_in(
    tx: &Transaction<'_>,
    id: &str,
    parent: &str,
    index: usize,
) -> anyhow::Result<(Bookmark, bool)> {
    validate_bookmark_id(id)?;
    let node = existing_bookmark(tx, id)?;
    let profile = node.browser_profile_id.clone();
    let parent_depth = resolve_parent(tx, &profile, parent)?;
    if !is_root(parent) {
        ensure_valid!(
            !ancestors(tx, parent)?.iter().any(|ancestor| ancestor == id),
            "a folder cannot move into itself or a descendant"
        );
    }
    let changed = if node.parent == parent {
        let mut order = sibling_ids(tx, &profile, parent)?;
        let old = node.index.min(order.len().saturating_sub(1));
        let new = index.min(order.len().saturating_sub(1));
        if new != old {
            let moved = order.remove(old);
            order.insert(new, moved);
            write_sibling_order(tx, &order)?;
        }
        new != old
    } else {
        ensure_valid!(
            parent_depth + subtree_height(tx, id)? <= MAX_BOOKMARK_DEPTH,
            "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
        );
        shift(tx, &profile, &node.parent, node.index + 1, -1)?;
        let count = sibling_ids(tx, &profile, parent)?.len();
        let index = index.min(count);
        shift(tx, &profile, parent, index, 1)?;
        tx.execute(
            "UPDATE bookmarks SET parent_id = ?2, position = ?3 WHERE bookmark_id = ?1",
            params![id, parent, i64::try_from(index)?],
        )?;
        true
    };
    let moved = existing_bookmark(tx, id)?;
    if changed {
        commit_bookmarks(
            tx,
            "personal.bookmark.moved",
            &profile,
            vec![subject("bookmark", id)],
            json!({"bookmark_id": id, "parent": moved.parent, "index": moved.index}),
        )?;
    }
    Ok((moved, changed))
}

/// Delete a node and its subtree; its later siblings close the gap.
fn delete_in(tx: &Transaction<'_>, id: &str) -> anyhow::Result<(String, Vec<String>)> {
    validate_bookmark_id(id)?;
    let node = existing_bookmark(tx, id)?;
    let deleted = subtree_ids(tx, id)?;
    tx.execute(
        &format!("DELETE FROM bookmarks WHERE bookmark_id IN ({SUBTREE} SELECT id FROM subtree)"),
        [id],
    )?;
    shift(tx, &node.browser_profile_id, &node.parent, node.index + 1, -1)?;
    commit_bookmarks(
        tx,
        "personal.bookmark.deleted",
        &node.browser_profile_id,
        vec![subject("bookmark", id)],
        json!({"bookmark_id": id, "deleted_count": deleted.len()}),
    )?;
    Ok((node.browser_profile_id, deleted))
}

/// Write an imported tree in one transaction. `nodes` become new nodes
/// at `parent`/`index` (absent appends), and `nodes[0]` carries
/// `source_key` when it is a folder. With `replace` (which needs
/// `source_key` and a folder `nodes[0]`), the profile's folder carrying
/// that `source_key` keeps its id, parent and position and takes
/// `nodes[0]`'s title and children; `nodes[1..]` follow it.
fn import_in(tx: &Transaction<'_>, import: BookmarkImport) -> anyhow::Result<(Vec<String>, usize)> {
    let profile = import.browser_profile_id.as_str();
    validate_profile_shape(profile)?;
    validate_key("source_key", import.source_key.as_deref())?;
    let (count, height) = validate_import_nodes(&import.nodes)?;
    ensure_valid!(count > 0, "nodes cannot be empty");
    if import.replace {
        ensure_valid!(import.source_key.is_some(), "replace needs a source_key");
        ensure_valid!(import.nodes[0].kind == "folder", "replace needs a folder as the first node");
    }
    let now = now_ms()?;
    ensure_profile(tx, profile)?;
    let parent_depth = resolve_parent(tx, profile, &import.parent)?;
    let existing = if import.replace {
        tx.query_row(
            "SELECT bookmark_id FROM bookmarks
             WHERE browser_profile_id = ?1 AND source_key = ?2 AND kind = 'folder'
             ORDER BY created_ms ASC, bookmark_id ASC LIMIT 1",
            params![profile, import.source_key],
            |row| row.get::<_, String>(0),
        )
        .optional()?
    } else {
        None
    };
    let root_ids = if let Some(folder) = existing {
        let stored = existing_bookmark(tx, &folder)?;
        let folder_depth = node_depth(tx, &folder)?;
        ensure_valid!(
            folder_depth - 1 + height <= MAX_BOOKMARK_DEPTH,
            "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
        );
        let old = subtree_ids(tx, &folder)?;
        ensure_capacity(tx, profile, old.len(), count)?;
        tx.execute(
            &format!(
                "DELETE FROM bookmarks WHERE bookmark_id IN ({SUBTREE} SELECT id FROM subtree)
                 AND bookmark_id != ?1"
            ),
            [&folder],
        )?;
        let root = &import.nodes[0];
        tx.execute(
            "UPDATE bookmarks SET title = ?2 WHERE bookmark_id = ?1",
            params![folder, root.title],
        )?;
        insert_import_nodes(
            &mut tx.prepare(INSERT_ROW)?,
            profile,
            &folder,
            0,
            root.children.as_deref().unwrap_or_default(),
            None,
            now,
        )?;
        let rest = &import.nodes[1..];
        let mut ids = vec![folder];
        if !rest.is_empty() {
            let after = stored.index + 1;
            shift(tx, profile, &stored.parent, after, i64::try_from(rest.len())?)?;
            ids.extend(insert_import_nodes(
                &mut tx.prepare(INSERT_ROW)?,
                profile,
                &stored.parent,
                after,
                rest,
                None,
                now,
            )?);
        }
        ids
    } else {
        ensure_valid!(
            parent_depth + height <= MAX_BOOKMARK_DEPTH,
            "bookmarks nest at most {MAX_BOOKMARK_DEPTH} deep"
        );
        ensure_capacity(tx, profile, 0, count)?;
        let siblings = sibling_ids(tx, profile, &import.parent)?.len();
        let index = import.index.unwrap_or(siblings).min(siblings);
        shift(tx, profile, &import.parent, index, i64::try_from(import.nodes.len())?)?;
        insert_import_nodes(
            &mut tx.prepare(INSERT_ROW)?,
            profile,
            &import.parent,
            index,
            &import.nodes,
            import.source_key.as_deref(),
            now,
        )?
    };
    commit_bookmarks(
        tx,
        "personal.bookmark.imported",
        profile,
        Vec::new(),
        json!({"root_count": root_ids.len(), "count": count, "replace": import.replace}),
    )?;
    Ok((root_ids, count))
}

// MARK: Ops

fn lookup_replay(
    tx: &Transaction<'_>,
    key: &WorkspaceMutation,
) -> anyhow::Result<Option<(String, String, String)>> {
    Ok(tx
        .query_row(
            "SELECT operation, fingerprint, result_json FROM bookmark_mutations
             WHERE origin = ?1 AND mutation_id = ?2",
            params![key.origin, key.id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?)
}

fn record_replay(
    tx: &Transaction<'_>,
    key: &WorkspaceMutation,
    operation: &str,
    fingerprint: &str,
    result: &Value,
) -> anyhow::Result<()> {
    tx.execute(
        "INSERT INTO bookmark_mutations(origin, mutation_id, operation, fingerprint, result_json)
         VALUES(?1, ?2, ?3, ?4, ?5)",
        params![key.origin, key.id, operation, fingerprint, serde_json::to_string(result)?],
    )?;
    tx.execute(
        "DELETE FROM bookmark_mutations
         WHERE seq <= (SELECT MAX(seq) FROM bookmark_mutations) - ?1",
        [BOOKMARK_REPLAY_RETENTION],
    )?;
    Ok(())
}

/// Apply one op in the caller's transaction. Returns the wire result
/// (without `replayed`) and the profile whose tree changed.
fn apply_op(tx: &Transaction<'_>, op: BookmarkOp) -> anyhow::Result<(Value, Option<String>)> {
    Ok(match op {
        BookmarkOp::Create(input) => {
            let (bookmark, changed) = create_in(tx, input)?;
            let profile = changed.then(|| bookmark.browser_profile_id.clone());
            (json!({"bookmark": bookmark, "changed": changed}), profile)
        }
        BookmarkOp::Update { bookmark, update } => {
            let (bookmark, changed) = update_in(tx, &bookmark, update)?;
            let profile = changed.then(|| bookmark.browser_profile_id.clone());
            (json!({"bookmark": bookmark, "changed": changed}), profile)
        }
        BookmarkOp::Move { bookmark, parent, index } => {
            let (bookmark, changed) = move_in(tx, &bookmark, &parent, index)?;
            let profile = changed.then(|| bookmark.browser_profile_id.clone());
            (json!({"bookmark": bookmark, "changed": changed}), profile)
        }
        BookmarkOp::Delete { bookmark } => {
            let (profile, deleted) = delete_in(tx, &bookmark)?;
            (json!({"deleted": deleted}), Some(profile))
        }
        BookmarkOp::Import(import) => {
            let profile = import.browser_profile_id.clone();
            let (root_ids, count) = import_in(tx, import)?;
            (json!({"root_ids": root_ids, "count": count}), Some(profile))
        }
    })
}

impl WorkspaceRegistry {
    /// The revision and every node of one profile's tree, in depth-first
    /// pre-order.
    pub fn list_bookmarks(&self, profile: &str) -> anyhow::Result<(u64, Vec<Bookmark>)> {
        ensure_profile(&self.connection, profile)?;
        Ok((bookmarks_revision(&self.connection)?, read_bookmarks(&self.connection, profile)?))
    }

    /// Validate and commit one bookmark op in one transaction. With a key
    /// (`origin` + `mutation_id`), the replay record is looked up before
    /// anything else and written with the op: a retry returns the original
    /// result with `replayed:true` and changes nothing, and the same key
    /// with another op is refused.
    pub fn apply_bookmark_op(
        &mut self,
        key: Option<&WorkspaceMutation>,
        op: BookmarkOp,
    ) -> anyhow::Result<BookmarkOutcome> {
        let operation = op.name();
        let fingerprint = {
            use sha2::{Digest, Sha256};
            let digest = Sha256::digest(serde_json::to_vec(&op)?);
            digest.iter().map(|byte| format!("{byte:02x}")).collect::<String>()
        };
        let tx = self.connection.transaction()?;
        if let Some(key) = key
            && let Some((stored_operation, stored_fingerprint, result)) = lookup_replay(&tx, key)?
        {
            ensure_valid!(
                stored_operation == operation && stored_fingerprint == fingerprint,
                "mutation {} of {} was used for another request",
                key.id,
                key.origin
            );
            let mut result: Value = serde_json::from_str(&result)?;
            result["replayed"] = json!(true);
            return Ok(BookmarkOutcome { result, changed: None });
        }
        let (mut result, changed) = apply_op(&tx, op)?;
        if let Some(key) = key {
            record_replay(&tx, key, operation, &fingerprint, &result)?;
        }
        let changed = match changed {
            Some(profile) => Some((profile, bookmarks_revision(&tx)?)),
            None => None,
        };
        tx.commit()?;
        result["replayed"] = json!(false);
        Ok(BookmarkOutcome { result, changed })
    }
}
