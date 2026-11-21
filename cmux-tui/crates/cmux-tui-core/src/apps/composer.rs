//! The agent chat composer's extension places (DESIGN section 3):
//! `cmux.composer.command/1` (slash commands), `cmux.composer.mention/1`
//! (mention providers) and `cmux.composer.control/1` (footer buttons and
//! menus). All are data in the manifest, so the daemon answers
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
//!
//! A footer control either writes its insert text at the caret (the page
//! does that from the list) or runs an action as its app: the click comes
//! back as `apps.composer.control.run`, only with the person's origin, and
//! the daemon checks the app's grant and the action catalog as it does for
//! the app's own `action.run` before it sends the call to the cmux app. The
//! list leaves out what the app could not run, so no dead control shows.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::actions::{self, ActionDecision};
use super::calls::mint_key;
use super::grants::{Decision, ScopeTable};
use super::mirror::Origin;
use super::provider::Target;
use super::store::text;
use super::supervisor::{ApiError, HostKey, Inner, Supervisor};

pub(super) const COMMAND: &str = "cmux.composer.command/1";
pub(super) const MENTION: &str = "cmux.composer.mention/1";
pub(super) const CONTROL: &str = "cmux.composer.control/1";

/// The most commands `apps.composer.list` answers, over every app.
const MAX_COMMANDS: usize = 256;
/// The most items `apps.composer.mentions` answers, and its default.
const MAX_MENTIONS: usize = 50;
const DEFAULT_MENTIONS: usize = 20;
/// The most footer controls `apps.composer.list` answers, over every app.
const MAX_CONTROLS: usize = 16;

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

/// A footer control as the page draws it. `insert` is set on a button or
/// item that writes text; `action` on one that runs (a click sends
/// `apps.composer.control.run`).
#[derive(Debug, Serialize)]
struct Control {
    app: String,
    extension: String,
    id: String,
    kind: String,
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tooltip: Option<String>,
    placement: String,
    order: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    insert: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    items: Vec<ControlItem>,
}

