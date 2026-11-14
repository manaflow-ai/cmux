//! The agent chat composer's extension places (DESIGN section 3):
//! `cmux.composer.command/1` (slash commands) and `cmux.composer.mention/1`
//! (mention providers). Both are data in the manifest, so the daemon answers
//! them from the catalog it already holds, with no app host: the composer's
//! `/` menu only lists what `apps.composer.list` returns, and `@` completions
//! are ranked here (`apps.composer.mentions`).
//!
//! Each call reads the live catalog, so a save of an installed local app's
//! manifest changes the next answer: the local reload (`local_reload.rs`)
//! swaps the catalog and broadcasts `apps-changed`, on which a page lists
//! again. Only installed, enabled and visible apps contribute, none in safe
//! mode (every extension is off). A command name an app earlier in id order
//! already took is dropped, so one `/name` never means two things.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::store::text;
use super::supervisor::{Inner, Supervisor};

pub(super) const COMMAND: &str = "cmux.composer.command/1";
pub(super) const MENTION: &str = "cmux.composer.mention/1";

/// The most commands `apps.composer.list` answers, over every app.
const MAX_COMMANDS: usize = 256;
/// The most items `apps.composer.mentions` answers, and its default.
const MAX_MENTIONS: usize = 50;
const DEFAULT_MENTIONS: usize = 20;

#[derive(Debug, Serialize)]
struct Command {
    app: String,
    /// The app's name, which the menu row shows as the command's source.
    extension: String,
    name: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    hint: Option<String>,
    insert: String,
}

#[derive(Debug, Serialize)]
struct Provider {
    app: String,
    extension: String,
    prefix: String,
    items: usize,
}

#[derive(Debug, Serialize)]
struct Mention {
    app: String,
    extension: String,
    prefix: String,
    id: String,
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    insert: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MentionParams {
    /// What follows `@`; empty lists every item.
    #[serde(default)]
    query: String,
    /// Only this provider's items (`@ticket:`).
    prefix: Option<String>,
    /// 1 to 50; default 20.
    limit: Option<u32>,
}

fn string(entry: &Value, key: &str) -> Option<String> {
    entry.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The options of `interface` for every app that contributes, with the
/// app's id and name, in app id order.
fn places<'a>(inner: &'a Inner, interface: &str) -> Vec<(&'a str, String, &'a Value)> {
    if inner.safe_mode.is_some() {
        return Vec::new();
    }
    inner
        .mirror
        .apps
        .iter()
        .filter(|(_, record)| record.installed && record.enabled && !record.hidden)
        .filter_map(|(app, _)| {
            let manifest = &inner.catalog.packages.get(app)?.manifest;
            let options = manifest.get("implements")?.get(interface)?.get("options")?;
            let name = manifest.get("name").map(text).filter(|n| !n.is_empty());
            Some((app.as_str(), name.unwrap_or_else(|| app.clone()), options))
        })
        .collect()
}

/// How well `query` (lowercase) names an item: 0 a prefix of its id or
/// label, 1 a prefix of a word of its label, 2 anywhere in its label;
/// `None` when it does not.
fn rank(query: &str, id: &str, label: &str) -> Option<u8> {
    if query.is_empty() {
        return Some(0);
    }
    let label = label.to_lowercase();
    if id.to_lowercase().starts_with(query) || label.starts_with(query) {
        Some(0)
    } else if label.split(|c: char| !c.is_alphanumeric()).any(|word| word.starts_with(query)) {
        Some(1)
    } else if label.contains(query) {
        Some(2)
    } else {
        None
    }
}

impl Supervisor {
    /// `apps.composer.list`: every extension slash command, and the mention
    /// providers with their item counts.
    pub(super) fn composer_list(&self) -> Value {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut taken = HashSet::new();
        let mut commands = Vec::new();
        for (app, extension, options) in places(&inner, COMMAND) {
            for entry in options.get("commands").and_then(Value::as_array).into_iter().flatten() {
                let (Some(name), Some(insert)) = (string(entry, "name"), string(entry, "insert"))
                else {
                    continue;
                };
                if commands.len() >= MAX_COMMANDS || !taken.insert(name.clone()) {
                    continue;
                }
                commands.push(Command {
                    app: app.to_string(),
                    extension: extension.clone(),
                    name,
                    description: string(entry, "description").unwrap_or_default(),
                    hint: string(entry, "hint"),
                    insert,
                });
            }
        }
        let mentions: Vec<Provider> = places(&inner, MENTION)
            .into_iter()
            .filter_map(|(app, extension, options)| {
                Some(Provider {
                    app: app.to_string(),
                    extension,
                    prefix: string(options, "prefix")?,
                    items: options.get("items").and_then(Value::as_array).map_or(0, Vec::len),
                })
            })
            .collect();
        json!({ "commands": commands, "mentions": mentions })
    }

    /// `apps.composer.mentions {query, prefix?, limit?}`: the items that
    /// match, best first (a prefix of the id or label, then of a word, then
    /// anywhere), each rank in provider and manifest order.
    pub(super) fn composer_mentions(&self, p: MentionParams) -> Value {
        let limit = p.limit.map_or(DEFAULT_MENTIONS, |l| (l as usize).clamp(1, MAX_MENTIONS));
        let query = p.query.trim().to_lowercase();
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut found: Vec<(u8, Mention)> = Vec::new();
        for (app, extension, options) in places(&inner, MENTION) {
            let Some(prefix) = string(options, "prefix") else { continue };
            if p.prefix.as_ref().is_some_and(|want| *want != prefix) {
                continue;
            }
            for entry in options.get("items").and_then(Value::as_array).into_iter().flatten() {
                let (Some(id), Some(label)) = (string(entry, "id"), string(entry, "label")) else {
                    continue;
                };
                let Some(score) = rank(&query, &id, &label) else { continue };
                found.push((
                    score,
                    Mention {
                        app: app.to_string(),
                        extension: extension.clone(),
                        prefix: prefix.clone(),
                        insert: string(entry, "insert").unwrap_or_else(|| label.clone()),
                        detail: string(entry, "detail"),
                        id,
                        label,
                    },
                ));
            }
        }
        found.sort_by_key(|(score, _)| *score);
        found.truncate(limit);
        json!({ "mentions": found.into_iter().map(|(_, m)| m).collect::<Vec<_>>() })
    }
}
