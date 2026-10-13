//! `merge-bookmarks` (`bookmarks-merge-v1`): the first sync of a Chromium
//! bookmark store keeps the bookmarks only Chromium has
//! (plans/cmux-next/bookmarks.md section 4). The chrome.bookmarks bridge
//! makes Chromium's tree follow cmux's, so before a store's first sync its
//! own `Bookmarks` file is merged into cmux's tree once: a bookmark cmux
//! already has (same id, or same URL in the same folder) is skipped, a
//! folder with the same title in the same place is merged into, and the rest
//! is appended. The merge key is recorded in the same transaction, so a later
//! merge of the same store changes nothing and a deletion in cmux stays
//! deleted.

use rusqlite::{OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use super::*;

/// Meta key prefix of a recorded merge.
const MERGED_META_PREFIX: &str = "bookmarks_merged:";
/// Milliseconds from 1601-01-01 (Chromium's `date_added` epoch) to 1970-01-01.
const WINDOWS_EPOCH_OFFSET_MS: i64 = 11_644_473_600_000;

/// Fields of `merge-bookmarks`.
#[derive(Debug, Clone, Default, Serialize)]
pub struct BookmarkMerge {
    pub browser_profile_id: String,
    pub merge_key: String,
    /// The text of a Chromium `Bookmarks` file.
    pub chromium_bookmarks: String,
}

#[derive(Default)]
struct Counts {
    created: usize,
    skipped: usize,
}

fn meta_key(profile: &str, merge_key: &str) -> String {
    format!("{MERGED_META_PREFIX}{profile}:{merge_key}")
}

/// `bm_` and the guid's 32 hex digits, when the guid is a UUID.
fn id_of_guid(guid: Option<&str>) -> Option<String> {
    let hex: String = guid?.chars().filter(|c| *c != '-').collect::<String>().to_ascii_lowercase();
    (hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_hexdigit())).then(|| format!("bm_{hex}"))
}

/// A URL compared for duplicates: an empty path and `/` are the same.
fn url_key(url: &str) -> String {
    match url::Url::parse(url) {
        Ok(parsed) => parsed.as_str().to_string(),
        Err(_) => url.to_string(),
    }
}

/// Chromium's `date_added` (microseconds since 1601, a string) in Unix ms.
fn created_ms(node: &Value) -> Option<i64> {
    let micros: i64 = node.get("date_added")?.as_str()?.parse().ok()?;
    let ms = micros / 1000 - WINDOWS_EPOCH_OFFSET_MS;
    (ms > 0).then_some(ms)
}

/// The direct children of `parent`: (id, kind, title, url key).
fn children(
    tx: &Transaction<'_>,
    profile: &str,
    parent: &str,
) -> anyhow::Result<Vec<(String, String, String, Option<String>)>> {
    let mut statement = tx.prepare(
        "SELECT bookmark_id, kind, title, url FROM bookmarks
         WHERE browser_profile_id = ?1 AND parent_id = ?2 ORDER BY position ASC, bookmark_id ASC",
    )?;
    let rows = statement
        .query_map(params![profile, parent], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get::<_, Option<String>>(3)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows
        .into_iter()
        .map(|(id, kind, title, url)| (id, kind, title, url.as_deref().map(url_key)))
        .collect())
}

/// The profile of an existing id, which is unique across profiles.
fn profile_of(tx: &Transaction<'_>, id: &str) -> anyhow::Result<Option<String>> {
    Ok(tx
        .query_row("SELECT browser_profile_id FROM bookmarks WHERE bookmark_id = ?1", [id], |row| {
            row.get::<_, String>(0)
        })
        .optional()?)
}

