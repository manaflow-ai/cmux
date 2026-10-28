//! The location trail store (cx-hnmbt.12): where the person was, one entry
//! per step, recorded by the hosting app with `history.trail.record` and
//! read, removed and cleared through the merged history. The daemon is the
//! only writer of the home session's personal frontend projection
//! `cmux-next/personal/history.locations` (schema 1). An app keeps its own
//! Back/Forward cursor over these steps as view state; it no longer owns a
//! trail document.
//!
//! Step rules, ported from the Swift `LocationTrail.record` and
//! `record(_:at:scope:)` at the end of the trail, so every host that records
//! steps gets the same trail (an app runs the same rules for its own
//! Back/Forward cursor):
//! - the same place (machine and tab) as the newest entry refreshes it;
//! - with `steps: workspaces` (the default, `navigation.history.steps`), a
//!   location in the newest entry's sidebar item (the same top page, or the
//!   same workspace on the same machine) replaces that entry's place, unless
//!   the step is a `jump`;
//! - a quick pass: when the newest entry was entered less than
//!   [`COALESCE_MS`] before this step (and the step is no `jump`), the newest
//!   entry is dropped; when the entry before it is this place, that entry is
//!   refreshed instead of a new one;
//! - else a new entry is appended. At most [`CAPACITY`] entries are kept
//!   (the oldest go). An incognito location is never stored. A remove or
//!   clear joins two neighbours of the same place into one.
//!
//! Entry times come from the step's `at_ms` (the app's clock), so an app
//! knows each of its steps in the rows by place and time.
//!
//! The first write adopts the app's older `history.trail` document (schema
//! 1, Swift `LocationTrail`), without its incognito entries, so an upgrade
//! keeps the trail; list reads show that document until then.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::hidden_doc::{FRONTEND, SCOPE};
use crate::Mux;
use crate::resource::ResourceError;
use crate::workspace_registry::{Actor, WorkspaceMutation};

pub(super) const SUBJECT: &str = "history.locations";
/// The app's own trail document before the daemon owned the trail.
const LEGACY_SUBJECT: &str = "history.trail";
const SCHEMA_VERSION: u32 = 1;
const ORIGIN: &str = "cmux-history";
const MAX_ATTEMPTS: usize = 4;
/// Entries kept, as the Swift `LocationTrail.defaultCapacity`.
pub(super) const CAPACITY: usize = 200;
/// A step sooner than this after the newest entry was entered replaces it
/// (Swift `LocationTrail.defaultCoalesceInterval`, 0.75 s).
pub(super) const COALESCE_MS: i64 = 750;
/// Seconds between the Unix epoch and the Swift reference date 2001-01-01.
const SWIFT_REFERENCE_UNIX_S: f64 = 978_307_200.0;
/// The location fields the store keeps (strings; `machine`, `tab` and
/// `title` required).
const LOCATION_FIELDS: [&str; 13] = [
    "machine",
    "tab",
    "page",
    "workspace",
    "workspace_title",
    "pane",
    "screen",
    "room",
    "content",
    "title",
    "machine_name",
    "url",
    "cwd",
];
const MAX_TEXT: usize = 8192;

#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub(super) struct TrailDocument {
    pub(super) next_id: u64,
    /// Oldest first.
    pub(super) entries: Vec<TrailEntry>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub(super) struct TrailEntry {
    pub(super) id: u64,
    pub(super) window: String,
    pub(super) at_ms: i64,
    pub(super) location: Map<String, Value>,
}

impl TrailEntry {
    fn place(&self) -> (&str, &str) {
        place(&self.location)
    }
}

fn place(location: &Map<String, Value>) -> (&str, &str) {
    let text = |key| location.get(key).and_then(Value::as_str).unwrap_or_default();
    (text("machine"), text("tab"))
}

/// The same sidebar item: the same top page, or the same workspace on the
/// same machine (Swift `HistoryLocation.isSameSidebarItem`).
fn same_sidebar_item(a: &Map<String, Value>, b: &Map<String, Value>) -> bool {
    let text = |location: &Map<String, Value>, key| {
        location.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
    };
    let (a_page, b_page) = (location_page(a), location_page(b));
    if a_page.is_some() || b_page.is_some() {
        return a_page == b_page;
    }
    text(a, "machine") == text(b, "machine") && text(a, "workspace") == text(b, "workspace")
}

