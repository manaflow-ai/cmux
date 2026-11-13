//! Firefox profiles: `places.sqlite` bookmarks and history, the session store's open tabs and
//! the default search engine (`FirefoxPlacesReader.swift`, `FirefoxSessionReader.swift`,
//! `FirefoxSearchEngineReader.swift`).

use crate::json::{self, Object};
use crate::model::{Bookmark, HistoryEntry, ReadError, SearchEngine, Tab};
use crate::sqlite::{self, Snapshot};
use crate::{lz4, search, time, url};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const ROOT_GUID: &str = "root________";
const TAGS_GUID: &str = "tags________";

/// Built-in folders store short internal titles ("toolbar", "menu").
fn root_name(guid: &str) -> Option<&'static str> {
    match guid {
        "toolbar_____" => Some("Bookmarks Toolbar"),
        "menu________" => Some("Bookmarks Menu"),
        "unfiled_____" => Some("Other Bookmarks"),
        "mobile______" => Some("Mobile Bookmarks"),
        _ => None,
    }
}

struct Folder {
    title: String,
    parent: i64,
    guid: String,
}

/// Bookmarks (`moz_bookmarks` joined to `moz_places`, folder titles from the parent chain), in
/// parent then position order. Entries under the tags root are tag assignments, left out.
pub fn bookmarks(file: &Path) -> Result<Vec<Bookmark>, ReadError> {
    let database = Snapshot::copying(file)?;
    let mut folders: HashMap<i64, Folder> = HashMap::new();
    database.query("SELECT id, title, parent, guid FROM moz_bookmarks WHERE type = 2", |row| {
        folders.insert(
            sqlite::int64(row, 0),
            Folder {
                title: sqlite::text(row, 1).unwrap_or_default(),
                parent: sqlite::int64(row, 2),
                guid: sqlite::text(row, 3).unwrap_or_default(),
            },
        );
        true
    })?;
    let mut bookmarks = Vec::new();
    let sql = "SELECT p.url, b.title, b.parent, b.dateAdded FROM moz_bookmarks b \
               JOIN moz_places p ON p.id = b.fk WHERE b.type = 1 ORDER BY b.parent, b.position";
    database.query(sql, |row| {
        let text = sqlite::text(row, 0);
        let Some(text) = text.as_deref().and_then(url::importable) else { return true };
        let mut path: Vec<String> = Vec::new();
        let mut parent = sqlite::int64(row, 2);
        let mut depth = 0u32;
        // The root folder ends the chain.
        while let Some(folder) = folders.get(&parent)
            && folder.guid != ROOT_GUID
            && depth < 64
        {
            if folder.guid == TAGS_GUID {
                return true;
            }
            path.insert(
                0,
                root_name(&folder.guid).map_or_else(|| folder.title.clone(), str::to_owned),
            );
            parent = folder.parent;
            depth = depth.saturating_add(1);
        }
        let title =
            sqlite::text(row, 1).filter(|t| !t.is_empty()).unwrap_or_else(|| text.to_owned());
        bookmarks.push(Bookmark {
            title,
            url: text.to_owned(),
            folder_path: path,
            date_added: time::mozilla(sqlite::int64(row, 3)),
        });
        true
    })?;
    Ok(bookmarks)
}

/// History (`moz_places` with visits), newest first.
pub fn history(file: &Path, limit: i64) -> Result<Vec<HistoryEntry>, ReadError> {
    let database = Snapshot::copying(file)?;
    let sql = format!(
        "SELECT url, title, visit_count, last_visit_date FROM moz_places \
         WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL AND {} \
         ORDER BY last_visit_date DESC LIMIT {}",
        url::sql_filter("url"),
        limit.max(0)
    );
    let mut entries = Vec::new();
    database.query(&sql, |row| {
        let text = sqlite::text(row, 0);
        let Some(text) = text.as_deref().and_then(url::importable) else { return true };
        let Some(date) = time::mozilla(sqlite::int64(row, 3)) else { return true };
        entries.push(HistoryEntry {
            url: text.to_owned(),
            title: sqlite::text(row, 1).filter(|t| !t.is_empty()),
            visit_count: sqlite::int64(row, 2),
            last_visit: date,
        });
        true
    })?;
    Ok(entries)
}

