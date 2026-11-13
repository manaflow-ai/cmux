//! Safari: `Bookmarks.plist`, `History.db` and the Search setting (`SafariReaders.swift`,
//! `SafariSearchEngineReader.swift`).

use crate::json;
use crate::model::{Bookmark, HistoryEntry, ReadError, SearchEngine};
use crate::sqlite::{self, Snapshot};
use crate::{search, time, url};
use plist::{Dictionary, Value};
use std::path::Path;

/// `Bookmarks.plist` (binary or XML): nested `WebBookmarkTypeList` folders and
/// `WebBookmarkTypeLeaf` bookmarks. The Favorites bar, the Bookmarks menu and the Reading List
/// get readable folder names; the History proxy is left out.
pub fn bookmarks(data: &[u8]) -> Result<Vec<Bookmark>, ReadError> {
    let value = Value::from_reader(std::io::Cursor::new(data))
        .map_err(|e| ReadError::Syntax(e.to_string()))?;
    let root = value.as_dictionary().ok_or(ReadError::Shape("notBookmarks"))?;
    let mut result = Vec::new();
    walk(root, &[], &mut result);
    Ok(result)
}

/// `as? [[String: Any]]` of a plist value: every element a dictionary, else none.
fn dictionaries(value: Option<&Value>) -> Vec<&Dictionary> {
    value
        .and_then(Value::as_array)
        .and_then(|list| list.iter().map(Value::as_dictionary).collect::<Option<Vec<_>>>())
        .unwrap_or_default()
}

fn walk(node: &Dictionary, path: &[String], result: &mut Vec<Bookmark>) {
    for child in dictionaries(node.get("Children")) {
        match child.get("WebBookmarkType").and_then(Value::as_string) {
            Some("WebBookmarkTypeLeaf") => {
                let Some(text) =
                    child.get("URLString").and_then(Value::as_string).and_then(url::importable)
                else {
                    continue;
                };
                let title = child
                    .get("URIDictionary")
                    .and_then(Value::as_dictionary)
                    .and_then(|d| d.get("title"))
                    .and_then(Value::as_string)
                    .filter(|t| !t.is_empty());
                result.push(Bookmark {
                    title: title.unwrap_or(text).to_owned(),
                    url: text.to_owned(),
                    folder_path: path.to_vec(),
                    date_added: None,
                });
            }
            Some("WebBookmarkTypeList") => {
                let title = child.get("Title").and_then(Value::as_string).unwrap_or_default();
                let mut inner = path.to_vec();
                inner.push(folder_name(title).to_owned());
                walk(child, &inner, result);
            }
            _ => {}
        }
    }
}

fn folder_name(title: &str) -> &str {
    match title {
        "BookmarksBar" => "Favorites",
        "BookmarksMenu" => "Bookmarks Menu",
        "com.apple.ReadingList" => "Reading List",
        other => other,
    }
}

/// `History.db` (`history_items` and `history_visits`, visit times in seconds since 2001),
/// newest first; each item's title is its newest visit's.
pub fn history(file: &Path, limit: i64) -> Result<Vec<HistoryEntry>, ReadError> {
    let database = Snapshot::copying(file)?;
    let sql = format!(
        "SELECT i.url, (SELECT v2.title FROM history_visits v2 WHERE v2.history_item = i.id \
                        ORDER BY v2.visit_time DESC LIMIT 1), \
                i.visit_count, MAX(v.visit_time) AS last \
         FROM history_items i JOIN history_visits v ON v.history_item = i.id \
         WHERE {} GROUP BY i.id ORDER BY last DESC LIMIT {}",
        url::sql_filter("i.url"),
        limit.max(0)
    );
    let mut entries = Vec::new();
    database.query(&sql, |row| {
        let text = sqlite::text(row, 0);
        let Some(text) = text.as_deref().and_then(url::importable) else { return true };
        let Some(date) = time::cocoa(sqlite::double(row, 3)) else { return true };
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

/// Safari's search engine from the Mac's `NSPreferredWebServices` (the app reads the global
/// defaults domain and passes that dictionary as JSON): `NSWebServicesProviderWebSearch`'s
/// display name or provider id ("DuckDuckGo", "com.duckduckgo"), mapped to the engine's
/// address. None when Safari keeps its own default.
pub fn search_engine(services: Option<&serde_json::Value>) -> Option<SearchEngine> {
    let web_search = json::object(json::object(services)?.get("NSWebServicesProviderWebSearch"))?;
    search::well_known(&[
        json::string(web_search.get("NSDefaultDisplayName")),
        json::string(web_search.get("NSProviderIdentifier")),
    ])
}
