//! The agent chat composer's extension places (DESIGN section 3):
//! `cmux.composer.command/1` (slash commands), `cmux.composer.mention/1`
//! (mention providers), `cmux.composer.toolbar/1` (toolbar buttons) and
//! `cmux.composer.chip/1` (context chips the person clicks to add text to
//! the draft). All are data in the manifest, so the daemon answers
//! them from the catalog it already holds, with no app host: the composer's
//! `/` menu only lists what `apps.composer.list` returns, and `@` completions
//! are ranked here (`apps.composer.mentions`).
//!
//! Each call reads the live catalog, so a save of an installed local app's
//! manifest changes the next answer: the local reload (`local_reload.rs`)
//! swaps the catalog and broadcasts `apps-changed`, on which a page lists
//! again. Only installed, enabled and visible apps contribute, none in safe
//! mode (every extension is off). A command name an app earlier in id order
//! already took is dropped, so one `/name` never means two things; a chip
//! whose insert text an earlier app already offers is dropped too, so the
//! row never shows two chips that do the same thing.
//!
//! The person's saved prompts (`~/.config/cmux/commands/NAME.md`, written by `cmux agent-config
//! commands add --agent cmux` or Settings > Skills > New Command) come first in the commands, read
//! from their folder on each call, so a new one is in the next chat's `/` menu with no restart.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::store::text;
use super::supervisor::{Inner, Supervisor};

const TOOLBAR: &str = "cmux.composer.toolbar/1";
const CHIP: &str = "cmux.composer.chip/1";
pub(super) const COMMAND: &str = "cmux.composer.command/1";
pub(super) const MENTION: &str = "cmux.composer.mention/1";

/// The most commands `apps.composer.list` answers, over every app.
const MAX_COMMANDS: usize = 256;
/// The most items `apps.composer.mentions` answers, and its default.
const MAX_MENTIONS: usize = 50;
const DEFAULT_MENTIONS: usize = 20;
/// The most chips `apps.composer.list` answers, over every app: one row
/// above the draft, not a menu.
const MAX_CHIPS: usize = 24;

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

#[derive(Debug, Serialize)]
struct Chip {
    app: String,
    extension: String,
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

/// The context chips, in app id and manifest order: an entry without an id,
/// label or insert text is skipped, as is one whose insert text an earlier
/// chip already writes; at most `MAX_CHIPS`.
fn chips(inner: &Inner) -> Vec<Chip> {
    let mut written = HashSet::new();
    let mut chips = Vec::new();
    for (app, extension, options) in places(inner, CHIP) {
        for entry in options.get("chips").and_then(Value::as_array).into_iter().flatten() {
            let (Some(id), Some(label), Some(insert)) =
                (string(entry, "id"), string(entry, "label"), string(entry, "insert"))
            else {
                continue;
            };
            if chips.len() >= MAX_CHIPS || !written.insert(insert.clone()) {
                continue;
            }
            chips.push(Chip {
                app: app.to_string(),
                extension: extension.clone(),
                id,
                label,
                detail: string(entry, "detail"),
                insert,
            });
        }
    }
    chips
}

/// The app id and source name of the person's saved prompts in `apps.composer.list`.
const SAVED_PROMPTS_APP: &str = "cmux/saved-prompts";
const SAVED_PROMPTS_SOURCE: &str = "cmux";

/// The saved prompts in `dir` (`cmux agent-config commands add --agent cmux`), in name order, as
/// composer commands whose pick writes the prompt; at most `MAX_COMMANDS`.
fn saved_prompts(dir: Option<&std::path::Path>) -> Vec<Command> {
    let Some(dir) = dir else { return Vec::new() };
    cmux_agent_customize::commands::list_in(cmux_agent_customize::commands::Target::Cmux, dir)
        .into_iter()
        .filter(|saved| !saved.prompt.trim().is_empty())
        .take(MAX_COMMANDS)
        .map(|saved| Command {
            app: SAVED_PROMPTS_APP.to_string(),
            extension: SAVED_PROMPTS_SOURCE.to_string(),
            name: saved.name,
            description: saved.description,
            hint: None,
            insert: saved.prompt,
        })
        .collect()
}

impl Supervisor {
    /// `apps.composer.list`: every extension slash command, the mention
    /// providers with their item counts, the toolbar buttons and the
    /// context chips.
    pub(super) fn composer_list(&self) -> Value {
        // The person's own saved prompts first: read before the lock, and listed even in safe
        // mode, since they are text the person wrote, not an extension.
        let mut commands = saved_prompts(self.config.sources.saved_prompts.as_deref());
        let mut taken: HashSet<String> = commands.iter().map(|c| c.name.clone()).collect();
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
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
        let mut toolbar_buttons = Vec::new();
        let mut seen_actions = HashSet::new();
        for (_, _, options) in places(&inner, TOOLBAR) {
            for button in options["buttons"].as_array().into_iter().flatten() {
                if let Some(action) = button["action"].as_str()
                    && seen_actions.insert(action)
                {
                    toolbar_buttons.push(button);
                }
            }
        }
        let chips = chips(&inner);
        json!({
            "commands": commands,
            "mentions": mentions,
            "toolbarButtons": toolbar_buttons,
            "chips": chips,
        })
    }

    /// `apps.composer.mentions {query, prefix?, limit?}`: the items that
    /// match, best first (a prefix of the id or label, then of a word, then
    /// anywhere), each rank in provider and manifest order.
    pub(super) fn composer_mentions(&self, p: MentionParams) -> Value {
        let limit = p.limit.map_or(DEFAULT_MENTIONS, |l| {
            usize::try_from(l).unwrap_or(MAX_MENTIONS).clamp(1, MAX_MENTIONS)
        });
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
