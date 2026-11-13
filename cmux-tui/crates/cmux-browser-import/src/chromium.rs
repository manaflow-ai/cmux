//! Chromium-family profiles (Chrome, Edge, Brave, Arc's Chromium side, ...): `Bookmarks`,
//! `History`, the last session's open tabs, the default search engine and the Web Store
//! extensions (`ChromiumBookmarksParser.swift`, `ChromiumHistoryReader.swift`,
//! `ChromiumSessionReader.swift`, `ChromiumSearchEngineReader.swift`,
//! `ChromiumExtensionsReader.swift`).

use crate::json::{self, Object};
use crate::model::{Bookmark, Extension, HistoryEntry, ReadError, SearchEngine, Tab};
use crate::pickle::{self, Pickle};
use crate::place::Place;
use crate::sqlite;
use crate::{search, time, url};
use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

// MARK: Bookmarks

/// A `Bookmarks` file (JSON: `roots.bookmark_bar`, `roots.other`, `roots.synced`, each a folder
/// of `url` and `folder` nodes).
pub fn bookmarks(data: &[u8]) -> Result<Vec<Bookmark>, ReadError> {
    let root = json::parse_object(data).map_err(|e| ReadError::Syntax(e.to_string()))?;
    let roots = root
        .as_ref()
        .and_then(|root| json::object(root.get("roots")))
        .ok_or(ReadError::Shape("notBookmarks"))?;
    let mut result = Vec::new();
    for key in ["bookmark_bar", "other", "synced"] {
        let Some(folder) = json::object(roots.get(key)) else { continue };
        let name = json::non_empty(folder.get("name")).unwrap_or(key);
        walk_bookmarks(folder, &[name.to_owned()], &mut result);
    }
    Ok(result)
}

fn walk_bookmarks(node: &Object, path: &[String], result: &mut Vec<Bookmark>) {
    for child in json::objects(node.get("children")).unwrap_or_default() {
        let name = json::string(child.get("name")).unwrap_or_default();
        match json::string(child.get("type")) {
            Some("url") => {
                let Some(text) = json::string(child.get("url")).and_then(url::importable) else {
                    continue;
                };
                let added = json::string(child.get("date_added"))
                    .and_then(|t| t.parse::<i64>().ok())
                    .and_then(time::chromium);
                result.push(Bookmark {
                    title: if name.is_empty() { text } else { name }.to_owned(),
                    url: text.to_owned(),
                    folder_path: path.to_vec(),
                    date_added: added,
                });
            }
            Some("folder") => {
                let mut inner = path.to_vec();
                inner.push(name.to_owned());
                walk_bookmarks(child, &inner, result);
            }
            _ => {}
        }
    }
}

// MARK: History

