//! The Settings window's navigation: which page and row a deep link opens (Swift
//! `SettingsAnchor`, `SettingsCardID`, `SettingsPageAnchor`, `SettingsDeepLink`).
//!
//! - `settings_window.anchor` `{key}` answers `{anchor: {section, id, header}}`, or `{}` when
//!   Settings shows no such thing: the place a deep link's `setting:` names, a schema row the page
//!   shows (a cmux.json key path), a card (`theme` or `card.theme`), a section header
//!   (`section.keyboard`) or an action button (`importFromBrowser`, or `action.browser.importFromBrowser`).
//! - `settings_window.route` `{section?, setting?, dev_build}` answers `{route}`: the page fragment
//!   for a section and a setting (a schema row focuses its row, any other name opens its section);
//!   `{}` when the Development section is asked for outside a DEV or NIGHTLY build.
//! - `settings_window.link` `{section?, setting?, route?}` answers the arguments of `openSettings`
//!   as the app reads them: `section` only when it names a section, `setting` trimmed (blank is
//!   none), `route` only when it is a `#/settings/` route.
//! - `settings_window.appearance_route` `{background?, workspace?, open}` and
//!   `settings_window.sidebar_route` `{open}` answer `{route}`. `open` is the app's clock
//!   (`DispatchTime.uptimeNanoseconds`), which makes a repeat request a new route.
//! - `settings_window.page_anchor` `{key}` answers `{anchor: {id, category, route}}` for a
//!   page-only place (Settings > Devices' join consent switches), `{}` for any other name.
//! - `settings_window.cards` answers `{cards: [{id, anchor_id, section}]}`, the custom parts of a
//!   section a deep link can name beside the schema rows.

use std::sync::OnceLock;

use serde_json::{Value, json};

use super::{OpError, string};
use crate::keypath::key_path;
use crate::schema::Schema;

/// Settings > Appearance's background picker key (the route's `focus`).
const BACKGROUND_FOCUS: &str = "appearance.background";
/// The Development section: DEV and NIGHTLY builds only.
const DEVELOPMENT: &str = "development";
/// The custom cards a deep link names: (raw value, section). Swift `SettingsCardID`.
const CARDS: [(&str, &str); 7] = [
    ("theme", "appearance"),
    ("terminal", "terminal"),
    ("accounts", "accounts"),
    ("rooms", "rooms"),
    ("browserProfiles", "rooms"),
    ("machines", "machines"),
    ("advanced", "advanced"),
];
/// Swift `SettingsPageAnchor`: the join consent switches.
const PAGE_ANCHORS: [&str; 3] =
    ["devices.join.screen", "devices.join.control", "devices.join.signedInMachines"];
const PAGE_ANCHOR_CATEGORY: &str = "devices";

/// The source of the page layout; `section_actions` is the action buttons at the end of each
/// section (the Swift `SettingsSchema.actions(in:)` is generated from the same file).
const PAGE_LAYOUT: &str = include_str!("../../../../../schemas/settings/source/page-layout.json");

/// Runs a `settings_window.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    match op {
        "settings_window.anchor" => Some(anchor_op(request)),
        "settings_window.route" => Some(route_op(request)),
        "settings_window.link" => Some(Ok(link(request))),
        "settings_window.appearance_route" => Some(Ok(appearance_route_op(request))),
        "settings_window.sidebar_route" => Some(sidebar_route_op(request)),
        "settings_window.page_anchor" => Some(page_anchor_op(request)),
        "settings_window.cards" => Some(Ok(cards_op())),
        _ => None,
    }
}

/// A place in Settings: a section and the id the page scrolls to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Anchor {
    pub section: String,
    pub id: String,
}

impl Anchor {
    fn header(section: &str) -> Self {
        Self { section: section.to_owned(), id: format!("section.{section}") }
    }

    fn action(action: &str, section: &str) -> Self {
        Self { section: section.to_owned(), id: format!("action.{section}.{action}") }
    }

    /// Whether this is its section's header.
    pub fn is_header(&self) -> bool {
        self.id == Self::header(&self.section).id
    }
}

/// The section ids, in the order of the schema (Swift `SettingsSection.allCases`).
fn sections() -> impl Iterator<Item = &'static str> {
    Schema::embedded().sections.iter().map(|section| section.id.as_str())
}

/// The action ids drawn at the end of `section` (Swift `SettingsSchema.actions(in:)`).
fn actions_in(section: &str) -> Vec<&'static str> {
    static LAYOUT: OnceLock<Value> = OnceLock::new();
    let layout = LAYOUT
        // A layout that does not parse draws no section actions (the settings behavior tests parse it).
        .get_or_init(|| serde_json::from_str(PAGE_LAYOUT).unwrap_or(Value::Null));
    layout
        .pointer(&format!("/section_actions/{section}"))
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

/// Whether the Settings page shows the row (Swift `isShownOnSettingsPage`: a cmux-next row the
/// page does not hide).
fn shown_on_page(row: &crate::schema::Row) -> bool {
    let raw = row.raw();
    let for_next = raw
        .get("consumers")
        .and_then(Value::as_array)
        .is_some_and(|consumers| consumers.iter().any(|name| name == "cmux-next"));
    for_next && raw.get("page_hidden").and_then(Value::as_bool) != Some(true)
}

