//! Settings written for another cmux, read by this one. A setup, a profile,
//! a theme file or a person's cmux-next.json can name a key by the name an
//! older cmux gave it; [`migrate`] rewrites such an object through the
//! retired-keys table (`schemas/settings/retired-keys.json`, the same table
//! the settings owner and the app read) and says what it changed.
//!
//! A renamed key (`replaced_by`) moves to its new name, its value carried as
//! is or through the entry's `values`; a removed key (no `replaced_by`) is
//! dropped. Each change is a [`Notice`]. The deprecation window
//! (`since`..`until`) does not change what `migrate` does: an old name past
//! its `until` still migrates at install, and [`Notice::window_ended`] is
//! what an author-time check (`cmux setup check`) reports as an error.
//!
//! The table has no chains (a `replaced_by` is never itself retired), so one
//! pass is the whole rewrite.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::schema::{Retired, choice_aliases, replaced_by_row, retired_entries};

/// What happened to one key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NoticeKind {
    /// The key has a new name; its value is there now.
    Renamed,
    /// The key is gone (or its value has no equivalent under the new name):
    /// it was dropped and that setting keeps its default.
    Removed,
    /// The key stays; its value is a choice the row renamed, now the new
    /// one (`old_value`, `new_value`).
    RenamedValue,
}

/// One key [`migrate`] rewrote.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Notice {
    /// The old dotted key.
    pub from: String,
    /// The key that took its place, when one did.
    pub to: Option<String>,
    pub kind: NoticeKind,
    /// Why, for a person: the table's reason, or what happened to the value.
    pub reason: String,
    /// When the old name stopped being the setting (`YYYY-MM-DD` or a cmux version).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub since: Option<String>,
    /// The end of the deprecation window (`YYYY-MM-DD` or a cmux version).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub until: Option<String>,
    /// For a renamed value: the value as written.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_value: Option<Value>,
    /// For a renamed value: the value it is now.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub new_value: Option<Value>,
}

impl Notice {
    fn of(entry: &Retired, kind: NoticeKind, reason: String) -> Notice {
        Notice {
            from: entry.key.clone(),
            to: entry.replaced_by.clone(),
            kind,
            reason,
            since: entry.since.clone(),
            until: entry.until.clone(),
            old_value: None,
            new_value: None,
        }
    }

    /// One line for a person: `old.key is now new.key (until 2027-01-01)`.
    pub fn message(&self) -> String {
        let until =
            self.until.as_ref().map(|until| format!(" (until {until})")).unwrap_or_default();
        match (self.kind, &self.to) {
            (NoticeKind::RenamedValue, _) => format!("{}: {}{until}", self.from, self.reason),
            (NoticeKind::Renamed, Some(to)) => format!("{} is now {to}{until}", self.from),
            (NoticeKind::Removed, Some(to)) => {
                format!("{} is now {to}, {}{until}", self.from, self.reason)
            }
            _ => format!("{} was removed: {}{until}", self.from, self.reason),
        }
    }

    /// Whether the window has ended: `until` is a date before `today`
    /// (`YYYY-MM-DD`), or a cmux version `running` (`X.Y.Z`) has reached. An
    /// entry with no `until`, or one that cannot be read, has not ended.
    pub fn window_ended(&self, today: &str, running: &str) -> bool {
        let Some(until) = self.until.as_deref() else { return false };
        if let (Some(until), Some(today)) = (date(until), date(today)) {
            return today > until;
        }
        match (version(until), version(running)) {
            (Some(until), Some(running)) => running != (0, 0, 0) && running >= until,
            _ => false,
        }
    }
}

/// `settings` (an object with dotted or nested keys, or both) with every
/// retired key rewritten, and what was rewritten. A key spelled the new way
/// wins over the old spelling of the same setting; anything that is not an
/// object comes back as it is.
pub fn migrate(settings: &Value) -> (Value, Vec<Notice>) {
    let Value::Object(members) = settings else { return (settings.clone(), Vec::new()) };
    let mut members = members.clone();
    let mut notices = Vec::new();
    for entry in retired_entries() {
        let old = path(&entry.key);
        let Some((value, dotted)) = take(&mut members, &old) else { continue };
        let Some(new_key) = &entry.replaced_by else {
            notices.push(Notice::of(entry, NoticeKind::Removed, entry.reason.clone()));
            continue;
        };
        let new = path(new_key);
        if find(&members, &new).is_some() {
            let reason = format!("{new_key} is set too, so the old key is dropped");
            notices.push(Notice::of(entry, NoticeKind::Renamed, reason));
            continue;
        }
        // This old key's own entry (a row may replace several: `updates.automatic`).
        let carried = replaced_by_row(&new)
            .find(|replaced| replaced.old == old)
            .and_then(|replaced| replaced.read(&value))
            .cloned();
        let Some(carried) = carried else {
            let reason = "which has no equivalent of this value and keeps its default".to_owned();
            notices.push(Notice::of(entry, NoticeKind::Removed, reason));
            continue;
        };
        if dotted {
            members.insert(new_key.clone(), carried);
        } else if let Value::Object(nested) =
            crate::value::with_value(&Value::Object(members.clone()), carried, &new)
        {
            members = nested;
        }
        notices.push(Notice::of(entry, NoticeKind::Renamed, entry.reason.clone()));
    }
    // A choice value a row renamed (its `aliases`), under the key's new name.
    for (key, aliases) in choice_aliases() {
        let Some(value) = find_mut(&mut members, &path(key)) else { continue };
        let Some(new) = value.as_str().and_then(|old| aliases.get(old)) else { continue };
        let old = std::mem::replace(value, Value::String(new.clone()));
        notices.push(Notice {
            from: key.clone(),
            to: Some(key.clone()),
            kind: NoticeKind::RenamedValue,
            reason: format!("{old} is now \"{new}\""),
            since: None,
            until: None,
            old_value: Some(old),
            new_value: Some(Value::String(new.clone())),
        });
    }
    (Value::Object(members), notices)
}

