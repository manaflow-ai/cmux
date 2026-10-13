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

use std::collections::{HashMap, HashSet};

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

/// One merge's running state: what it wrote and skipped, and the profile's
/// node count (read once).
struct Merge<'a> {
    tx: &'a Transaction<'a>,
    profile: &'a str,
    now: i64,
    total: usize,
    created: usize,
    skipped: usize,
}

/// The children of one target folder, read once per visit: URL keys,
/// folders by title and the next position.
struct Folder {
    urls: HashSet<String>,
    folders: HashMap<String, String>,
    next: usize,
}

fn meta_key(profile: &str, merge_key: &str) -> String {
    format!("{MERGED_META_PREFIX}{profile}:{merge_key}")
}

/// `bm_` and the guid's 32 hex digits, when the guid is a UUID.
fn id_of_guid(guid: Option<&str>) -> Option<String> {
    let hex: String = guid?.chars().filter(|c| *c != '-').collect::<String>().to_ascii_lowercase();
    (hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_hexdigit())).then(|| format!("bm_{hex}"))
}

/// A URL compared for duplicates: the parsed absolute URL, so a host with
/// an empty path equals the host with `/`; `/a` and `/a/` stay different,
/// as in Chromium.
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

/// A title cmux stores: no NUL, at most the title limit (cut at a char
/// boundary), so a long Chromium title is kept, not dropped.
fn stored_title(title: &str) -> String {
    let mut title = title.replace('\0', "");
    if title.len() > MAX_BOOKMARK_TITLE_BYTES {
        let mut end = MAX_BOOKMARK_TITLE_BYTES;
        while !title.is_char_boundary(end) {
            end -= 1;
        }
        title.truncate(end);
    }
    title
}

impl Merge<'_> {
    fn folder(&self, parent: &str) -> anyhow::Result<Folder> {
        let mut statement = self.tx.prepare_cached(
            "SELECT bookmark_id, kind, title, url FROM bookmarks
             WHERE browser_profile_id = ?1 AND parent_id = ?2",
        )?;
        let mut folder = Folder { urls: HashSet::new(), folders: HashMap::new(), next: 0 };
        let mut rows = statement.query(params![self.profile, parent])?;
        while let Some(row) = rows.next()? {
            folder.next += 1;
            let (id, kind, title, url): (String, String, String, Option<String>) =
                (row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?);
            if kind == "folder" {
                folder.folders.entry(title).or_insert(id);
            } else if let Some(url) = url {
                folder.urls.insert(url_key(&url));
            }
        }
        Ok(folder)
    }

    /// The profile of an existing id (ids are unique across profiles).
    fn owner(&self, id: &str) -> anyhow::Result<Option<(String, String)>> {
        Ok(self
            .tx
            .prepare_cached(
                "SELECT browser_profile_id, kind FROM bookmarks WHERE bookmark_id = ?1",
            )?
            .query_row([id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .optional()?)
    }

    /// Merge Chromium `nodes` into cmux folder `parent`, whose children sit
    /// at depth `depth`.
    fn children(&mut self, parent: &str, depth: usize, nodes: &[Value]) -> anyhow::Result<()> {
        if nodes.is_empty() {
            return Ok(());
        }
        let mut folder = self.folder(parent)?;
        for node in nodes {
            let kind = node.get("type").and_then(Value::as_str).unwrap_or_default();
            let title = stored_title(node.get("name").and_then(Value::as_str).unwrap_or_default());
            let url = node.get("url").and_then(Value::as_str);
            let nested = node
                .get("children")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            let valid = depth <= MAX_BOOKMARK_DEPTH
                && match kind {
                    "url" => url.is_some_and(|url| validate_url(url).is_ok()),
                    "folder" => true,
                    _ => false,
                };
            if !valid {
                self.skipped += 1;
                continue;
            }
            let id = id_of_guid(node.get("guid").and_then(Value::as_str));
            let owner = match &id {
                Some(id) => self.owner(id)?,
                None => None,
            };
            // A node cmux already has (cmux made it, or a merge took it before):
            // a folder's children merge into it where it is now.
            if let (Some(id), Some((profile, existing))) = (&id, &owner)
                && profile == self.profile
            {
                self.skipped += 1;
                if kind == "folder" && existing == "folder" {
                    let depth = node_depth(self.tx, id)? + 1;
                    self.children(id, depth, nested)?;
                }
                continue;
            }
            if kind == "url" {
                if folder.urls.contains(&url_key(url.unwrap_or_default())) {
                    self.skipped += 1;
                    continue;
                }
            } else if let Some(existing) = folder.folders.get(&title).cloned() {
                self.skipped += 1;
                self.children(&existing, depth + 1, nested)?;
                continue;
            }
            if self.total >= MAX_BOOKMARKS_PER_PROFILE {
                self.skipped += 1;
                continue;
            }
            let new_id = match id {
                Some(id) if owner.is_none() => id,
                _ => new_bookmark_id(),
            };
            insert_row(
                &mut self.tx.prepare_cached(INSERT_ROW)?,
                &new_id,
                self.profile,
                parent,
                kind,
                folder.next,
                &title,
                url.filter(|_| kind == "url"),
                None,
                None,
                created_ms(node).unwrap_or(self.now),
            )?;
            folder.next += 1;
            self.total += 1;
            self.created += 1;
            if kind == "folder" {
                folder.folders.entry(title).or_insert_with(|| new_id.clone());
                self.children(&new_id, depth + 1, nested)?;
            } else if let Some(url) = url {
                folder.urls.insert(url_key(url));
            }
        }
        Ok(())
    }
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
    let mut merge = Merge {
        tx,
        profile,
        now: now_ms()?,
        total: profile_count(tx, profile)?,
        created: 0,
        skipped: 0,
    };
    for (chromium, cmux) in [("bookmark_bar", BOOKMARKS_BAR), ("other", OTHER_BOOKMARKS)] {
        let nodes = roots
            .get(chromium)
            .and_then(|root| root.get("children"))
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        merge.children(cmux, 1, nodes)?;
    }
    let (now, created, skipped) = (merge.now, merge.created, merge.skipped);
    tx.execute("INSERT INTO meta(key, value) VALUES(?1, ?2)", params![key, now.to_string()])?;
    if created > 0 {
        commit_bookmarks(
            tx,
            "personal.bookmark.merged",
            profile,
            Vec::new(),
            json!({"count": created, "skipped": skipped}),
        )?;
    }
    Ok((json!({"merged": true, "created": created, "skipped": skipped}), created > 0))
}
