//! Arc's `StorableSidebar.json` (`ArcSidebarReader.swift`). Arc keeps its bookmarks in the
//! sidebar, not in Chromium's `Bookmarks` file: each space has a pinned container (tabs and
//! nested folders, called lists), and each profile has a Favorites row (top apps). Unpinned
//! tabs are open tabs, not bookmarks.
//!
//! Shape (the first of `sidebar.containers` with `items` or `spaces`): `items` and `spaces` are
//! flat arrays that alternate an id string and the object; items link through `parentID` /
//! `childrenIds`. A space names its profile as `{"default": true}` or
//! `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}` and lists `containerIDs` as
//! `["unpinned", id, "pinned", id]`; `topAppsContainerIDs` alternates a profile and a container
//! id the same way.

use crate::json::{self, Object};
use crate::model::{Bookmark, ReadError};
use crate::{time, url};
use serde_json::Value;
use std::collections::HashMap;

/// Bookmarks of the profile in folder `profile_directory` ("Default", "Profile 1"): Favorites
/// first, then each space's pinned items under the space's name.
pub fn bookmarks(data: &[u8], profile_directory: &str) -> Result<Vec<Bookmark>, ReadError> {
    let root = json::parse_object(data).map_err(|e| ReadError::Syntax(e.to_string()))?;
    let containers = root
        .as_ref()
        .and_then(|root| json::object(root.get("sidebar")))
        .and_then(|sidebar| json::objects(sidebar.get("containers")))
        .ok_or(ReadError::Shape("notSidebar"))?;
    let Some(container) =
        containers.into_iter().find(|c| c.contains_key("items") || c.contains_key("spaces"))
    else {
        return Ok(Vec::new());
    };
    let mut items: HashMap<&str, &Object> = HashMap::new();
    for item in objects(container.get("items")) {
        if let Some(id) = json::string(item.get("id")) {
            items.entry(id).or_insert(item);
        }
    }
    let mut result = Vec::new();
    // Favorites: the profile's top-apps container.
    for (profile, id) in pairs(container.get("topAppsContainerIDs")) {
        if profile == profile_directory {
            walk(id, &items, &["Favorites".to_owned()], 0, &mut result);
        }
    }
    for space in objects(container.get("spaces")) {
        if self::profile_directory(space.get("profile")).as_deref() != Some(profile_directory) {
            continue;
        }
        let title = json::non_empty(space.get("title")).unwrap_or("Space").to_owned();
        let ids = space.get("containerIDs").and_then(Value::as_array).map(Vec::as_slice);
        let ids = ids.unwrap_or_default();
        for (index, value) in ids.iter().enumerate() {
            if value.as_str() != Some("pinned") {
                continue;
            }
            let Some(pinned) = index.checked_add(1).and_then(|next| ids.get(next)) else {
                continue;
            };
            let Some(pinned) = pinned.as_str() else { continue };
            walk(pinned, &items, std::slice::from_ref(&title), 0, &mut result);
        }
    }
    Ok(result)
}

fn walk(
    id: &str,
    items: &HashMap<&str, &Object>,
    path: &[String],
    depth: usize,
    result: &mut Vec<Bookmark>,
) {
    if depth >= 64 {
        return;
    }
    let Some(node) = items.get(id) else { return };
    for child_id in json::strings(node.get("childrenIds")).unwrap_or_default() {
        let Some(child) = items.get(child_id) else { continue };
        let data = json::object(child.get("data"));
        if let Some(tab) = data.and_then(|d| json::object(d.get("tab"))) {
            let Some(text) = json::string(tab.get("savedURL")).and_then(url::importable) else {
                continue;
            };
            let title = [json::string(child.get("title")), json::string(tab.get("savedTitle"))]
                .into_iter()
                .flatten()
                .find(|t| !t.is_empty())
                .unwrap_or(text);
            let created = json::double(child.get("createdAt")).and_then(time::cocoa);
            result.push(Bookmark {
                title: title.to_owned(),
                url: text.to_owned(),
                folder_path: path.to_vec(),
                date_added: created,
            });
        } else if data.is_some_and(|d| d.contains_key("list") || d.contains_key("itemContainer")) {
            let mut inner = path.to_vec();
            if let Some(name) = json::non_empty(child.get("title")) {
                inner.push(name.to_owned());
            }
            walk(child_id, items, &inner, depth.saturating_add(1), result);
        }
    }
}

/// The objects of an alternating id/object array.
fn objects(value: Option<&Value>) -> Vec<&Object> {
    value
        .and_then(Value::as_array)
        .map(|list| list.iter().filter_map(Value::as_object).collect())
        .unwrap_or_default()
}

/// (profile directory, container id) pairs of `topAppsContainerIDs`.
fn pairs(value: Option<&Value>) -> Vec<(String, &str)> {
    let list = value.and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let mut result = Vec::new();
    let mut index = 0usize;
    while let (Some(first), Some(second)) =
        (list.get(index), index.checked_add(1).and_then(|next| list.get(next)))
    {
        if let (Some(profile), Some(id)) = (profile_directory(Some(first)), second.as_str()) {
            result.push((profile, id));
            index = index.saturating_add(2);
        } else {
            index = index.saturating_add(1);
        }
    }
    result
}

/// "Default" for `{"default": ...}`, the folder name for a custom profile.
pub fn profile_directory(value: Option<&Value>) -> Option<String> {
    let profile = json::object(value)?;
    if profile.contains_key("default") {
        return Some("Default".to_owned());
    }
    let inner = json::object(json::object(profile.get("custom")).and_then(|c| c.get("_0")));
    json::non_empty(inner.and_then(|i| i.get("directoryBasename"))).map(str::to_owned)
}
