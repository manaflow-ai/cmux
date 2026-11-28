//! Classic cmux settings that cmux-next reads under another key: the port of
//! Swift `ClassicSettingRename` / `migrateClassicSettings` and
//! `ClassicPreferenceImport` / `importClassicPreferences`.
//!
//! Next adopts the classic `cmux.json` as is on first launch, so without
//! [`rename_edits`] a classic key next renamed is silently ignored and the
//! upgrade loses that setting (hq#1870 parity audit, cx-iy8b7). Only renames
//! with the same effect are listed: a key whose classic value next cannot
//! express, or that next spells differently in kind, stays where it is.
//!
//! Classic's Settings window kept a few link-routing values only in its
//! preferences (UserDefaults), never in `cmux.json`; [`preference_edits`]
//! brings them over once. The app reads the preference domains and the file;
//! this decides what to write.

use std::collections::BTreeSet;

use serde_json::{Value, json};

use crate::domains::Domains;
use crate::schema::{self, Schema};
use crate::value::{canonical, value_at};

/// How a classic value becomes the next value.
#[derive(Debug, Clone, Copy)]
enum Transform {
    /// As is (a mapped entry's table is in [`MAPPED`]).
    Same,
    /// As is, but `custom`: without its template next would search with Google.
    NotCustom,
}

/// One classic key and the next key it moves to.
#[derive(Debug, Clone, Copy)]
struct Rename {
    classic: &'static [&'static str],
    next: &'static [&'static str],
    transform: Transform,
}

/// A table entry's next value for a classic value.
#[derive(Debug, Clone, Copy)]
enum To {
    Bool(bool),
    Text(&'static str),
}

const fn rename(classic: &'static [&'static str], next: &'static [&'static str]) -> Rename {
    Rename { classic, next, transform: Transform::Same }
}

/// Entries mapped through a spelling table.
struct Mapped {
    classic: &'static [&'static str],
    next: &'static [&'static str],
    table: &'static [(&'static str, To)],
}

const MAPPED: &[Mapped] = &[
    // Classic's ring off kept the flash; next's style "none" would drop both.
    Mapped {
        classic: &["notifications", "unreadPaneRing"],
        next: &["notifications", "attention", "persist"],
        table: &[("false", To::Bool(false))],
    },
    Mapped {
        classic: &["app", "newWorkspacePlacement"],
        next: &["workspaces", "newPlacement"],
        table: &[
            ("top", To::Text("top")),
            ("afterCurrent", To::Text("afterCurrent")),
            ("end", To::Text("bottom")),
        ],
    },
    Mapped {
        classic: &["app", "equalizeSplitsOnCreate"],
        next: &["layout", "splitSizing"],
        table: &[("true", To::Text("even")), ("false", To::Text("halve"))],
    },
    Mapped {
        classic: &["app", "minimalMode"],
        next: &["window", "titlebar"],
        table: &[("true", To::Text("minimal")), ("false", To::Text("standard"))],
    },
    Mapped {
        classic: &["app", "focusHistoryIncludesPanesAndTabs"],
        next: &["navigation", "history", "scope"],
        table: &[("true", To::Text("everything")), ("false", To::Text("workspaces"))],
    },
    Mapped {
        classic: &["browser", "discardHiddenWebViews"],
        next: &["browser", "hibernation"],
        table: &[("false", To::Text("off"))],
    },
    Mapped {
        classic: &["notifications", "suppressWhenAppFocused"],
        next: &["notifications", "desktop"],
        table: &[("true", To::Text("whenInactive"))],
    },
    // Next moves a workspace only for a notification; agentActivity's extra moves are not ported.
    Mapped {
        classic: &["app", "reorderOnNotification"],
        next: &["notifications", "attention", "moveToTop"],
        table: &[
            ("true", To::Bool(true)),
            ("false", To::Bool(false)),
            ("off", To::Bool(false)),
            ("notifications", To::Bool(true)),
            ("agentActivity", To::Bool(true)),
        ],
    },
];

