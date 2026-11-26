//! Chat roots, chat font faces, managed merge, sidebar look and build defaults: Swift `ChatRootValidator`, `ChatFontFaces`, `EffectiveSettings`, `SidebarLookPreset`, `SettingsBuildDefaults`.
//!
//! - `effective.merge` `{file, managed: {forced, recommended}, team: {teamName, defaults, enforced},
//!   legacyKeys: {old: new}, chats: {roots, booleans}}` answers `{root, managedKeys, policy,
//!   diagnostics, managedChatRoots}`: Swift `EffectiveSettings.merge`, layer for layer. The team
//!   layer arrives already limited to the app's catalog (`TeamPolicyLayer.limitedToCatalog`). A
//!   managed key's source is `"device"` or `{"team": NAME}`; a diagnostic is `{kind, path, message}`.
//! - `font_faces.load` `{faces}` answers `{faces: {family[:italic]: data URL}}`: Swift
//!   `ChatFontFaces.Loader.dataURLs`, on [`crate::font_faces`], each file's URL kept until its
//!   path, size or modification time changes.
//! - `chat_roots.refusal` `{path, homes, links}` answers `{refusal: REASON}`, `{}` (allowed) or
//!   `{need: PATH}`: Swift `ChatRootValidator.refusal`. REASON is `relative`, `symlink`, `system`,
//!   `home`, `volume` or `protected`. Rust never reads a link itself: the app answers each `need`
//!   with its own readlink (`links[PATH]` = the target, or null for no link) and asks again, so its
//!   injected resolvers and batch caches still decide, and only folders the walk reaches are read.
//! - `chat_roots.resolve_home` `{home, links}` answers `{home}` (its own links resolved) or `{need}`.
//! - `sidebar_look.entries` `{name, text}` answers `{entries: [{path, value}]}` and
//!   `sidebar_look.fill` `{root, name, text}` answers `{root}`: Swift `SidebarLookPreset`, on
//!   [`crate::sidebar_look::SidebarLook`].

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::{OpError, string};
use crate::domains::Domains;
use crate::font_faces;
use crate::keypath::key_path;
use crate::managed::is_setting_key;
use crate::schema::Schema;
use crate::sidebar_look::SidebarLook;
use crate::value::{char_count, value_at, with_value};

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "effective.merge" => merge(request),
        "font_faces.load" => load_faces(request),
        "chat_roots.refusal" => chat_root_refusal(request),
        "chat_roots.resolve_home" => resolve_home_op(request),
        "sidebar_look.entries" => sidebar_look_entries(request),
        "sidebar_look.fill" => sidebar_look_fill(request),
        _ => return None,
    })
}

/// The object member `key` of `request` as a sorted map; absent is empty.
fn members(request: &Value, key: &str) -> Result<BTreeMap<String, Value>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(BTreeMap::new()),
        Some(Value::Object(map)) => Ok(map.iter().map(|(k, v)| (k.clone(), v.clone())).collect()),
        Some(_) => Err(OpError::Invalid(format!("expected an object `{key}`"))),
    }
}

/// The string array member `key` of `request`; absent is empty.
fn strings_of(request: &Value, key: &str) -> Result<Vec<String>, OpError> {
    match request.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().map(str::to_owned))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| OpError::Invalid(format!("expected a string array `{key}`"))),
        Some(_) => Err(OpError::Invalid(format!("expected a string array `{key}`"))),
    }
}

// MARK: effective.merge

/// What the merge needs beside the layers: the older names of renamed keys and the chat keys.
struct MergeKeys {
    /// Older name -> new name.
    legacy: BTreeMap<String, String>,
    roots_key: String,
    booleans: Vec<String>,
    /// The roots key and every boolean chat key: merged by their own rules, never generically.
    chat_keys: BTreeSet<String>,
}

/// `values` with each older key's value under its new name when the new name is absent.
fn aliasing_map(values: &BTreeMap<String, Value>, keys: &MergeKeys) -> BTreeMap<String, Value> {
    let mut values = values.clone();
    for (old, new) in &keys.legacy {
        if !values.contains_key(new)
            && let Some(value) = values.get(old).cloned()
        {
            values.insert(new.clone(), value);
        }
    }
    values
}