/// Merge Chromium `nodes` into cmux folder `parent` (depth of its children: `depth`).
fn merge_children(
    tx: &Transaction<'_>,
    profile: &str,
    parent: &str,
    depth: usize,
    nodes: &[Value],
    now: i64,
    counts: &mut Counts,
) -> anyhow::Result<()> {
    for node in nodes {
        let kind = node.get("type").and_then(Value::as_str).unwrap_or_default();
        let title = node.get("name").and_then(Value::as_str).unwrap_or_default();
        let url = node.get("url").and_then(Value::as_str);
        let nested =
            node.get("children").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        let valid = depth <= MAX_BOOKMARK_DEPTH
            && validate_title(title).is_ok()
            && match kind {
                "url" => url.is_some_and(|url| validate_url(url).is_ok()),
                "folder" => true,
                _ => false,
            };
        if !valid {
            counts.skipped += 1;
            continue;
        }
        let id = id_of_guid(node.get("guid").and_then(Value::as_str));
        // A node cmux already has (cmux made it, or a merge took it before).
        if let Some(id) = &id
            && profile_of(tx, id)?.as_deref() == Some(profile)
        {
            counts.skipped += 1;
            if kind == "folder" && existing_bookmark(tx, id)?.kind == "folder" {
                merge_children(tx, profile, id, depth + 1, nested, now, counts)?;
            }
            continue;
        }
        let siblings = children(tx, profile, parent)?;
        if kind == "url" {
            let key = url_key(url.unwrap_or_default());
            if siblings
                .iter()
                .any(|(_, kind, _, url)| kind == "url" && url.as_deref() == Some(key.as_str()))
            {
                counts.skipped += 1;
                continue;
            }
        } else if let Some((folder, ..)) =
            siblings.iter().find(|(_, kind, existing, _)| kind == "folder" && existing == title)
        {
            counts.skipped += 1;
            let folder = folder.clone();
            merge_children(tx, profile, &folder, depth + 1, nested, now, counts)?;
            continue;
        }
        if profile_count(tx, profile)? >= MAX_BOOKMARKS_PER_PROFILE {
            counts.skipped += 1;
            continue;
        }
        let free = match &id {
            Some(id) => profile_of(tx, id)?.is_none(),
            None => false,
        };
        let new_id = if free { id.unwrap_or_else(new_bookmark_id) } else { new_bookmark_id() };
        insert_row(
            &mut tx.prepare(INSERT_ROW)?,
            &new_id,
            profile,
            parent,
            kind,
            siblings.len(),
            title,
            url.filter(|_| kind == "url"),
            None,
            None,
            created_ms(node).unwrap_or(now),
        )?;
        counts.created += 1;
        if kind == "folder" {
            merge_children(tx, profile, &new_id, depth + 1, nested, now, counts)?;
        }
    }
    Ok(())
}

/// Merge once per (profile, merge key). Returns the result and whether the
/// tree changed.
pub(super) fn merge_in(
    tx: &Transaction<'_>,
    merge: BookmarkMerge,
) -> anyhow::Result<(Value, bool)> {
    let profile = merge.browser_profile_id.as_str();
    validate_profile_shape(profile)?;
    ensure_valid!(!merge.merge_key.is_empty(), "merge_key cannot be empty");
    validate_key("merge_key", Some(&merge.merge_key))?;
    let file: Value = serde_json::from_str(&merge.chromium_bookmarks)
        .map_err(|error| invalid_bookmark(format!("chromium_bookmarks is not JSON: {error}")))?;
    let roots = file
        .get("roots")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid_bookmark("chromium_bookmarks has no roots"))?;
    ensure_profile(tx, profile)?;
    let key = meta_key(profile, &merge.merge_key);
    let done =
        tx.query_row("SELECT 1 FROM meta WHERE key = ?1", [&key], |_| Ok(())).optional()?.is_some();
    if done {
        return Ok((json!({"merged": false, "created": 0, "skipped": 0}), false));
    }
    let now = now_ms()?;
    let mut counts = Counts::default();
    for (chromium, cmux) in [("bookmark_bar", BOOKMARKS_BAR), ("other", OTHER_BOOKMARKS)] {
        let nodes = roots
            .get(chromium)
            .and_then(|root| root.get("children"))
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        merge_children(tx, profile, cmux, 1, nodes, now, &mut counts)?;
    }
    tx.execute("INSERT INTO meta(key, value) VALUES(?1, ?2)", params![key, now.to_string()])?;
    if counts.created > 0 {
        commit_bookmarks(
            tx,
            "personal.bookmark.merged",
            profile,
            Vec::new(),
            json!({"count": counts.created, "skipped": counts.skipped}),
        )?;
    }
    Ok((
        json!({"merged": true, "created": counts.created, "skipped": counts.skipped}),
        counts.created > 0,
    ))
}
