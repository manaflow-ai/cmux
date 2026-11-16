//! How the entries stack: the value every key and file takes from the
//! entries that are on (top first) over the base, the conflicts the listing
//! names, and how a settings file is tidied when the library takes keys out.

use std::collections::{BTreeMap, BTreeSet};

use cmux_config::{Schema, jsonc};
use serde_json::Value;

use super::keys::{self, KEYBINDINGS};
use super::{Base, CodeLayer, Conflict, Entry, Listed, Listing, WEB_KEY};
use crate::Error;
use crate::profile::Profile;
use crate::tree;

/// The value of setting `key` in a parsed settings file.
pub(super) fn setting_value(file: &Value, key: &str) -> Option<Value> {
    let row = Schema::embedded().row(key)?;
    cmux_config::value::value_at(file, &row.path).cloned()
}

/// The apps (`local/NAME`) whose manifest `writes` puts on disk.
pub(super) fn apps_written(writes: &BTreeMap<String, Option<Vec<u8>>>) -> Vec<String> {
    let mut apps: Vec<String> = writes
        .iter()
        .filter(|(path, bytes)| bytes.is_some() && tree::is_manifest(path))
        .filter_map(|(path, _)| tree::app_of(path).map(|name| format!("local/{name}")))
        .collect();
    apps.dedup();
    apps
}

/// Settings text after the library took keys out of it: every object the
/// library made that is empty now is taken out too, and the file itself
/// (`None`) when the library made it and nothing of anyone's is left in it.
pub(super) fn prune_made(mut text: String, base: &Base) -> Option<String> {
    let mut made: Vec<&Vec<String>> = base.made_objects.iter().collect();
    made.sort_by_key(|path| std::cmp::Reverse(path.len()));
    for path in made {
        let Ok(file) = jsonc::parse(&text) else { break };
        let empty = cmux_config::value::value_at(&file, path)
            .is_some_and(|value| value.as_object().is_some_and(serde_json::Map::is_empty));
        if empty && let Ok(pruned) = jsonc::remove(&text, path) {
            text = pruned;
        }
    }
    let solid = |text: &str| text.chars().filter(|c| !c.is_whitespace()).collect::<String>();
    let nothing_left = jsonc::parse(&text).is_ok_and(|file| file == Value::Object(Default::default()))
        // A comment is the person's: the file stays.
        && jsonc::strip(&text).is_ok_and(|strict| solid(&strict) == solid(&text));
    if base.made_settings_file && nothing_left { None } else { Some(text) }
}

/// The highest entry that is on with a web part: the layer web-dev.json serves.
pub(super) fn web_top(entries: &[Entry]) -> Option<&CodeLayer> {
    entries.iter().filter(|entry| entry.on).find_map(Entry::web_layer)
}

/// The highest entry that is on whose profile `get` finds something in.
pub(super) fn top<'a, T>(
    entries: &'a [Entry],
    get: impl Fn(&'a Profile) -> Option<&'a T>,
) -> Option<(&'a Entry, &'a T)> {
    entries
        .iter()
        .filter(|entry| entry.on)
        .find_map(|entry| get(&entry.profile).map(|v| (entry, v)))
}

/// Every key and file the stack decides: the top on entry's value, or the
/// base.
pub(super) struct Stacked {
    pub(super) settings: BTreeMap<String, Option<Value>>,
    pub(super) files: BTreeMap<String, Option<String>>,
}

/// The winning binding of every key the entries that are on bind.
pub(super) fn binding_winners(entries: &[Entry]) -> Vec<(String, Value)> {
    keys::winners(
        entries
            .iter()
            .filter(|entry| entry.on)
            .filter_map(|entry| entry.profile.files.get(KEYBINDINGS).map(String::as_str))
            .collect::<Vec<_>>()
            .into_iter(),
    )
}