/// `root` with each older key's value at its new path when the new path is unset.
fn aliasing_root(root: Value, keys: &MergeKeys) -> Value {
    let mut root = root;
    for (old, new) in &keys.legacy {
        let new_path = key_path(new);
        if value_at(&root, &new_path).is_none()
            && let Some(value) = value_at(&root, &key_path(old)).cloned()
        {
            root = with_value(&root, value, &new_path);
        }
    }
    root
}

/// Deterministic order, settings keys only and no chat key (a shorter key first, so a nested
/// key set later wins over an object set at its parent).
fn sorted_setting_entries<'a>(
    values: &'a BTreeMap<String, Value>,
    keys: &MergeKeys,
) -> Vec<(&'a String, &'a Value)> {
    let mut entries: Vec<(&String, &Value)> = values
        .iter()
        .filter(|(key, _)| is_setting_key(key) && !keys.chat_keys.contains(*key))
        .collect();
    entries.sort_by(|a, b| (char_count(a.0), a.0).cmp(&(char_count(b.0), b.0)));
    entries
}

/// Swift `ChatSettings.unique`: first occurrence kept, order kept.
fn unique(values: Vec<String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values.into_iter().filter(|value| seen.insert(value.clone())).collect()
}

/// Swift `ChatSettings.strings`: the unique strings of an array value.
fn chat_strings(value: Option<&Value>) -> Vec<String> {
    let items = value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_owned).collect::<Vec<_>>());
    unique(items.unwrap_or_default())
}

#[derive(Clone, PartialEq, Eq, Debug)]
enum Source {
    Device,
    Team(String),
}