fn location_page(location: &Map<String, Value>) -> Option<&str> {
    location.get("page").and_then(Value::as_str)
}

/// How one step is recorded.
pub(super) struct Step<'a> {
    pub(super) window: &'a str,
    pub(super) location: Map<String, Value>,
    pub(super) at_ms: i64,
    /// `steps: workspaces`: a location in the newest entry's sidebar item
    /// replaces it.
    pub(super) workspace_steps: bool,
    /// A place the person jumped to on purpose: the newest entry is never
    /// coalesced away.
    pub(super) jump: bool,
}

impl TrailDocument {
    /// Records one step; the entry it landed in, whether the document
    /// changed, and which step rule applied (the daemon log names it).
    fn record(&mut self, step: Step<'_>) -> (u64, bool, &'static str) {
        let Step { window, location, at_ms, workspace_steps, jump } = step;
        let mut quick_pass = false;
        if let Some(newest) = self.entries.last_mut() {
            let same_place = newest.place() == place(&location);
            // A jump is the base rule only (Swift `recordJump`): never a sidebar replace.
            let sidebar =
                workspace_steps && !jump && same_sidebar_item(&newest.location, &location);
            if same_place || sidebar {
                let changed = newest.location != location || newest.window != window;
                newest.location = location;
                window.clone_into(&mut newest.window);
                let rule = if same_place { "same place" } else { "same sidebar item" };
                return (newest.id, changed, rule);
            }
            if !jump && at_ms.saturating_sub(newest.at_ms) < COALESCE_MS {
                // A quick pass: the newest entry was only passed through.
                self.entries.pop();
                quick_pass = true;
                if let Some(previous) = self.entries.last_mut()
                    && previous.place() == place(&location)
                {
                    previous.location = location;
                    window.clone_into(&mut previous.window);
                    let rule = "quick pass (< 750 ms): newest dropped, previous refreshed";
                    return (previous.id, true, rule);
                }
            }
        }
        let highest = self.entries.iter().map(|entry| entry.id).max().unwrap_or(0);
        self.next_id = self.next_id.max(highest) + 1;
        let id = self.next_id;
        self.entries.push(TrailEntry { id, window: window.to_owned(), at_ms, location });
        let excess = self.entries.len().saturating_sub(CAPACITY);
        self.entries.drain(..excess);
        (id, true, if quick_pass { "quick pass (< 750 ms): newest replaced" } else { "appended" })
    }

    /// Removes every entry of the places the ids name; answers the count.
    fn remove(&mut self, ids: &[u64]) -> u64 {
        let places: HashSet<(String, String)> = self
            .entries
            .iter()
            .filter(|entry| ids.contains(&entry.id))
            .map(|entry| {
                let (machine, tab) = entry.place();
                (machine.to_owned(), tab.to_owned())
            })
            .collect();
        self.retain(|entry| {
            let (machine, tab) = entry.place();
            !places.contains(&(machine.to_owned(), tab.to_owned()))
        })
    }

    /// Removes the entries entered at or after `since_ms` (every entry: None).
    fn clear(&mut self, since_ms: Option<i64>) -> u64 {
        self.retain(|entry| since_ms.is_some_and(|since| entry.at_ms < since))
    }

    /// Keeps the entries `keep` accepts, then joins two neighbours of the
    /// same place into the older one (with the newer context). Answers how
    /// many entries went.
    fn retain(&mut self, keep: impl Fn(&TrailEntry) -> bool) -> u64 {
        let before = self.entries.len();
        self.entries.retain(keep);
        let mut joined: Vec<TrailEntry> = Vec::with_capacity(self.entries.len());
        for entry in self.entries.drain(..) {
            match joined.last_mut() {
                Some(older) if older.place() == entry.place() => {
                    older.location = entry.location;
                    older.window = entry.window;
                }
                _ => joined.push(entry),
            }
        }
        self.entries = joined;
        (before - self.entries.len()) as u64
    }
}

/// The stored document and its projection revision (0: none yet; then the
/// app's older trail, adopted).
pub(super) fn load(mux: &Mux) -> anyhow::Result<(TrailDocument, u64)> {
    if let Some(stored) = mux.get_frontend_projection(FRONTEND, SCOPE, SUBJECT)? {
        let document = if stored.schema_version == SCHEMA_VERSION {
            serde_json::from_value(stored.projection).unwrap_or_default()
        } else {
            TrailDocument::default()
        };
        return Ok((document, stored.projection_revision));
    }
    let legacy = mux.get_frontend_projection(FRONTEND, SCOPE, LEGACY_SUBJECT)?;
    let document = legacy
        .filter(|stored| stored.schema_version == 1)
        .map(|stored| adopt_legacy(&stored.projection))
        .unwrap_or_default();
    Ok((document, 0))
}