pub(super) fn stacked(entries: &[Entry], base: &Base) -> Result<Stacked, Error> {
    let mut stack = stacked_whole(entries, base);
    // An app stacks whole, by its folder: the highest entry that is on with
    // any file of `apps/NAME/` gives every file there (one it does not have is
    // not there); with none on, each file is its base.
    let folders: BTreeSet<&str> = base.files.keys().filter_map(|path| tree::app_of(path)).collect();
    for name in folders {
        let prefix = format!("apps/{name}/");
        let winner = entries
            .iter()
            .filter(|entry| entry.on)
            .find(|entry| entry.profile.files.keys().any(|path| path.starts_with(&prefix)));
        if let Some(winner) = winner {
            for (path, value) in
                stack.files.iter_mut().filter(|(path, _)| path.starts_with(&prefix))
            {
                *value = winner.profile.files.get(path).cloned();
            }
        }
    }
    if let Some(under) = base.files.get(KEYBINDINGS) {
        let file = keys::compose(under.as_deref(), &binding_winners(entries))?;
        stack.files.insert(KEYBINDINGS.to_owned(), file);
    }
    Ok(stack)
}

/// [`stacked`] with every file whole.
pub(super) fn stacked_whole(entries: &[Entry], base: &Base) -> Stacked {
    let settings = base
        .settings
        .iter()
        .map(|(key, under)| {
            let value = top(entries, |profile| profile.settings.get(key))
                .map(|(_, value)| Some(value.clone()))
                .unwrap_or_else(|| under.clone());
            (key.clone(), value)
        })
        .collect();
    let files = base
        .files
        .iter()
        .map(|(path, under)| {
            let value = top(entries, |profile| profile.files.get(path))
                .map(|(_, text)| Some(text.clone()))
                .unwrap_or_else(|| under.clone());
            (path.clone(), value)
        })
        .collect();
    Stacked { settings, files }
}

pub(super) fn referenced(entries: &[Entry]) -> (BTreeSet<String>, BTreeSet<String>) {
    let mut settings = BTreeSet::new();
    let mut files = BTreeSet::new();
    for entry in entries {
        settings.extend(entry.profile.settings.keys().cloned());
        files.extend(entry.profile.files.keys().cloned());
    }
    (settings, files)
}

pub(super) fn listing(entries: &[Entry]) -> Listing {
    // Who sets what, among entries that are on, top first.
    let mut setters: BTreeMap<(&'static str, String), Vec<&str>> = BTreeMap::new();
    for entry in entries.iter().filter(|entry| entry.on) {
        for key in entry.profile.settings.keys() {
            setters.entry(("setting", key.clone())).or_default().push(entry.name());
        }
        for (path, text) in &entry.profile.files {
            if path == KEYBINDINGS {
                // One binding at a time: two entries meet only on a key.
                for (id, _) in keys::bindings(text) {
                    let key = format!("{KEYBINDINGS} {id}");
                    setters.entry(("binding", key)).or_default().push(entry.name());
                }
                continue;
            }
            if let Some(name) = tree::app_of(path) {
                // One app at a time: two entries meet on an app folder.
                let names = setters.entry(("app", format!("apps/{name}"))).or_default();
                if names.last() != Some(&entry.name()) {
                    names.push(entry.name());
                }
                continue;
            }
            setters.entry(("file", path.clone())).or_default().push(entry.name());
        }
        if entry.web_layer().is_some() {
            setters.entry(("code", WEB_KEY.to_owned())).or_default().push(entry.name());
        }
    }
    let conflicts: Vec<Conflict> = setters
        .iter()
        .filter_map(|((kind, key), names)| {
            let (winner, losers) = names.split_first()?;
            (!losers.is_empty()).then(|| Conflict {
                kind,
                key: key.clone(),
                winner: (*winner).to_owned(),
                losers: losers.iter().map(|name| (*name).to_owned()).collect(),
            })
        })
        .collect();
    let listed = entries
        .iter()
        .enumerate()
        .map(|(i, entry)| {
            let overridden = conflicts
                .iter()
                .filter(|conflict| entry.on && conflict.losers.iter().any(|n| n == entry.name()))
                .map(|conflict| conflict.key.clone())
                .collect();
            Listed {
                position: i + 1,
                name: entry.name().to_owned(),
                on: entry.on,
                source: entry.source.clone(),
                words: entry.words.clone(),
                description: entry.profile.description.clone(),
                thumbnail: entry.thumbnail.clone(),
                settings: entry.profile.settings.keys().cloned().collect(),
                files: entry.profile.files.keys().cloned().collect(),
                added_ms: entry.added_ms,
                overridden,
                code: entry.code.clone(),
            }
        })
        .collect();
    Listing { entries: listed, conflicts }
}