/// `{file, managed, team, legacyKeys, chats}` to the effective settings (module docs).
fn merge(request: &Value) -> Result<Value, OpError> {
    let file = request.get("file").cloned().unwrap_or(Value::Null);
    let empty = Value::Object(Map::new());
    let managed_in = request.get("managed").unwrap_or(&empty);
    let team_in = request.get("team").unwrap_or(&empty);
    let chats = request.get("chats").unwrap_or(&empty);
    let legacy = members(request, "legacyKeys")?
        .into_iter()
        .filter_map(|(old, new)| new.as_str().map(|new| (old, new.to_owned())))
        .collect();
    let roots_key = chats.get("roots").and_then(Value::as_str).unwrap_or_default().to_owned();
    let booleans = strings_of(chats, "booleans")?;
    let mut chat_keys: BTreeSet<String> = booleans.iter().cloned().collect();
    if !roots_key.is_empty() {
        chat_keys.insert(roots_key.clone());
    }
    let keys = MergeKeys { legacy, roots_key, booleans, chat_keys };

    let team_name = team_in.get("teamName").and_then(Value::as_str).unwrap_or_default().to_owned();
    let team_defaults = aliasing_map(&members(team_in, "defaults")?, &keys);
    let team_enforced = aliasing_map(&members(team_in, "enforced")?, &keys);
    let forced = aliasing_map(&members(managed_in, "forced")?, &keys);
    let recommended = aliasing_map(&members(managed_in, "recommended")?, &keys);

    let mut root =
        aliasing_root(if file.is_object() { file.clone() } else { empty.clone() }, &keys);
    let mut managed_keys: BTreeMap<String, Source> = BTreeMap::new();
    let mut diagnostics: Vec<Value> = Vec::new();

    // Below the file: fill only absent keys; MDM recommended outranks team default.
    for layer in [&recommended, &team_defaults] {
        for (key, value) in sorted_setting_entries(layer, &keys) {
            let path = key_path(key);
            if value_at(&root, &path).is_none() {
                root = with_value(&root, value.clone(), &path);
            }
        }
    }
    // Above the file: team enforced, then MDM forced overwrites.
    for (key, value) in sorted_setting_entries(&team_enforced, &keys) {
        root = with_value(&root, value.clone(), &key_path(key));
        managed_keys.insert(key.clone(), Source::Team(team_name.clone()));
    }
    for (key, value) in sorted_setting_entries(&forced, &keys) {
        root = with_value(&root, value.clone(), &key_path(key));
        managed_keys.insert(key.clone(), Source::Device);
    }
    for (key, team_value) in &team_enforced {
        if keys.chat_keys.contains(key) {
            continue;
        }
        if forced.get(key).is_some_and(|device| device != team_value) {
            diagnostics.push(json!({
                "kind": "managedConflict",
                "path": key,
                "message": "the team policy value is ignored: the MDM profile manages this key",
            }));
        }
    }
    for key in managed_keys.keys() {
        let path = key_path(key);
        if let Some(mine) = value_at(&file, &path)
            && Some(mine) != value_at(&root, &path)
        {
            diagnostics.push(json!({
                "kind": "managedOverride",
                "path": key,
                "message": "managed by your organization; the value in cmux.json is ignored",
            }));
        }
    }
    // Policy keys come from forced values only: non-forced values in the domain can be written by
    // any local user (`defaults write`).
    let policy: Map<String, Value> = forced
        .iter()
        .filter(|(key, _)| !is_setting_key(key))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();

    // Chats (Swift `EffectiveSettings.mergeChats`): roots are additive and switches can only be
    // forced off. Provenance is kept even when a user root is also managed.
    let roots_path = key_path(&keys.roots_key);
    let managed_roots = unique(
        [&team_defaults, &recommended, &team_enforced, &forced]
            .into_iter()
            .flat_map(|layer| chat_strings(layer.get(&keys.roots_key)))
            .collect(),
    );
    let file_roots = value_at(&file, &roots_path);
    if !keys.roots_key.is_empty() && (!managed_roots.is_empty() || file_roots.is_some()) {
        let mut all = chat_strings(file_roots);
        all.extend(managed_roots.iter().cloned());
        let all: Vec<Value> = unique(all).into_iter().map(Value::String).collect();
        root = with_value(&root, Value::Array(all), &roots_path);
    }
    for key in &keys.booleans {
        let path = key_path(key);
        let in_file = value_at(&file, &path);
        let user = in_file
            .and_then(Value::as_bool)
            .or_else(|| recommended.get(key).and_then(Value::as_bool))
            .or_else(|| team_defaults.get(key).and_then(Value::as_bool))
            .unwrap_or(true);
        let device_off = forced.get(key).and_then(Value::as_bool) == Some(false);
        let team_off = team_enforced.get(key).and_then(Value::as_bool) == Some(false);
        if !user || device_off || team_off || in_file.is_some() {
            root = with_value(&root, Value::Bool(user && !device_off && !team_off), &path);
        }
        if device_off {
            managed_keys.insert(key.clone(), Source::Device);
        } else if team_off {
            managed_keys.insert(key.clone(), Source::Team(team_name.clone()));
        }
    }

    let managed_keys: Map<String, Value> = managed_keys
        .into_iter()
        .map(|(key, source)| {
            let source = match source {
                Source::Device => json!("device"),
                Source::Team(name) => json!({ "team": name }),
            };
            (key, source)
        })
        .collect();
    Ok(json!({
        "root": root,
        "managedKeys": managed_keys,
        "policy": policy,
        "diagnostics": diagnostics,
        "managedChatRoots": managed_roots,
    }))
}

// MARK: font_faces.load

/// What a cached read was of: the file's type, size and modification time.
#[derive(Clone, PartialEq, Eq, Debug)]
struct Stamp {
    kind: &'static str,
    size: u64,
    modified: Option<SystemTime>,
}

/// The data URLs read so far, by path. Bounded: a map holds at most [`font_faces::MAX_FACES`],
/// so a full cache only holds stale paths and is emptied.
fn face_cache() -> &'static Mutex<HashMap<PathBuf, (Stamp, String)>> {
    static CACHE: OnceLock<Mutex<HashMap<PathBuf, (Stamp, String)>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// One file's stamp, or `None` when it is no face: not a plain file (a link is not), too large,
/// or an extension that is not a face type. The bytes are checked against it when read.
fn stamp(path: &Path) -> Option<Stamp> {
    let meta = std::fs::symlink_metadata(path).ok()?;
    if !meta.file_type().is_file() || meta.len() > font_faces::MAX_FACE_BYTES {
        return None;
    }
    let kind =
        path.extension().and_then(|ext| ext.to_str()).and_then(font_faces::extension_kind)?;
    Some(Stamp { kind, size: meta.len(), modified: meta.modified().ok() })
}

