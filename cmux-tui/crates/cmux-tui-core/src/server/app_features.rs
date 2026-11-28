//! The routed `apps.features` namespace (page-router.md "Routed namespaces"):
//! the App Store's Features tab, built-in features as switches. Leo (10-21):
//! "have that app store area as a sort of way to, like, toggle things on and
//! off ... instead of having it be so-called experimental".
//!
//! A feature is one existing settings key, never a new one: a switch reads
//! the key's effective value and writes the same key Settings writes, so the
//! store adds no state and changes no default.
//!
//! - `apps.features.list {}`: `{revision, features: [{id, group, key, on,
//!   default_on, managed, title, summary}]}`, [`CURATED`] in order, then every
//!   `labs.*` and `experiments.*` toggle the schema has (so a new experiment
//!   shows up here without a store change).
//! - `apps.features.set {id, on}` (mutation): a toggle writes `on`; a choice
//!   feature writes its value when turned on and, turned off, resets the key
//!   to its default (only while the key holds that value). `{revision,
//!   replayed, changed}`. A managed key, an unknown id, or a default that
//!   already is the "on" value is refused.
//!
//! Both sit behind [`GATE`] (`experiments.appStoreFeatures`, off by default,
//! Leo's UI rule "merge default-off"): while it is off the list says
//! `enabled: false` with no features and the page draws no Features tab, and
//! a set is refused.

use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::sync::Arc;

use super::Mux;
use crate::resource::ResourceError;
use cmux_config::schema::Kind;
use cmux_config::{Op, Origin, Row, Schema, State, Target, WriteMeta};

/// The routed owner's name in spec/page-router.json.
pub(super) const OWNER: &str = "apps.features";

/// The experiment that turns the Features tab on (schemas/settings/source/experiments.json).
pub(crate) const GATE: &str = "experiments.appStoreFeatures";

/// Whether [`GATE`] is on in `state` (a missing key reads as off).
fn gate_on(state: &State) -> bool {
    let view = state.get(&Target::Key(GATE.to_owned()));
    let value = view.row.as_ref().and_then(|row| row.value.clone()).or(view.value);
    value == Some(Value::Bool(true))
}

/// One curated feature: a settings key and, for a choice key, the value
/// that means "on" (a toggle key's "on" is `true`).
struct Curated {
    id: &'static str,
    group: &'static str,
    key: &'static str,
    on: Option<&'static str>,
}

const fn toggle(id: &'static str, group: &'static str, key: &'static str) -> Curated {
    Curated { id, group, key, on: None }
}

const fn choice(
    id: &'static str,
    group: &'static str,
    key: &'static str,
    on: &'static str,
) -> Curated {
    Curated { id, group, key, on: Some(on) }
}

/// The built-in features the store lists first, by group (the Swift
/// `AppFeature` catalog's switchable entries; density pickers and sidebar
/// items stay in Settings).
const CURATED: &[Curated] = &[
    choice("backgrounds.shufflePaintings", "Backgrounds", "appearance.background", "daily"),
    choice("backgrounds.desktopWallpaper", "Backgrounds", "appearance.background", "desktop"),
    choice("backgrounds.glass", "Backgrounds", "appearance.backgroundBlur", "glass"),
    choice("backgrounds.perPane", "Backgrounds", "appearance.paneBackgrounds", "perPane"),
    toggle("chief.pet", "Chief", "home.chiefPetEnabled"),
    toggle("chief.channels", "Chief", "home.channelsEnabled"),
    toggle("chief.suggestedTasks", "Chief", "sessions.promptSuggestions"),
    toggle("chief.githubFeed", "Chief", "feed.github.enabled"),
    toggle("chat.needsYou", "Chief", "agentPane.needsYou.enabled"),
    toggle("media.newTabNowPlaying", "Music", "tabs.newTabNowPlaying"),
    toggle("media.sidebar", "Music", "sidebar.nowPlaying.enabled"),
    choice("appearance.calm", "Appearance", "ui.calm", "calm"),
    choice("appearance.brailleStatus", "Appearance", "appearance.statusIndicator.style", "braille"),
    toggle("appearance.runningCommands", "Appearance", "status.inferCommandBusy"),
    toggle("appearance.detailedStatusIcons", "Appearance", "sidebar.detailedStatusIcons"),
    choice("editor.splitDiff", "Editor", "diff.layout", "split"),
    toggle("editor.minimap", "Editor", "editor.minimap.enabled"),
    toggle("sidebar.priorityView", "Sidebar", "sidebar.priorityView"),
    toggle("sidebar.hoverCards", "Sidebar", "sidebar.hoverCards.enabled"),
    toggle("sidebar.workspacesAsTabs", "Sidebar", "sidebar.workspacesAsTabs"),
    toggle("sidebar.sessionTree", "Sidebar", "sidebar.sessionTree"),
    toggle("sidebar.groupByComputer", "Sidebar", "sidebar.groupByComputer"),
    toggle("browser.agentCursor", "Browser", "browser.showAgentCursor"),
    toggle("browser.bookmarksBar", "Browser", "browser.showBookmarksBar"),
    toggle("browser.fullURLs", "Browser", "browser.omnibar.showFullURLs"),
    toggle("devices.globalHotKey", "Devices", "app.globalHotKey"),
    toggle("layout.focusFollowsMouse", "Devices", "layout.focusFollowsMouse"),
];