/// A `History` database (`urls`: url, title, visit_count, last_visit_time), newest first.
pub fn history<'a>(file: impl Into<Place<'a>>, limit: i64) -> Result<Vec<HistoryEntry>, ReadError> {
    let database = file.into().database()?;
    let sql = format!(
        "SELECT url, title, visit_count, last_visit_time FROM urls \
         WHERE hidden = 0 AND visit_count > 0 AND {} ORDER BY last_visit_time DESC LIMIT {}",
        url::sql_filter("url"),
        limit.max(0)
    );
    let mut entries = Vec::new();
    database.query(&sql, |row| {
        let text = sqlite::text(row, 0);
        let Some(text) = text.as_deref().and_then(url::importable) else { return true };
        let Some(date) = time::chromium(sqlite::int64(row, 3)) else { return true };
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

// MARK: Session

// session_service_commands.cc command ids.
const SET_TAB_WINDOW: u8 = 0;
const SET_TAB_INDEX_IN_WINDOW: u8 = 2;
const UPDATE_TAB_NAVIGATION: u8 = 6;
const SET_SELECTED_NAVIGATION_INDEX: u8 = 7;
const SET_PINNED_STATE: u8 = 12;
const TAB_CLOSED: u8 = 16;
const WINDOW_CLOSED: u8 = 17;

/// The newest `Session_*` file in a profile's `Sessions` folder (by the number after
/// `Session_`; a name without one counts as 0).
pub fn latest_session_file<'a>(sessions: impl Into<Place<'a>>) -> Option<PathBuf> {
    let sessions = sessions.into();
    let mut best: Option<(i64, String)> = None;
    for name in sessions.names() {
        let Some(number) = name.strip_prefix("Session_") else { continue };
        let number = number.parse::<i64>().unwrap_or(0);
        // The first of equal numbers stays (`max(by:)`).
        if best.as_ref().is_none_or(|(top, _)| number > *top) {
            best = Some((number, name));
        }
    }
    best.map(|(_, name)| sessions.join(&name).path())
}

/// The profile's session file: the newest `Sessions/Session_*`, else `Current Session`.
pub fn session_file<'a>(profile: impl Into<Place<'a>>) -> Option<PathBuf> {
    let profile = profile.into();
    latest_session_file(profile.join("Sessions")).or_else(|| {
        let legacy = profile.join("Current Session");
        legacy.exists().then(|| legacy.path())
    })
}

#[derive(Default)]
struct SessionTab {
    window: i32,
    index: i32,
    pinned: bool,
    selected: Option<i32>,
    navigations: HashMap<i32, (String, String)>,
}

/// The open tabs of a session file: an "SNSS" command log (after an 8-byte header, "SNSS" and
/// an int32 version, each command is a uint16 size, a uint8 id and `size - 1` payload bytes).
/// Replaying the tab and window commands gives the tabs that were open, each at its selected
/// navigation. Encrypted session files (versions 2 and 4) give none.
pub fn session(data: &[u8]) -> Vec<Tab> {
    if data.len() < 8 || data.get(..4) != Some(b"SNSS".as_slice()) {
        return Vec::new();
    }
    if !matches!(pickle::uint32(data, 4), Some(1 | 3)) {
        return Vec::new();
    }
    let mut tabs: HashMap<i32, SessionTab> = HashMap::new();
    let mut closed_windows: HashSet<i32> = HashSet::new();
    let mut offset = 8usize;
    while let Some(header) = offset.checked_add(3).and_then(|end| data.get(offset..end)) {
        let (Some(&low), Some(&high), Some(&id)) = (header.first(), header.get(1), header.get(2))
        else {
            break;
        };
        let size = usize::from(u16::from_le_bytes([low, high]));
        let Some(end) = offset.checked_add(2).and_then(|start| start.checked_add(size)) else {
            break;
        };
        if size < 1 || end > data.len() {
            break;
        }
        let payload = data.get(offset.saturating_add(3)..end).unwrap_or_default();
        offset = end;
        apply(id, payload, &mut tabs, &mut closed_windows);
    }
    let mut open: Vec<(&i32, &SessionTab)> =
        tabs.iter().filter(|(_, tab)| !closed_windows.contains(&tab.window)).collect();
    open.sort_by_key(|(id, tab)| (tab.window, tab.index, **id));
    let mut windows: Vec<i32> = open.iter().map(|(_, tab)| tab.window).collect();
    windows.sort_unstable();
    windows.dedup();
    open.into_iter()
        .filter_map(|(_, tab)| {
            let index = tab.selected.or_else(|| tab.navigations.keys().max().copied())?;
            let (text, title) = tab.navigations.get(&index)?;
            let text = url::importable(text)?;
            Some(Tab {
                url: text.to_owned(),
                title: (!title.is_empty()).then(|| title.clone()),
                window: windows.iter().position(|w| *w == tab.window).unwrap_or(0),
                pinned: tab.pinned,
            })
        })
        .collect()
}

fn apply(
    id: u8,
    payload: &[u8],
    tabs: &mut HashMap<i32, SessionTab>,
    closed_windows: &mut HashSet<i32>,
) {
    let mut raw = Pickle::raw(payload);
    match id {
        UPDATE_TAB_NAVIGATION => {
            let Some(mut pickle) = Pickle::new(payload) else { return };
            let (Some(tab), Some(index), Some(url), Some(title)) =
                (pickle.int32(), pickle.int32(), pickle.string(), pickle.string16())
            else {
                return;
            };
            tabs.entry(tab).or_default().navigations.insert(index, (url, title));
        }
        SET_SELECTED_NAVIGATION_INDEX => {
            let (Some(tab), Some(index)) = (raw.int32(), raw.int32()) else { return };
            tabs.entry(tab).or_default().selected = Some(index);
        }
        SET_TAB_WINDOW => {
            let (Some(window), Some(tab)) = (raw.int32(), raw.int32()) else { return };
            tabs.entry(tab).or_default().window = window;
        }
        SET_TAB_INDEX_IN_WINDOW => {
            let (Some(tab), Some(index)) = (raw.int32(), raw.int32()) else { return };
            tabs.entry(tab).or_default().index = index;
        }
        SET_PINNED_STATE => {
            let (Some(tab), Some(pinned)) = (raw.int32(), raw.int32()) else { return };
            tabs.entry(tab).or_default().pinned = pinned & 0xFF != 0;
        }
        TAB_CLOSED => {
            let Some(tab) = raw.int32() else { return };
            tabs.remove(&tab);
        }
        WINDOW_CLOSED => {
            let Some(window) = raw.int32() else { return };
            closed_windows.insert(window);
        }
        _ => {}
    }
}

// MARK: Search engine

/// A profile's default search engine: `Preferences`'
/// `default_search_provider_data.template_url_data` (an engine the person set), else the
/// `keywords` row of `Web Data` whose `sync_guid` is `default_search_provider.guid`. None when
/// the profile keeps the browser's own default.
pub fn search_engine<'a>(profile: impl Into<Place<'a>>) -> Option<SearchEngine> {
    let profile = profile.into();
    let data = profile.join("Preferences").read().ok()?;
    let root = json::object_or_none(&data)?;
    if let Some(template) = json::object(
        json::object(root.get("default_search_provider_data"))
            .and_then(|d| d.get("template_url_data")),
    ) && let Some(engine) = search::engine(
        json::string(template.get("short_name")),
        json::string(template.get("keyword")),
        json::string(template.get("url")),
        json::string(template.get("suggestions_url")),
    ) {
        return Some(engine);
    }
    let guid = json::non_empty(
        json::object(root.get("default_search_provider")).and_then(|p| p.get("guid")),
    )?;
    let database = profile.join("Web Data").database().ok()?;
    let quoted = guid.replace('\'', "''");
    let mut found = None;
    let _ = database.query(
        &format!(
            "SELECT short_name, keyword, url, suggest_url FROM keywords WHERE sync_guid = '{quoted}' LIMIT 1"
        ),
        |row| {
            let (name, keyword, search, suggest) = (
                sqlite::text(row, 0),
                sqlite::text(row, 1),
                sqlite::text(row, 2),
                sqlite::text(row, 3),
            );
            found = search::engine(
                name.as_deref(),
                keyword.as_deref(),
                search.as_deref(),
                suggest.as_deref(),
            );
            false
        },
    );
    found
}