/// One entry's page key and data URL, from the cache while its file is unchanged.
fn face(key: &str, value: &Value) -> Option<(String, String)> {
    let page_key = font_faces::face_key(&font_faces::parse_key(key).ok()?);
    let path = font_faces::face_path(value).ok()?;
    let stamp = stamp(&path)?;
    let cache = face_cache();
    if let Some((known, url)) = cache.lock().unwrap_or_else(|e| e.into_inner()).get(&path)
        && *known == stamp
    {
        return Some((page_key, url.clone()));
    }
    match font_faces::load(key, value) {
        Ok(loaded) => {
            let mut cache = cache.lock().unwrap_or_else(|e| e.into_inner());
            if cache.len() >= font_faces::MAX_FACES * 4 {
                cache.clear();
            }
            cache.insert(path, (stamp, loaded.data_url.clone()));
            Some((page_key, loaded.data_url))
        }
        Err(_) => {
            cache.lock().unwrap_or_else(|e| e.into_inner()).remove(&path);
            None
        }
    }
}

/// `{faces}` to `{faces: {family[:italic]: data URL}}`: the first [`font_faces::MAX_FACES`] keys
/// in key order, bad entries skipped. File I/O.
fn load_faces(request: &Value) -> Result<Value, OpError> {
    let faces = members(request, "faces")?;
    let mut loaded = Map::new();
    for (key, value) in faces.iter().take(font_faces::MAX_FACES) {
        if let Some((page_key, url)) = face(key, value) {
            loaded.insert(page_key, Value::String(url));
        }
    }
    Ok(json!({ "faces": loaded }))
}

// MARK: chat_roots.*

const PROTECTED: &str = include_str!("../../../acpmux/data/protected-folders.json");
const MAX_LINKS: usize = 40;

#[derive(Deserialize, Default)]
struct ProtectedEntry {
    path: String,
}

#[derive(Deserialize, Default)]
struct Protected {
    #[serde(rename = "inHome")]
    in_home: Vec<ProtectedEntry>,
    roots: Vec<ProtectedEntry>,
}

/// The one protected-folder list (cmux-tui/crates/acpmux/data/protected-folders.json), as
/// `schema::chat_roots` reads it.
fn protected() -> &'static Protected {
    static LIST: OnceLock<Protected> = OnceLock::new();
    LIST.get_or_init(|| serde_json::from_str(PROTECTED).unwrap_or_default())
}

/// The app's link answers: `Err(path)` while it has not answered for `path`.
fn link(links: &Map<String, Value>, candidate: &str) -> Result<Option<String>, String> {
    match links.get(candidate) {
        None => Err(candidate.to_owned()),
        Some(Value::String(target)) => Ok(Some(target.clone())),
        Some(_) => Ok(None),
    }
}

fn split(path: &str) -> Vec<String> {
    path.split('/').filter(|part| !part.is_empty()).map(str::to_owned).collect()
}

fn fold(path: &str) -> String {
    path.to_lowercase().trim_matches('/').to_owned()
}

fn joined(resolved: &[String], part: Option<&String>) -> String {
    let mut parts: Vec<&str> = resolved.iter().map(String::as_str).collect();
    if let Some(part) = part {
        parts.push(part);
    }
    format!("/{}", parts.join("/"))
}

/// Why `path` (by spelling) may not be a chat root; `homes` are folded.
fn guarded(path: &str, last: bool, homes: &[String]) -> Option<&'static str> {
    let folded = fold(path);
    if last && folded.is_empty() {
        return Some("system");
    }
    if last && homes.contains(&folded) {
        return Some("home");
    }
    let under = |root: &str| folded == root || folded.starts_with(&format!("{root}/"));
    let list = protected();
    if list.roots.iter().any(|entry| under(&fold(&entry.path))) {
        return Some("volume");
    }
    let in_home = homes.iter().any(|home| {
        list.in_home.iter().any(|entry| under(&format!("{home}/{}", entry.path.to_lowercase())))
    });
    in_home.then_some("protected")
}