/// The prefixes whose toggles are listed after [`CURATED`], each as its group.
const DYNAMIC: &[(&str, &str)] = &[("labs.", "Labs"), ("experiments.", "Experiments")];

/// One feature as the store lists it: its settings row and "on" value.
pub(crate) struct Feature {
    pub id: String,
    pub group: &'static str,
    pub row: &'static Row,
    /// The value that means on: `true` for a toggle, a choice's value.
    pub on: Value,
}

impl Feature {
    fn is_toggle(&self) -> bool {
        matches!(self.row.kind, Kind::Toggle)
    }
}

/// Every feature the store lists, in order. A curated entry whose key the
/// schema lacks (or whose kind no longer fits) is left out.
pub(crate) fn features(schema: &'static Schema) -> Vec<Feature> {
    let mut out = Vec::new();
    for entry in CURATED {
        let Some(row) = schema.row(entry.key) else { continue };
        let on = match (&row.kind, entry.on) {
            (Kind::Toggle, None) => Value::Bool(true),
            (Kind::Choice(choices), Some(value)) if choices.iter().any(|c| c.value == value) => {
                Value::String(value.to_owned())
            }
            _ => continue,
        };
        out.push(Feature { id: entry.id.to_owned(), group: entry.group, row, on });
    }
    for (prefix, group) in DYNAMIC {
        for row in schema.rows_in(None) {
            // The gate is the tab itself, not a feature on it.
            if row.key.starts_with(prefix) && matches!(row.kind, Kind::Toggle) && row.key != GATE {
                out.push(Feature { id: row.key.clone(), group, row, on: Value::Bool(true) });
            }
        }
    }
    out
}

fn text_json(text: &cmux_config::schema::Text) -> Value {
    json!({"key": text.key, "text": text.text})
}

/// One feature's row for `apps.features.list`, read from `state`.
fn feature_json(state: &State, feature: &Feature) -> Value {
    let view = state.get(&Target::Key(feature.row.key.clone()));
    let row = view.row.as_ref();
    let value = row.and_then(|row| row.value.clone()).or(view.value.clone());
    let default = row.and_then(|row| row.default.clone());
    let managed = view.managed.is_some() || row.is_some_and(|row| row.managed.is_some());
    let mut title = text_json(&feature.row.title);
    // A choice feature is named by its choice, not the key's title
    // ("Background" says less than "Shuffle Paintings").
    if let (Kind::Choice(choices), Value::String(on)) = (&feature.row.kind, &feature.on)
        && let Some(choice) = choices.iter().find(|c| &c.value == on)
    {
        title = json!({
            "key": choice.title.key,
            "text": format!("{}: {}", feature.row.title.text, choice.title.text),
        });
    }
    json!({
        "id": feature.id,
        "group": feature.group,
        "key": feature.row.key,
        "kind": if feature.is_toggle() { "toggle" } else { "choice" },
        "on": value.as_ref() == Some(&feature.on),
        "default_on": default.as_ref() == Some(&feature.on),
        "managed": managed,
        "title": title,
        "summary": feature.row.summary.as_ref().map(text_json),
    })
}

/// What `apps.features.set` writes for `on` given the key's current value.
#[derive(Debug, PartialEq)]
pub(crate) enum Write {
    Set(Value),
    Reset,
    /// Already as asked.
    Nothing,
}

pub(crate) fn plan(
    feature_on: &Value,
    is_toggle: bool,
    current: Option<&Value>,
    on: bool,
) -> Write {
    let holds = current == Some(feature_on);
    match (is_toggle, on, holds) {
        (_, true, true) | (_, false, false) => Write::Nothing,
        (true, on, _) => Write::Set(Value::Bool(on)),
        (false, true, _) => Write::Set(feature_on.clone()),
        (false, false, true) => Write::Reset,
    }
}

/// Unknown fields are ignored, so an older or newer page still talks to this daemon.
#[derive(Deserialize)]
struct SetParams {
    id: String,
    on: bool,
    idempotency_key: String,
}

#[derive(Deserialize)]
struct ListParams {}

fn decode<T: for<'de> Deserialize<'de>>(params: Map<String, Value>) -> Result<T, ResourceError> {
    serde_json::from_value(Value::Object(params))
        .map_err(|error| ResourceError::validation_invalid(Some("params"), error.to_string()))
}