/// The Swift `LocationTrail` document as entries 1..n (incognito ones and
/// entries that do not decode are left out).
fn adopt_legacy(trail: &Value) -> TrailDocument {
    let mut document = TrailDocument::default();
    for entry in trail.get("entries").and_then(Value::as_array).into_iter().flatten() {
        let Some(location) = entry.get("location").and_then(Value::as_object) else { continue };
        if location.get("isIncognito").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let key = location.get("key");
        let key_text = |name: &str| key.and_then(|key| key.get(name)).and_then(Value::as_str);
        let (Some(machine), Some(tab)) = (key_text("machine"), key_text("tab")) else { continue };
        let Some(entered) = entry.get("enteredAt").and_then(Value::as_f64) else { continue };
        let mut adopted = Map::new();
        adopted.insert("machine".into(), json!(machine));
        adopted.insert("tab".into(), json!(tab));
        for (from, to) in [
            ("page", "page"),
            ("workspace", "workspace"),
            ("workspaceTitle", "workspace_title"),
            ("pane", "pane"),
            ("screen", "screen"),
            ("room", "room"),
            ("content", "content"),
            ("title", "title"),
            ("machineName", "machine_name"),
            ("url", "url"),
            ("cwd", "cwd"),
        ] {
            if let Some(text) = location.get(from).and_then(Value::as_str) {
                adopted.insert(to.into(), json!(text));
            }
        }
        adopted.entry("title").or_insert_with(|| json!(""));
        document.next_id += 1;
        document.entries.push(TrailEntry {
            id: document.next_id,
            window: location.get("window").and_then(Value::as_str).unwrap_or_default().to_owned(),
            at_ms: ((entered + SWIFT_REFERENCE_UNIX_S) * 1000.0).round() as i64,
            location: adopted,
        });
    }
    let excess = document.entries.len().saturating_sub(CAPACITY);
    document.entries.drain(..excess);
    document
}

/// Applies `change` to the stored document and writes it back when it
/// changed (compare-and-swap; a conflict re-reads and runs `change` again).
/// Answers what `change` answered.
fn change<T>(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    apply: impl Fn(&mut TrailDocument) -> (T, bool),
) -> anyhow::Result<T> {
    let digest = Sha256::digest(key.as_bytes());
    let key_hash: String = digest.iter().take(12).map(|byte| format!("{byte:02x}")).collect();
    let mut last_error = None;
    for _ in 0..MAX_ATTEMPTS {
        let (mut document, revision) = load(mux)?;
        let adopted = document.entries.len();
        let (answer, changed) = apply(&mut document);
        if !changed {
            return Ok(answer);
        }
        let mutation =
            WorkspaceMutation::new(format!("trail-{revision}-{key_hash}"), ORIGIN, actor.clone())?;
        let value = serde_json::to_value(&document)?;
        match mux.put_frontend_projection(
            &mutation,
            FRONTEND,
            SCOPE,
            SUBJECT,
            SCHEMA_VERSION,
            Some(revision),
            &value,
        ) {
            Ok(_) => {
                if revision == 0 && adopted > 0 {
                    log(mux, format!("adopted the app's older history.trail ({adopted} entries)"));
                }
                return Ok(answer);
            }
            Err(error) if error.to_string().contains("projection revision conflict") => {
                last_error = Some(error);
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("history.locations write did not settle")))
}

fn invalid(field: &str, reason: impl Into<String>) -> ResourceError {
    ResourceError::validation_invalid(Some(field), reason)
}

/// The `location` field: an object of the known string fields, with
/// `machine`, `tab` and `title`.
fn location(fields: &Map<String, Value>) -> Result<Map<String, Value>, ResourceError> {
    let object = fields
        .get("location")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("location", "location must be an object"))?;
    let mut kept = Map::new();
    for (name, value) in object {
        if !LOCATION_FIELDS.contains(&name.as_str()) {
            return Err(invalid("location", format!("location has an unknown field {name}")));
        }
        match value {
            Value::Null => {}
            Value::String(text) if text.len() <= MAX_TEXT => {
                kept.insert(name.clone(), value.clone());
                if (name == "machine" || name == "tab") && text.is_empty() {
                    return Err(invalid("location", format!("location.{name} must not be empty")));
                }
            }
            _ => {
                return Err(invalid(
                    "location",
                    format!("location.{name} must be a string of at most {MAX_TEXT} bytes"),
                ));
            }
        }
    }
    for required in ["machine", "tab", "title"] {
        if !kept.contains_key(required) {
            return Err(invalid("location", format!("location.{required} is required")));
        }
    }
    Ok(kept)
}