/// Swift `ChatRootValidator.refusal`: the spelling first (resolving a protected descendant would
/// read it), then each folder on the way, following links through `links`.
fn refusal(
    path: &str,
    homes: &[String],
    links: &Map<String, Value>,
) -> Result<Option<&'static str>, String> {
    if !path.starts_with('/') || path.contains('\0') {
        return Ok(Some("relative"));
    }
    if let Some(reason) = guarded(path, true, homes) {
        return Ok(Some(reason));
    }
    let mut parts = split(path);
    let mut resolved: Vec<String> = Vec::new();
    let mut count: usize = 0;
    while !parts.is_empty() {
        let part = parts.remove(0);
        if part == "." {
            continue;
        }
        if part == ".." {
            resolved.pop();
            continue;
        }
        let candidate = joined(&resolved, Some(&part));
        if let Some(reason) = guarded(&candidate, parts.is_empty(), homes) {
            return Ok(Some(reason));
        }
        if let Some(target) = link(links, &candidate)? {
            count = count.saturating_add(1);
            if count > MAX_LINKS {
                return Ok(Some("symlink"));
            }
            if target.starts_with('/') {
                resolved.clear();
            }
            let mut next = split(&target);
            next.extend(parts);
            parts = next;
        } else {
            resolved.push(part);
        }
    }
    Ok(guarded(&joined(&resolved, None), true, homes))
}

/// Swift `ChatRootValidator.resolveHome`: the home path's own links resolved (never a child of a
/// protected folder); the home as given past [`MAX_LINKS`] links.
fn resolve_home(home: &str, links: &Map<String, Value>) -> Result<String, String> {
    let mut parts = split(home);
    let mut resolved: Vec<String> = Vec::new();
    let mut count: usize = 0;
    while !parts.is_empty() {
        let part = parts.remove(0);
        if part == "." {
            continue;
        }
        if part == ".." {
            resolved.pop();
            continue;
        }
        let candidate = joined(&resolved, Some(&part));
        if let Some(target) = link(links, &candidate)? {
            count = count.saturating_add(1);
            if count > MAX_LINKS {
                return Ok(home.to_owned());
            }
            if target.starts_with('/') {
                resolved.clear();
            }
            let mut next = split(&target);
            next.extend(parts);
            parts = next;
        } else {
            resolved.push(part);
        }
    }
    Ok(joined(&resolved, None))
}

fn links_of(request: &Value) -> Result<Map<String, Value>, OpError> {
    match request.get("links") {
        None | Some(Value::Null) => Ok(Map::new()),
        Some(Value::Object(links)) => Ok(links.clone()),
        Some(_) => Err(OpError::Invalid("expected an object `links`".to_owned())),
    }
}

/// `{path, homes, links}` to `{refusal}`, `{}` or `{need}`.
fn chat_root_refusal(request: &Value) -> Result<Value, OpError> {
    let path = string(request, "path")?;
    let homes: Vec<String> = strings_of(request, "homes")?.iter().map(|home| fold(home)).collect();
    Ok(match refusal(path, &homes, &links_of(request)?) {
        Ok(Some(reason)) => json!({ "refusal": reason }),
        Ok(None) => json!({}),
        Err(need) => json!({ "need": need }),
    })
}

/// `{home, links}` to `{home}` or `{need}`.
fn resolve_home_op(request: &Value) -> Result<Value, OpError> {
    let home = string(request, "home")?;
    Ok(match resolve_home(home, &links_of(request)?) {
        Ok(home) => json!({ "home": home }),
        Err(need) => json!({ "need": need }),
    })
}

// MARK: sidebar_look.*

fn sidebar_look(request: &Value) -> Result<SidebarLook, OpError> {
    let name = string(request, "name")?;
    let text = string(request, "text")?;
    Ok(SidebarLook::read(name, text, Schema::embedded(), &Domains::default()))
}

/// `{name, text}` to `{entries: [{path, value}]}`, in key-path order.
fn sidebar_look_entries(request: &Value) -> Result<Value, OpError> {
    let look = sidebar_look(request)?;
    let entries: Vec<Value> = look
        .values
        .into_iter()
        .map(|(path, value)| json!({ "path": path, "value": value }))
        .collect();
    Ok(json!({ "entries": entries }))
}

/// `{root, name, text}` to `{root}` with every value of the look `root` leaves unset.
fn sidebar_look_fill(request: &Value) -> Result<Value, OpError> {
    let root = request
        .get("root")
        .ok_or_else(|| OpError::Invalid("expected a value `root`".to_owned()))?;
    Ok(json!({ "root": sidebar_look(request)?.filling(root) }))
}

#[cfg(test)]
#[path = "effective_tests.rs"]
mod tests;