/// Runs one routed `apps.features.*` operation.
pub(super) fn routed(
    mux: &Arc<Mux>,
    operation: &str,
    params: Map<String, Value>,
) -> Result<Value, ResourceError> {
    match operation {
        "apps.features.list" => {
            let ListParams {} = decode(params)?;
            Ok(mux.with_settings(|state| {
                if !gate_on(state) {
                    return json!({"revision": state.revision(), "enabled": false, "features": []});
                }
                let list = features(state.schema());
                json!({
                    "revision": state.revision(),
                    "enabled": true,
                    "features": list.iter().map(|f| feature_json(state, f)).collect::<Vec<_>>(),
                })
            }))
        }
        "apps.features.set" => {
            let SetParams { id, on, idempotency_key } = decode(params)?;
            let (key, write, managed) = mux.with_settings(|state| {
                if !gate_on(state) {
                    return Err(ResourceError::operation_failed(
                        operation,
                        "the Features tab is off (Settings > Advanced > Experiments)",
                        json!({"key": GATE}),
                    ));
                }
                let list = features(state.schema());
                let feature = list.into_iter().find(|f| f.id == id).ok_or_else(|| {
                    ResourceError::validation_invalid(Some("id"), format!("no feature {id:?}"))
                })?;
                let view = state.get(&Target::Key(feature.row.key.clone()));
                let row = view.row.as_ref();
                let current = row.and_then(|row| row.value.clone()).or(view.value.clone());
                let managed = view.managed.is_some() || row.is_some_and(|r| r.managed.is_some());
                let write = plan(&feature.on, feature.is_toggle(), current.as_ref(), on);
                Ok::<_, ResourceError>((feature.row.key.clone(), write, managed))
            })?;
            if managed && write != Write::Nothing {
                return Err(ResourceError::operation_failed(
                    operation,
                    "this setting is managed by your organization",
                    json!({"key": key}),
                ));
            }
            let meta = WriteMeta {
                origin: Origin::User,
                idempotency_key: Some(idempotency_key),
                if_revision: None,
            };
            let target = Target::Key(key.clone());
            let op = match write {
                Write::Set(value) => Op::Set { target, value, meta },
                Write::Reset => Op::Reset { target, meta },
                Write::Nothing => {
                    return Ok(mux.with_settings(|state| {
                        json!({"revision": state.revision(), "replayed": false, "changed": false})
                    }));
                }
            };
            let outcome = mux.settings_apply(op).map_err(|refusal| {
                ResourceError::operation_failed(
                    operation,
                    "settings refused the write",
                    json!({"key": key, "refusal": format!("{refusal:?}")}),
                )
            })?;
            Ok(json!({
                "revision": outcome.revision,
                "replayed": outcome.replayed,
                "changed": true,
            }))
        }
        _ => Err(ResourceError::operation_failed(
            operation,
            "apps.features has no such operation",
            json!({}),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_curated_entry_names_a_schema_row_of_its_kind() {
        let schema = Schema::embedded();
        let listed = features(schema);
        for entry in CURATED {
            assert!(
                listed.iter().any(|f| f.id == entry.id),
                "{} ({}) is not a {} row in the schema",
                entry.id,
                entry.key,
                if entry.on.is_some() { "choice" } else { "toggle" }
            );
        }
    }

    #[test]
    fn no_feature_is_on_by_default_through_its_choice() {
        // A choice feature's "on" is never the default: turning it off resets.
        for feature in features(Schema::embedded()) {
            if !feature.is_toggle() {
                assert_ne!(feature.row.default.as_ref(), Some(&feature.on), "{}", feature.id);
            }
        }
    }

    #[test]
    fn ids_are_unique_and_experiments_are_listed() {
        let list = features(Schema::embedded());
        let mut ids: Vec<_> = list.iter().map(|f| f.id.as_str()).collect();
        let total = ids.len();
        ids.sort_unstable();
        ids.dedup();
        assert_eq!(ids.len(), total);
        assert!(list.iter().any(|f| f.group == "Experiments"));
        assert!(list.iter().any(|f| f.group == "Labs"));
    }

    #[test]
    fn the_gate_is_an_experiment_that_is_off_by_default() {
        let row =
            Schema::embedded().row(GATE).expect("experiments.appStoreFeatures is a schema row");
        assert!(matches!(row.kind, Kind::Toggle));
        assert_eq!(row.default, Some(Value::Bool(false)));
        assert!(
            features(Schema::embedded()).iter().all(|f| f.row.key != GATE),
            "the gate is not a switch on its own tab"
        );
    }

    #[test]
    fn plan_writes_only_what_changes() {
        let t = Value::Bool(true);
        assert_eq!(plan(&t, true, Some(&Value::Bool(false)), true), Write::Set(t.clone()));
        assert_eq!(plan(&t, true, Some(&t), false), Write::Set(Value::Bool(false)));
        assert_eq!(plan(&t, true, Some(&t), true), Write::Nothing);
        let daily = json!("daily");
        assert_eq!(plan(&daily, false, Some(&json!("none")), true), Write::Set(daily.clone()));
        assert_eq!(plan(&daily, false, Some(&daily), false), Write::Reset);
        // Off while another choice holds: leave the person's choice alone.
        assert_eq!(plan(&daily, false, Some(&json!("desktop")), false), Write::Nothing);
    }
}