/// The anchor `key` names: a schema row, a card, a section header or an action button.
pub fn anchor(key: &str) -> Option<Anchor> {
    let key = key.trim();
    if key.is_empty() {
        return None;
    }
    let schema = Schema::embedded();
    if let Some(row) = schema.row_at(&key_path(key)).filter(|row| shown_on_page(row)) {
        return Some(Anchor { section: row.section.clone(), id: row.key.clone() });
    }
    if let Some((name, section)) =
        CARDS.iter().find(|(name, _)| key == format!("card.{name}") || key == *name)
    {
        return Some(Anchor { section: (*section).to_owned(), id: format!("card.{name}") });
    }
    for section in sections() {
        let header = Anchor::header(section);
        if key == header.id {
            return Some(header);
        }
        for action in actions_in(section) {
            let anchor = Anchor::action(action, section);
            if key == action || key == anchor.id {
                return Some(anchor);
            }
        }
    }
    None
}

/// The page fragment for `section` and `setting`; `None` opens Settings on its default page.
pub fn route(section: Option<&str>, setting: Option<&str>, dev_build: bool) -> Option<String> {
    if let Some(setting) = setting
        && let Some(row) = Schema::embedded().row_at(&key_path(setting))
    {
        if row.section == DEVELOPMENT && !dev_build {
            return None;
        }
        return Some(format!("#/settings/{}?focus={}", row.section, row.key));
    }
    let section = section?;
    if section == DEVELOPMENT && !dev_build {
        return None;
    }
    Some(format!("#/settings/{section}"))
}

fn optional<'a>(request: &'a Value, key: &str) -> Option<&'a str> {
    request.get(key).and_then(Value::as_str)
}

fn anchor_op(request: &Value) -> Result<Value, OpError> {
    Ok(match anchor(string(request, "key")?) {
        Some(anchor) => {
            json!({ "anchor": { "section": anchor.section, "id": anchor.id, "header": anchor.is_header() } })
        }
        None => json!({}),
    })
}

fn route_op(request: &Value) -> Result<Value, OpError> {
    let dev_build = request.get("dev_build").and_then(Value::as_bool).unwrap_or(false);
    Ok(match route(optional(request, "section"), optional(request, "setting"), dev_build) {
        Some(route) => json!({ "route": route }),
        None => json!({}),
    })
}

/// `text`, trimmed; `None` when blank.
fn text(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|text| !text.is_empty())
}

fn link(request: &Value) -> Value {
    let mut link = serde_json::Map::new();
    if let Some(section) =
        text(optional(request, "section")).filter(|name| sections().any(|id| id == *name))
    {
        link.insert("section".to_owned(), json!(section));
    }
    if let Some(setting) = text(optional(request, "setting")) {
        link.insert("setting".to_owned(), json!(setting));
    }
    if let Some(route) =
        text(optional(request, "route")).filter(|route| route.starts_with("#/settings/"))
    {
        link.insert("route".to_owned(), json!(route));
    }
    Value::Object(link)
}

fn open_of(request: &Value) -> Result<u64, OpError> {
    request
        .get("open")
        .and_then(Value::as_u64)
        .ok_or_else(|| OpError::Invalid("expected an integer `open`".to_owned()))
}

/// Foundation's `CharacterSet.alphanumerics`: letters and digits stay, all else is escaped.
fn percent_encode(text: &str) -> String {
    let mut out = String::new();
    for ch in text.chars() {
        if ch.is_alphanumeric() {
            out.push(ch);
        } else {
            let mut buffer = [0u8; 4];
            for byte in ch.encode_utf8(&mut buffer).bytes() {
                out.push_str(&format!("%{byte:02X}"));
            }
        }
    }
    out
}

fn appearance_route_op(request: &Value) -> Value {
    let background = request.get("background").and_then(Value::as_bool).unwrap_or(false);
    let mut query: Vec<String> = Vec::new();
    if background {
        let open = request.get("open").and_then(Value::as_u64).unwrap_or(0);
        query.push(format!("focus={BACKGROUND_FOCUS}"));
        query.push(format!("open={open}"));
    }
    if let Some(workspace) = optional(request, "workspace") {
        query.push(format!("workspace={}", percent_encode(workspace)));
    }
    let suffix = if query.is_empty() { String::new() } else { format!("?{}", query.join("&")) };
    json!({ "route": format!("#/settings/appearance{suffix}") })
}

fn sidebar_route_op(request: &Value) -> Result<Value, OpError> {
    Ok(json!({ "route": format!("#/settings/sidebar?open={}", open_of(request)?) }))
}

fn page_anchor_op(request: &Value) -> Result<Value, OpError> {
    let key = string(request, "key")?.trim();
    Ok(match PAGE_ANCHORS.iter().find(|id| **id == key) {
        Some(id) => json!({ "anchor": {
            "id": id,
            "category": PAGE_ANCHOR_CATEGORY,
            "route": format!("#/settings/{PAGE_ANCHOR_CATEGORY}?focus={id}"),
        } }),
        None => json!({}),
    })
}

fn cards_op() -> Value {
    let cards: Vec<Value> = CARDS
        .iter()
        .map(|(id, section)| json!({ "id": id, "anchor_id": format!("card.{id}"), "section": section }))
        .collect();
    json!({ "cards": cards })
}

#[cfg(test)]
#[path = "settings_window_tests.rs"]
mod tests;