/// The session store a profile has: `recovery.jsonlz4`, else `sessionstore.jsonlz4`, else
/// `previous.jsonlz4`.
pub fn session_file(profile: &Path) -> Option<PathBuf> {
    [
        "sessionstore-backups/recovery.jsonlz4",
        "sessionstore.jsonlz4",
        "sessionstore-backups/previous.jsonlz4",
    ]
    .iter()
    .map(|name| profile.join(name))
    .find(|path| path.exists())
}

/// The open tabs of a session store (mozLz4 JSON, `windows[].tabs[].entries[]`, `index`
/// 1-based and clamped to the entries).
pub fn session(data: &[u8]) -> Vec<Tab> {
    let Some(root) = lz4::decompress(data).and_then(|j| json::object_or_none(&j)) else {
        return Vec::new();
    };
    let mut tabs = Vec::new();
    for (window_index, window) in
        json::objects(root.get("windows")).unwrap_or_default().into_iter().enumerate()
    {
        for tab in json::objects(window.get("tabs")).unwrap_or_default() {
            let entries = json::objects(tab.get("entries")).unwrap_or_default();
            let count = i64::try_from(entries.len()).unwrap_or(i64::MAX);
            if count == 0 {
                continue;
            }
            let index =
                json::int(tab.get("index")).unwrap_or(count).clamp(1, count).saturating_sub(1);
            let Some(entry) = usize::try_from(index).ok().and_then(|i| entries.get(i)) else {
                continue;
            };
            let Some(text) = json::string(entry.get("url")).and_then(url::importable) else {
                continue;
            };
            tabs.push(Tab {
                url: text.to_owned(),
                title: json::non_empty(entry.get("title")).map(str::to_owned),
                window: window_index,
                pinned: json::boolean(tab.get("pinned")).unwrap_or(false),
            });
        }
    }
    tabs
}

/// A profile's default search engine from `search.json.mozlz4`.
pub fn search_engine(profile: &Path) -> Option<SearchEngine> {
    let data = std::fs::read(profile.join("search.json.mozlz4")).ok()?;
    search_engine_json(&lz4::decompress(&data)?)
}

/// The engine `metaData.defaultEngineId` names (`metaData.current`, its name, in files before
/// Firefox 97). An engine the person added keeps its own addresses (`_urls`, the query `params`
/// joined on); one Firefox ships names only its id, so it maps to the well-known engine's
/// address. None when the file names no engine.
pub fn search_engine_json(data: &[u8]) -> Option<SearchEngine> {
    let root = json::object_or_none(data)?;
    let engines = json::objects(root.get("engines"))?;
    let meta = json::object(root.get("metaData"));
    let field = |key: &str| json::non_empty(meta.and_then(|m| m.get(key)));
    let engine = if let Some(id) = field("defaultEngineId") {
        engines.into_iter().find(|e| json::string(e.get("id")) == Some(id))
    } else if let Some(name) = field("current") {
        engines.into_iter().find(|e| json::string(e.get("_name")) == Some(name))
    } else {
        return None;
    }?;
    let name = json::string(engine.get("_name"));
    let urls = json::objects(engine.get("_urls")).unwrap_or_default();
    let page = urls
        .iter()
        .find(|u| json::string(u.get("type")).unwrap_or("text/html") == "text/html")
        .and_then(|u| template(u));
    let Some(page) = page else {
        return search::well_known(&[json::string(engine.get("id")), name]);
    };
    let suggest = urls
        .iter()
        .find(|u| json::string(u.get("type")) == Some("application/x-suggestions+json"))
        .and_then(|u| template(u));
    let keyword = match engine.get("_definedAliases") {
        Some(aliases) => json::strings(Some(aliases)).and_then(|list| list.first().copied()),
        None => None,
    }
    .or_else(|| json::string(engine.get("alias")));
    search::engine(name, keyword, Some(&page), suggest.as_deref())
}

/// An `_urls` entry's address with its `params` (`{"name":"q","value":"{searchTerms}"}`) in the
/// query.
fn template(entry: &Object) -> Option<String> {
    let template = json::string(entry.get("template"))?;
    let params: Vec<String> = json::objects(entry.get("params"))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|p| {
            Some(format!("{}={}", json::string(p.get("name"))?, json::string(p.get("value"))?))
        })
        .collect();
    if params.is_empty() {
        return Some(template.to_owned());
    }
    let joiner = if template.contains('?') { '&' } else { '?' };
    Some(format!("{template}{joiner}{}", params.join("&")))
}