/// The renames in Swift's order: each entry and, for a mapped one, its table.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
fn entries() -> Vec<(Rename, Option<&'static Mapped>)> {
    let mapped = |index: usize| {
        let entry = &MAPPED[index];
        (
            Rename { classic: entry.classic, next: entry.next, transform: Transform::Same },
            Some(entry),
        )
    };
    vec![
        (rename(&["paneBorderColor"], &["layout", "paneBorderColor"]), None),
        (rename(&["activePaneBorderColor"], &["focusRing", "color"]), None),
        (
            rename(&["notifications", "paneFlashColor"], &["notifications", "attention", "color"]),
            None,
        ),
        (rename(&["notifications", "paneFlash"], &["notifications", "attention", "flash"]), None),
        (
            rename(
                &["notifications", "paneFlashOnTyping"],
                &["notifications", "attention", "flashOnTyping"],
            ),
            None,
        ),
        mapped(0),
        mapped(1),
        mapped(2),
        mapped(3),
        mapped(4),
        (rename(&["diffViewer", "defaultLayout"], &["diff", "layout"]), None),
        (
            rename(
                &["browser", "showSearchSuggestions"],
                &["browser", "omnibar", "remoteSuggestions"],
            ),
            None,
        ),
        // Engines next doesn't offer stay unmapped (the row refuses them), and so does "custom".
        (
            Rename {
                classic: &["browser", "defaultSearchEngine"],
                next: &["browser", "searchEngine"],
                transform: Transform::NotCustom,
            },
            None,
        ),
        mapped(5),
        mapped(6),
        (rename(&["sidebar", "showPorts"], &["sidebar", "workspaceRow", "ports"]), None),
        (rename(&["sidebar", "showLog"], &["sidebar", "workspaceRow", "log"]), None),
        (rename(&["sidebar", "showProgress"], &["sidebar", "workspaceRow", "progress"]), None),
        (
            rename(&["sidebar", "showPullRequests"], &["sidebar", "workspaceRow", "pullRequest"]),
            None,
        ),
        // "Show Branch + Directory" is two rows in next.
        (
            rename(&["sidebar", "showBranchDirectory"], &["sidebar", "workspaceRow", "directory"]),
            None,
        ),
        (rename(&["sidebar", "showBranchDirectory"], &["sidebar", "workspaceRow", "branch"]), None),
        (rename(&["sidebar", "showAgentActivity"], &["sidebar", "workspaceRow", "working"]), None),
        (
            rename(
                &["sidebar", "showNotificationMessage"],
                &["sidebar", "workspaceRow", "notification"],
            ),
            None,
        ),
        mapped(7),
    ]
}

fn transformed(rename: &Rename, mapped: Option<&Mapped>, value: &Value) -> Option<Value> {
    if let Some(mapped) = mapped {
        let spelling = match value {
            Value::String(text) => text.as_str(),
            Value::Bool(true) => "true",
            Value::Bool(false) => "false",
            _ => return None,
        };
        let (_, to) = mapped.table.iter().find(|(from, _)| *from == spelling)?;
        return Some(match to {
            To::Bool(flag) => Value::Bool(*flag),
            To::Text(text) => json!(text),
        });
    }
    match rename.transform {
        Transform::NotCustom if value.as_str() == Some("custom") => None,
        _ => Some(value.clone()),
    }
}

fn owned(path: &[&str]) -> Vec<String> {
    path.iter().map(|part| (*part).to_owned()).collect()
}

/// One write of a migration: `value` at `path`, or the key removed (`None`).
pub type PathEdit = (Vec<String>, Option<Value>);

/// The edits that move each classic key in `file` (the cmux-next.json root)
/// to its next key, in one atomic write: a value next's row accepts is
/// written and the classic key dropped; a next key already set wins and the
/// classic key is dropped; a classic value next can't express stays.
pub fn rename_edits(file: &Value) -> Vec<PathEdit> {
    let file = canonical(file.clone());
    let schema = Schema::embedded();
    let domains = Domains::default();
    let mut edits = Vec::new();
    for (rename, mapped) in entries() {
        let Some(old) = value_at(&file, rename.classic) else { continue };
        if value_at(&file, rename.next).is_none() {
            let next = owned(rename.next);
            let Some(value) = transformed(&rename, mapped, old) else { continue };
            let accepted = schema
                .row_at(&next)
                .is_some_and(|row| schema::accepts(row, &value, &domains).is_ok());
            if !accepted {
                continue;
            }
            edits.push((next, Some(value)));
        }
        edits.push((owned(rename.classic), None));
    }
    edits
}

// MARK: Preferences

/// The UserDefaults key under which the app records the imported paths.
pub const IMPORTED_KEY: &str = "classicPreferencesImported";

/// The classic preferences a domain may hold, as the app reads them.
pub const PREFERENCE_KEYS: [&str; 4] = [
    "browserDisabledOverride",
    "browserOpenTerminalLinksInCmuxBrowser",
    "browserHostWhitelist",
    "browserExternalOpenPatterns",
];

/// Which classic preference a [`Preference`] reads.
#[derive(Debug, Clone, Copy)]
enum Read {
    /// Classic's effective value: a disabled browser opened every link outside.
    OpenLinks,
    /// Classic's Disable cmux Browser switch.
    Enabled,
    /// One-per-line text (or an older release's array) under this key.
    Lines(&'static str),
}

struct Preference {
    next: &'static [&'static str],
    /// An older next key for the same value: imported under it already, or set in the file, counts.
    legacy: Option<&'static [&'static str]>,
    read: Read,
}

const PREFERENCES: [Preference; 4] = [
    Preference {
        next: &["browser", "openLinksInCmuxBrowser"],
        legacy: Some(&["browser", "openTerminalLinksInCmuxBrowser"]),
        read: Read::OpenLinks,
    },
    Preference { next: &["browser", "enabled"], legacy: None, read: Read::Enabled },
    Preference {
        next: &["browser", "hostsToOpenInEmbeddedBrowser"],
        legacy: None,
        read: Read::Lines("browserHostWhitelist"),
    },
    Preference {
        next: &["browser", "urlsToAlwaysOpenExternally"],
        legacy: None,
        read: Read::Lines("browserExternalOpenPatterns"),
    },
];