#[derive(Debug, Serialize)]
struct ControlItem {
    id: String,
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    symbol: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    insert: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ControlRunParams {
    app: String,
    control: String,
    /// The menu item, for a menu.
    item: Option<String>,
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

/// Whether `app` may run `id` as `action.run` today: its grant has the
/// scope and the catalog lets apps run it; the reason when not.
fn may_run(inner: &Inner, app: &str, id: &str, args: &Value) -> Result<(), ApiError> {
    let grant = Supervisor::grant_for(inner, &HostKey { app: app.to_string(), preview: false });
    let params = json!({ "id": id, "args": args });
    match ScopeTable::get().check("action.run", &params, &grant) {
        Decision::Allow(_) => {}
        Decision::Unsupported => {
            return Err(ApiError::new(
                "operation.unsupported",
                "action.run is not in this cmux version",
            ));
        }
        Decision::ScopeMissing(reason) => return Err(ApiError::new("scope.missing", reason)),
    }
    match actions::decide_for(app, Some(id)) {
        ActionDecision::NeedsGesture => Ok(()),
        ActionDecision::Unknown => Err(ApiError::new(
            "operation.unsupported",
            format!("{id} is not an action of this cmux version"),
        )),
        ActionDecision::Refused(reason) => {
            Err(ApiError::new("scope.missing", format!("apps cannot run {reason} actions")))
        }
    }
}

/// What a button or menu item does: `(action, args)` or the insert text.
enum Does {
    Run(String, Value),
    Insert(String),
}

fn does(entry: &Value) -> Option<Does> {
    if let Some(insert) = string(entry, "insert") {
        return Some(Does::Insert(insert));
    }
    let action = string(entry, "action")?;
    Some(Does::Run(action, entry.get("args").cloned().unwrap_or_else(|| json!({}))))
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
        let controls = controls(&inner);
        json!({ "commands": commands, "mentions": mentions, "controls": controls })
    }

    /// `apps.composer.control.run {app, control, item?}`: the person clicked
    /// a footer control (or one of its menu's items). An insert answers
    /// `{insert}`; an action is sent to the cmux app as the control's app's
    /// `action.run` with the person's origin, and answers `{ran}`.
    pub(super) fn composer_control_run(
        &self,
        p: ControlRunParams,
        origin: Origin,
    ) -> Result<Value, ApiError> {
        if origin != Origin::User {
            return Err(ApiError::new(
                "gesture.required",
                "only a person's click runs a composer control",
            ));
        }
        let mut inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let missing = || ApiError::new("apps.composer.control.unknown", "no such composer control");
        let (_, _, options) = places(&inner, CONTROL)
            .into_iter()
            .find(|(app, ..)| *app == p.app)
            .ok_or_else(missing)?;
        let control = options
            .get("controls")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|c| c.get("id").and_then(Value::as_str) == Some(p.control.as_str()))
            .ok_or_else(missing)?;
        let entry = match &p.item {
            Some(item) => control
                .get("items")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .find(|i| i.get("id").and_then(Value::as_str) == Some(item.as_str()))
                .ok_or_else(missing)?,
            None => control,
        };
        let (action, args) = match does(entry).ok_or_else(missing)? {
            Does::Insert(insert) => return Ok(json!({ "insert": insert })),
            Does::Run(action, args) => (action, args),
        };
        may_run(&inner, &p.app, &action, &args)?;
        let params = json!({ "id": action, "args": args });
        let key = format!("app:{}:{}", p.app, mint_key());
        let outs = self
            .send_to_provider_locked(
                &mut inner,
                &p.app,
                Target::Store,
                "action.run",
                params,
                Origin::User,
                Some(key),
            )
            .map_err(|body| ApiError::from_body(&body, "operation.failed"))?;
        drop(inner);
        self.emit(outs);
        Ok(json!({ "ran": action }))
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

/// Every footer control, left then right, each side by `order` and then app
/// and manifest order; an action the app may not run is left out, and a menu
/// with no item left with it.
fn controls(inner: &Inner) -> Vec<Control> {
    let entry_does = |app: &str, entry: &Value| match does(entry)? {
        Does::Insert(insert) => Some((None, Some(insert))),
        Does::Run(action, args) => {
            may_run(inner, app, &action, &args).ok()?;
            Some((Some(action), None))
        }
    };
    let mut out = Vec::new();
    for (app, extension, options) in places(inner, CONTROL) {
        for entry in options.get("controls").and_then(Value::as_array).into_iter().flatten() {
            let (Some(id), Some(label)) = (string(entry, "id"), string(entry, "label")) else {
                continue;
            };
            let kind = string(entry, "kind").unwrap_or_else(|| "button".into());
            let (mut action, mut insert, mut items) = (None, None, Vec::new());
            if kind == "menu" {
                for item in entry.get("items").and_then(Value::as_array).into_iter().flatten() {
                    let (Some(item_id), Some(item_label)) =
                        (string(item, "id"), string(item, "label"))
                    else {
                        continue;
                    };
                    let Some((item_action, item_insert)) = entry_does(app, item) else { continue };
                    items.push(ControlItem {
                        id: item_id,
                        label: item_label,
                        description: string(item, "description"),
                        symbol: string(item, "symbol"),
                        action: item_action,
                        insert: item_insert,
                    });
                }
                if items.is_empty() {
                    continue;
                }
            } else {
                let Some(found) = entry_does(app, entry) else { continue };
                (action, insert) = found;
            }
            out.push(Control {
                app: app.to_string(),
                extension: extension.clone(),
                id,
                kind,
                label,
                symbol: string(entry, "symbol"),
                tooltip: string(entry, "tooltip"),
                placement: string(entry, "placement")
                    .filter(|p| p == "right")
                    .unwrap_or_else(|| "left".into()),
                order: entry.get("order").and_then(Value::as_i64).unwrap_or(0),
                action,
                insert,
                items,
            });
        }
    }
    out.sort_by_key(|c| (c.placement == "right", c.order));
    out.truncate(MAX_CONTROLS);
    out
}
