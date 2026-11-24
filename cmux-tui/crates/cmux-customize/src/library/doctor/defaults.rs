//! Settings you set that you may think you are not setting: a value that
//! hides or zeroes something you would see, or one whose default changed
//! since you set it (Leo, 2026-11-19, on pane dividers gone for good because
//! `appearance.surfaces.splitDivider.opacity` was 0 in his file: "i thought
//! we turned those on by default and htat i was following them by default?
//! where's it all at?").
//!
//! ```text
//! not-default  yours: 0, default: 0.6   opacity, width, size ... at 0, or show/visible off, where the default shows it
//! not-default  default changed           the default is not the one there was when you set yours
//! ```
//!
//! The fix is Follow default: the key is taken out of the settings file
//! (comments and the rest stay), after a copy of the file is kept.

use std::collections::BTreeMap;

use cmux_config::{Schema, jsonc};
use serde_json::Value;

use super::{FindingKind, Fix, Found, Level, file_name, line_of_key};
use crate::{Customize, Error};

/// Name parts of a setting whose 0 makes something vanish.
const SIZE_WORDS: &[&str] = &["opacity", "alpha", "width", "thickness", "height", "size", "scale"];
/// Name parts of a setting whose `false` hides something.
const SHOW_WORDS: &[&str] = &["visible", "show", "shown", "display"];

/// One setting as the settings file writes it.
struct Set {
    /// The keys as written (`["appearance.accent"]` for a dotted one).
    written: Vec<String>,
    /// The setting's dotted key.
    key: String,
    value: Value,
    /// `None`: worked out at run time (`default_label` says from what).
    default: Option<Value>,
    default_label: Option<String>,
}

impl Set {
    /// `0.6`, or `follows Window opacity` for a default worked out at run time.
    fn default_words(&self) -> String {
        match (&self.default, &self.default_label) {
            (Some(default), _) => compact(default),
            (None, Some(label)) => format!("follows {label}"),
            (None, None) => "worked out by cmux".to_owned(),
        }
    }
}

impl Customize {
    pub(super) fn default_findings(&self, out: &mut Found) {
        let Some((text, sets)) = self.settings_set() else { return };
        let seen = self.read_doctor_state().seen_defaults;
        let file = &self.roots().settings_file;
        for set in sets {
            if set.default.as_ref() == Some(&set.value) {
                continue;
            }
            let hides = hides(&set.key, &set.value, set.default.as_ref());
            let changed = set
                .default
                .as_ref()
                .and_then(|default| seen.get(&set.key).filter(|old| *old != default));
            if !hides && changed.is_none() {
                continue;
            }
            let yours = compact(&set.value);
            let now = set.default_words();
            let mut detail = format!("Yours: {yours}, default: {now}.");
            if hides {
                detail.push_str(&format!(
                    " At {yours} it hides what {} draws, so it can look like a bug.",
                    set.key.rsplit_once('.').map_or(set.key.as_str(), |(owner, _)| owner)
                ));
            }
            if let Some(old) = changed {
                detail.push_str(&format!(
                    " The default changed from {} to {now} since you set yours.",
                    compact(old)
                ));
            }
            let line = line_of_key(&text, &set.key);
            out.push(
                FindingKind::NotDefault,
                if hides { Level::Warning } else { Level::Info },
                &set.key,
                format!("You are not following the default for {}", set.key),
                detail,
                match line {
                    Some(line) => format!("{}:{line}", file_name(file)),
                    None => file_name(file),
                },
                Some(file),
                line,
                vec![Fix::follow_default(), Fix::open(false)],
            );
        }
    }

    /// For every setting the file sets, the default first seen for it:
    /// `seen`'s, else today's. A setting no longer set is dropped.
    pub(super) fn note_defaults(&self, seen: &BTreeMap<String, Value>) -> BTreeMap<String, Value> {
        let Some((_, sets)) = self.settings_set() else { return seen.clone() };
        sets.into_iter()
            .filter_map(|set| {
                let default = seen.get(&set.key).cloned().or(set.default)?;
                Some((set.key, default))
            })
            .collect()
    }

    /// Takes setting `key` out of the settings file; a copy of the file is kept first.
    pub(super) fn follow_default(&self, key: &str, now_ms: u64) -> Result<String, Error> {
        let file = self.roots().settings_file.clone();
        let (text, sets) = self
            .settings_set()
            .ok_or_else(|| Error::Library(format!("{} does not read", file.display())))?;
        let set = sets
            .into_iter()
            .find(|set| set.key == key)
            .ok_or_else(|| Error::Library(format!("{key} is not set in {}", file_name(&file))))?;
        let edited = jsonc::remove(&text, &set.written)
            .map_err(|error| Error::Library(format!("{key} was not taken out: {error}")))?;
        let kept = self.keep_copy(&file, text.as_bytes(), now_ms)?;
        // Through a link: a settings file in a dotfiles repo stays linked.
        cmux_config::fsio::write_atomic(
            &cmux_config::fsio::resolve_symlinks(&file),
            edited.as_bytes(),
        )?;
        Ok(format!(
            "{key} follows its default ({}) again; the file as it was is at {}",
            set.default_words(),
            kept.display()
        ))
    }

    /// The settings file's text and every setting it sets.
    fn settings_set(&self) -> Option<(String, Vec<Set>)> {
        let text = std::fs::read_to_string(&self.roots().settings_file).ok()?;
        let Ok(Value::Object(object)) = jsonc::parse(&text) else { return None };
        let mut out = Vec::new();
        walk(&object, &mut Vec::new(), &mut Vec::new(), &mut out);
        Some((text, out))
    }
}

fn walk(
    object: &serde_json::Map<String, Value>,
    written: &mut Vec<String>,
    path: &mut Vec<String>,
    out: &mut Vec<Set>,
) {
    let schema = Schema::embedded();
    for (key, value) in object {
        let depth = (written.len(), path.len());
        written.push(key.clone());
        path.extend(key.split('.').map(str::to_owned));
        if let Some(row) = schema.row_at(path) {
            out.push(Set {
                written: written.clone(),
                key: row.key.clone(),
                value: value.clone(),
                default: row.default.clone(),
                default_label: row.default_label.as_ref().map(|label| label.text.clone()),
            });
        } else if let Value::Object(inner) = value {
            walk(inner, written, path, out);
        }
        written.truncate(depth.0);
        path.truncate(depth.1);
    }
}

/// The value makes something the default shows vanish.
/// A default worked out at run time (`None`) counts as one that shows it.
fn hides(key: &str, value: &Value, default: Option<&Value>) -> bool {
    let last = key.rsplit('.').next().unwrap_or(key).to_lowercase();
    let zero = value.as_f64() == Some(0.0)
        && default.is_none_or(|default| default.as_f64().is_some_and(|d| d != 0.0));
    let off = value == &Value::Bool(false) && default.is_none_or(|d| d == &Value::Bool(true));
    (zero && SIZE_WORDS.iter().any(|word| last.contains(word)))
        || (off && SHOW_WORDS.iter().any(|word| last.contains(word)))
}

fn compact(value: &Value) -> String {
    match value {
        Value::String(text) => format!("{text:?}"),
        other => other.to_string(),
    }
}

impl Fix {
    fn follow_default() -> Fix {
        Fix { kind: super::FixKind::FollowDefault, label: "Follow default", confirm: false }
    }
}