impl Preference {
    fn was_imported(&self, done: &BTreeSet<String>) -> bool {
        done.contains(&self.next.join("."))
            || self.legacy.is_some_and(|legacy| done.contains(&legacy.join(".")))
    }
}

/// Swift `object(forKey:) as? Bool`: a bool, or an NSNumber of 0 or 1.
fn object_bool(value: Option<&Value>) -> Option<bool> {
    match value? {
        Value::Bool(flag) => Some(*flag),
        Value::Number(number) => {
            let x = number.as_f64()?;
            if x == 0.0 {
                Some(false)
            } else if x == 1.0 {
                Some(true)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// `UserDefaults.bool(forKey:)`: a bool, a nonzero number, or a string
/// NSString's `boolValue` reads as true (`Y`, `y`, `T`, `t` or a digit 1-9
/// after spaces, a sign and leading zeros).
fn defaults_bool(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().is_some_and(|x| x != 0.0),
        Some(Value::String(text)) => {
            let rest = text.trim_start_matches(|c: char| c.is_whitespace());
            let rest = rest.strip_prefix(['+', '-']).unwrap_or(rest);
            let rest = rest.trim_start_matches('0');
            rest.chars().next().is_some_and(|c| matches!(c, 'Y' | 'y' | 'T' | 't' | '1'..='9'))
        }
        _ => false,
    }
}

/// Swift `LinkRouting.lines`: a string or an array of strings, split into
/// lines, trimmed, with empty and `#` lines dropped; `None` for anything else.
pub fn lines(value: &Value) -> Option<Vec<String>> {
    let texts: Vec<&str> = match value {
        Value::String(text) => vec![text.as_str()],
        Value::Array(items) => items.iter().map(Value::as_str).collect::<Option<_>>()?,
        _ => return None,
    };
    let newline =
        |c: char| matches!(c, '\n' | '\u{B}' | '\u{C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}');
    Some(
        texts
            .into_iter()
            .flat_map(|text| text.split(newline))
            .map(crate::text::trim_whitespaces)
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(str::to_owned)
            .collect(),
    )
}

/// The value `read` takes from one preference domain (its members by key).
fn read_source(read: Read, source: &Value) -> Option<Value> {
    let get = |key: &str| source.get(key);
    match read {
        Read::OpenLinks => {
            if defaults_bool(get("browserDisabledOverride")) {
                return Some(Value::Bool(false));
            }
            object_bool(get("browserOpenTerminalLinksInCmuxBrowser")).map(Value::Bool)
        }
        Read::Enabled => {
            object_bool(get("browserDisabledOverride")).map(|disabled| Value::Bool(!disabled))
        }
        Read::Lines(key) => {
            let raw = get(key)?;
            let raw = match raw {
                Value::String(_) => raw.clone(),
                Value::Array(items) if items.iter().all(Value::is_string) => raw.clone(),
                _ => return None,
            };
            lines(&raw).map(|lines| json!(lines))
        }
    }
}

/// Whether any preference is not imported yet (`done` is the recorded paths).
pub fn preferences_pending(done: &BTreeSet<String>) -> bool {
    PREFERENCES.iter().any(|preference| !preference.was_imported(done))
}

/// What [`preference_edits`] decided.
#[derive(Debug, Clone, PartialEq)]
pub struct PreferenceImport {
    /// The values to set where the file has none yet, in order.
    pub edits: Vec<(Vec<String>, Value)>,
    /// The paths recorded as imported, sorted (what the app stores under [`IMPORTED_KEY`]).
    pub done: Vec<String>,
}

/// Each classic preference's value from the first of `sources` (preference
/// domains, this channel's first) that holds one, once per key: `done` holds
/// the paths already imported. A value `file` already has wins, and a value
/// equal to next's default isn't written.
pub fn preference_edits(
    done: &BTreeSet<String>,
    file: &Value,
    sources: &[Value],
) -> PreferenceImport {
    let file = canonical(file.clone());
    let sources: Vec<Value> = sources.iter().cloned().map(canonical).collect();
    let schema = Schema::embedded();
    let domains = Domains::default();
    let mut done = done.clone();
    let mut edits = Vec::new();
    for preference in &PREFERENCES {
        if preference.was_imported(&done) {
            continue;
        }
        done.insert(preference.next.join("."));
        if preference.legacy.is_some_and(|legacy| value_at(&file, legacy).is_some()) {
            continue;
        }
        let Some(value) = sources.iter().find_map(|source| read_source(preference.read, source))
        else {
            continue;
        };
        if value_at(&file, preference.next).is_some() {
            continue;
        }
        let next = owned(preference.next);
        let Some(row) = schema.row_at(&next) else { continue };
        if schema::accepts(row, &value, &domains).is_err() || row.default.as_ref() == Some(&value) {
            continue;
        }
        edits.push((next, value));
    }
    PreferenceImport { edits, done: done.into_iter().collect() }
}

#[cfg(test)]
#[path = "classic_tests.rs"]
mod tests;