// MARK: Extensions

/// Chrome's own apps that ship with every profile.
const BUILT_INS: [&str; 8] = [
    "nmmhkkegccagdldgiimedpiccmgmieda", // Chrome Web Store Payments
    "pjkljhegncpnkpknbcohdijeoejaedia", // Gmail (legacy app)
    "blpcfgokakmgnkcojhhkbfbldkacnbeo", // YouTube (legacy app)
    "apdfllckaahabafndbhieahigkjlhalf", // Google Drive (legacy app)
    "aapocclcgogkmnckokdopfmhonfmgoek", // Slides
    "aohghmighlieiainnegkcijnfilokake", // Docs
    "felcaaldnbdncclmgdcncolpebgiejap", // Sheets
    "ahfgeienlihckogmohjhadlkjgocpleb", // Web Store app
];

/// Chromium `Manifest::Location` values that can come from the store: INTERNAL (1),
/// EXTERNAL_PREF_DOWNLOAD (6). EXTERNAL_POLICY_DOWNLOAD (7) is policy, left out.
const STORE_LOCATIONS: [i64; 2] = [1, 6];

struct Manifest<'a> {
    json: Object,
    folder: Place<'a>,
}

/// The Chrome Web Store extensions of a profile, by name. Sources, merged per id:
/// `Preferences` then `Secure Preferences` (`extensions.settings.<id>`) and the unpacked copies
/// under `Extensions/<id>/<version>/manifest.json` (the name resolving `__MSG_x__` through
/// `_locales/<default_locale>/messages.json`). Component, policy, default-installed, unpacked
/// extensions and themes are left out: they cannot be reinstalled from the store.
pub fn extensions<'a>(profile: impl Into<Place<'a>>) -> Vec<Extension> {
    let profile = profile.into();
    let mut settings: BTreeMap<String, Object> = BTreeMap::new();
    for name in ["Preferences", "Secure Preferences"] {
        let Some(root) = profile.join(name).read().ok().and_then(|d| json::object_or_none(&d))
        else {
            continue;
        };
        let Some(entries) =
            json::object(json::object(root.get("extensions")).and_then(|e| e.get("settings")))
        else {
            continue;
        };
        for (id, value) in entries {
            let Some(entry) = value.as_object() else { continue };
            let merged = settings.entry(id.clone()).or_default();
            for (key, field) in entry {
                merged.insert(key.clone(), field.clone());
            }
        }
    }
    let installed = profile.join("Extensions");
    let mut ids: Vec<String> = settings.keys().cloned().collect();
    ids.extend(installed.names());
    ids.sort();
    ids.dedup();
    let empty = Object::new();
    let mut result: Vec<Extension> = ids
        .into_iter()
        .filter(|id| Extension::is_valid_id(id) && !BUILT_INS.contains(&id.as_str()))
        .filter_map(|id| {
            let entry = settings.get(&id).unwrap_or(&empty);
            if let Some(location) = json::int(entry.get("location"))
                && !STORE_LOCATIONS.contains(&location)
            {
                return None;
            }
            if json::boolean(entry.get("was_installed_by_default")) == Some(true)
                || json::boolean(entry.get("was_installed_by_oem")) == Some(true)
            {
                return None;
            }
            let manifest = latest_manifest(&installed.join(&id));
            let pref_manifest = json::object(entry.get("manifest"));
            let name = display_name(manifest.as_ref(), pref_manifest)?;
            let field = |key: &str| {
                manifest
                    .as_ref()
                    .and_then(|m| m.json.get(key))
                    .or_else(|| pref_manifest.and_then(|p| p.get(key)))
            };
            if field("theme").is_some() {
                return None; // Themes are not extensions.
            }
            let from_store = json::boolean(entry.get("from_webstore"))
                .or_else(|| {
                    json::string(manifest.as_ref().and_then(|m| m.json.get("update_url")))
                        .map(|u| u.contains("google.com"))
                })
                .unwrap_or(true);
            let state = json::int(entry.get("state"));
            let disabled =
                state == Some(0) || json::int(entry.get("disable_reasons")).unwrap_or(0) != 0;
            let version = json::string(manifest.as_ref().and_then(|m| m.json.get("version")))
                .or_else(|| json::string(pref_manifest.and_then(|p| p.get("version"))))
                .map(str::to_owned);
            Some(Extension { id, name, version, enabled: !disabled, from_web_store: from_store })
        })
        .filter(|e| e.from_web_store)
        .collect();
    result.sort_by_key(|e| e.name.to_lowercase());
    result
}