/// [`find`], for a change in place.
fn find_mut<'a>(members: &'a mut Map<String, Value>, path: &[String]) -> Option<&'a mut Value> {
    let (head, rest) = splits(path).find(|(head, rest)| match members.get(head) {
        Some(_) if rest.is_empty() => true,
        Some(Value::Object(child)) => find(child, rest).is_some(),
        _ => false,
    })?;
    let value = members.get_mut(&head)?;
    if rest.is_empty() {
        return Some(value);
    }
    find_mut(value.as_object_mut()?, rest)
}

/// Each way to spell `path` as one key and what is under it, shortest first:
/// (`a`, [b, c]), (`a.b`, [c]), (`a.b.c`, []).
fn splits(path: &[String]) -> impl Iterator<Item = (String, &[String])> {
    (1..=path.len()).filter_map(move |at| {
        let (head, rest) = path.split_at_checked(at)?;
        Some((head.join("."), rest))
    })
}

/// [`migrate`] for settings by dotted key (a profile's or a setup's).
pub fn migrate_dotted(
    settings: &BTreeMap<String, Value>,
) -> (BTreeMap<String, Value>, Vec<Notice>) {
    let object = Value::Object(settings.iter().map(|(k, v)| (k.clone(), v.clone())).collect());
    let (migrated, notices) = migrate(&object);
    let Value::Object(members) = migrated else { return (settings.clone(), notices) };
    (members.into_iter().collect(), notices)
}

fn path(dotted: &str) -> Vec<String> {
    dotted.split('.').map(str::to_string).collect()
}

/// Where `path` is in `members`, spelled any way (`a.b.c`, `a: {b.c}`,
/// `a.b: {c}`, ...): the first spelling found, in that order.
fn find<'a>(members: &'a Map<String, Value>, path: &[String]) -> Option<&'a Value> {
    splits(path).find_map(|(head, rest)| {
        let value = members.get(&head)?;
        if rest.is_empty() {
            return Some(value);
        }
        find(value.as_object()?, rest)
    })
}

/// Removes `path` from `members` (spelled any way) and returns its value and
/// whether it was one dotted key at the top. An object it leaves empty goes too.
fn take(members: &mut Map<String, Value>, path: &[String]) -> Option<(Value, bool)> {
    for (head, rest) in splits(path) {
        if rest.is_empty() {
            if let Some(value) = members.remove(&head) {
                return Some((value, true));
            }
            continue;
        }
        let Some(Value::Object(child)) = members.get_mut(&head) else { continue };
        if let Some((value, _)) = take(child, rest) {
            if child.is_empty() {
                members.remove(&head);
            }
            return Some((value, false));
        }
    }
    None
}

fn date(text: &str) -> Option<(u32, u32, u32)> {
    let mut parts = text.split('-');
    let year = parts.next().filter(|part| part.len() == 4)?.parse().ok()?;
    let month = parts.next().filter(|part| part.len() == 2)?.parse().ok()?;
    let day = parts.next().filter(|part| part.len() == 2)?.parse().ok()?;
    parts.next().is_none().then_some((year, month, day))
}

fn version(text: &str) -> Option<(u64, u64, u64)> {
    let core = text.trim_start_matches('v').split(['-', '+', ' ']).next()?;
    let mut parts = core.split('.').map(|part| part.parse::<u64>());
    let major = parts.next()?.ok()?;
    let minor = parts.next().unwrap_or(Ok(0)).ok()?;
    let patch = parts.next().unwrap_or(Ok(0)).ok()?;
    Some((major, minor, patch))
}

pub mod classic;
pub mod once;
pub mod renamed;

#[cfg(test)]
mod tests;