/// `history.trail.record`: one step of the person's location trail.
pub(super) fn record(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    fields: &Map<String, Value>,
    now_ms: i64,
) -> Result<(Value, bool), ResourceError> {
    const OPERATION: &str = "history.trail.record";
    let window = super::pages::text(fields, "window")?
        .filter(|window| window.len() <= 256)
        .ok_or_else(|| invalid("window", "window must be a string of 1 to 256 bytes"))?;
    let location = location(fields)?;
    let flag = |name: &str| -> Result<bool, ResourceError> {
        match fields.get(name) {
            None | Some(Value::Null) => Ok(false),
            Some(Value::Bool(value)) => Ok(*value),
            Some(_) => Err(invalid(name, format!("{name} must be a boolean"))),
        }
    };
    let jump = flag("jump")?;
    let workspace_steps = match fields.get("steps") {
        None | Some(Value::Null) => true,
        Some(Value::String(steps)) if steps == "workspaces" => true,
        Some(Value::String(steps)) if steps == "everything" => false,
        Some(_) => return Err(invalid("steps", "steps must be workspaces or everything")),
    };
    let at_ms = match fields.get("at_ms") {
        None | Some(Value::Null) => now_ms,
        Some(value) => value
            .as_str()
            .and_then(|text| text.parse::<i64>().ok())
            .filter(|at| *at >= 0)
            .ok_or_else(|| invalid("at_ms", "at_ms must be an unsigned decimal string"))?,
    };
    // Incognito steps never reach the disk (the app keeps them in memory).
    let (machine, tab) = place(&location);
    let what = format!("window {window} machine {machine} tab {tab} at_ms {at_ms} jump {jump}");
    if flag("incognito")? {
        log(mux, format!("dropped (incognito, never stored): {what}"));
        return Ok((json!({"recorded": false}), false));
    }
    let (id, changed, rule) = change(mux, key, actor, |document| {
        let step = Step { window, location: location.clone(), at_ms, workspace_steps, jump };
        let (id, changed, rule) = document.record(step);
        ((id, changed, rule), changed)
    })
    .map_err(|error| super::store_failed(OPERATION, format!("{error:#}")))?;
    let outcome = if changed { "accepted" } else { "unchanged" };
    log(mux, format!("{outcome} location:{id} ({rule}): {what}"));
    Ok((json!({"id": format!("location:{id}"), "recorded": changed}), changed))
}

/// One line of the trail's failure log (cx-hnmbt.14) in the daemon log
/// (the owner's client log): each `history.trail.record` accept, drop or
/// refusal with the step rule or reason. Places are machine and tab ids,
/// never titles or paths.
pub(crate) fn log(mux: &Mux, message: impl std::fmt::Display) {
    mux.report_internal_diagnostic(format!("{}: {message}", super::TRAIL_RECORD_OPERATION));
}

/// The entry ids of `location:<n>` ids (others are not trail ids).
pub(super) fn ids(ids: &[&str]) -> Vec<u64> {
    ids.iter()
        .filter_map(|id| id.strip_prefix("location:"))
        .filter_map(|rest| rest.parse().ok())
        .collect()
}

/// Removes every entry of the places the trail ids name.
pub(super) fn remove(mux: &Mux, key: &str, actor: &Actor, ids: &[u64]) -> anyhow::Result<u64> {
    if ids.is_empty() {
        return Ok(0);
    }
    change(mux, key, actor, |document| {
        let removed = document.remove(ids);
        (removed, removed > 0)
    })
}

/// Removes the entries entered at or after `since_ms` (every entry: None).
pub(super) fn clear(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    since_ms: Option<i64>,
) -> anyhow::Result<u64> {
    change(mux, key, actor, |document| {
        let removed = document.clear(since_ms);
        (removed, removed > 0)
    })
}