/// The manifest in the highest version folder that has a readable one.
fn latest_manifest<'a>(extension_folder: &Place<'a>) -> Option<Manifest<'a>> {
    let mut versions = extension_folder.names();
    versions.sort_by(|a, b| numeric_compare(b, a));
    versions.into_iter().find_map(|version| {
        let folder = extension_folder.join(&version);
        let data = folder.join("manifest.json").read().ok()?;
        Some(Manifest { json: json::object_or_none(&data)?, folder })
    })
}

/// The extension's name: the manifest's (else the preferences' copy), `__MSG_key__` looked up
/// case-insensitively in the default locale's messages, then `en`, then `en_US`.
fn display_name(manifest: Option<&Manifest<'_>>, pref_manifest: Option<&Object>) -> Option<String> {
    let raw = manifest
        .and_then(|m| m.json.get("name"))
        .or_else(|| pref_manifest.and_then(|p| p.get("name")));
    let raw = json::non_empty(raw)?;
    let Some(manifest) = manifest.filter(|_| raw.starts_with("__MSG_") && raw.ends_with("__"))
    else {
        return Some(raw.to_owned());
    };
    let inner: Vec<char> = raw.chars().skip(6).collect();
    let key: String =
        inner.iter().take(inner.len().saturating_sub(2)).collect::<String>().to_lowercase();
    let default_locale = json::string(manifest.json.get("default_locale"));
    for locale in default_locale.into_iter().chain(["en", "en_US"]) {
        let file = manifest.folder.join("_locales").join(locale).join("messages.json");
        let Some(messages) = file.read().ok().and_then(|d| json::object_or_none(&d)) else {
            continue;
        };
        // Message keys are case-insensitive.
        let entry = messages.iter().find(|(k, _)| k.to_lowercase() == key).map(|(_, v)| v);
        if let Some(message) = json::non_empty(json::object(entry).and_then(|e| e.get("message"))) {
            return Some(message.to_owned());
        }
    }
    None
}

/// `String.compare(_:options: .numeric)`: runs of digits compare as numbers.
fn numeric_compare(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let run = |it: &mut std::iter::Peekable<std::str::Chars<'_>>| {
                    let mut digits = String::new();
                    while let Some(ch) = it.peek().copied().filter(char::is_ascii_digit) {
                        digits.push(ch);
                        it.next();
                    }
                    digits.trim_start_matches('0').to_owned()
                };
                let (m, n) = (run(&mut x), run(&mut y));
                let order = m.len().cmp(&n.len()).then_with(|| m.cmp(&n));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(c), Some(d)) => {
                if c != d {
                    return c.cmp(&d);
                }
                x.next();
                y.next();
            }
        }
    }
}
