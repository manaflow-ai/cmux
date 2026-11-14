//! Build cmux extensions from Rust.
//!
//! An extension is a folder with a manifest (`cmux-app.json`) and a script cmux runs in its
//! sandbox (written with the TypeScript package `cmux-extension-sdk`, next to this crate). This
//! crate is the Rust side of the same SDK, built from the same tables the runtime and the
//! TypeScript package read (`build.rs`):
//!
//! - the versions ([`API_VERSION`], [`RUNTIME_VERSION`]), the event streams ([`EVENTS`]) and the
//!   live sources ([`SIGNALS`]) an extension can use, with the scope each needs;
//! - [`Manifest`], a typed builder for `cmux-app.json` that asks for the right scopes when you
//!   say which events you listen to;
//! - [`validate`] and [`check_package`], the validator cmux itself runs before it loads an
//!   extension, so a tool or a test can refuse what cmux would refuse.

/// The table `build.rs` writes from the runtime's sources: nothing generated is committed.
mod api {
    use crate::{Event, Signal};
    include!(concat!(env!("OUT_DIR"), "/api.rs"));
}

pub use api::{API_VERSION, EVENTS, RUNTIME_VERSION, SIGNALS};
pub use cmux_app_manifest::{Issue, PackageReport, Severity, is_valid};

use serde_json::{Map, Value, json};
use std::path::Path;

/// This crate's version; the TypeScript package carries the same one.
pub const SDK_VERSION: &str = env!("CARGO_PKG_VERSION");

/// An event stream: an invalidation with no payload. The app reads `reads` again when it fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub name: &'static str,
    pub docs: &'static str,
    /// The read op it invalidates; the daemon sends the event only to an app that may call it.
    pub reads: &'static str,
    /// The scope the manifest must ask for to hear it.
    pub scope: &'static str,
}

/// A live source `cmux.watch(name)` reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Signal {
    pub name: &'static str,
    pub docs: &'static str,
    /// Holding any one of these lets an app read it.
    pub scopes: &'static [&'static str],
    /// The events that push a re-read; empty when the runtime polls behind it.
    pub push: &'static [&'static str],
}

/// The event stream named `name`, if cmux sends it.
pub fn event(name: &str) -> Option<&'static Event> {
    EVENTS.iter().find(|e| e.name == name)
}

/// The live source named `name`, if there is one.
pub fn signal(name: &str) -> Option<&'static Signal> {
    SIGNALS.iter().find(|s| s.name == name)
}

/// Where a sidebar section starts; the person moves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Region {
    Top,
    Middle,
    Bottom,
}

impl Region {
    fn as_str(self) -> &'static str {
        match self {
            Region::Top => "top",
            Region::Middle => "middle",
            Region::Bottom => "bottom",
        }
    }
}

/// A builder for an extension's `cmux-app.json` (manifest v2).
///
/// ```
/// use cmux_extension_sdk::{Manifest, Region};
/// let manifest = Manifest::new("local/hello", "Hello", "0.1.0", "Says hello.")
///     .section("renderSection", "Hello", "sparkles", Region::Bottom)
///     .listen("workspace.changed")
///     .unwrap();
/// assert!(cmux_extension_sdk::is_valid(&manifest.validate()));
/// ```
#[derive(Debug, Clone)]
pub struct Manifest {
    value: Map<String, Value>,
}

impl Manifest {
    /// `id` is `local/<name>` while you develop, `<github-owner>/<name>` to publish;
    /// `description` is the one line the store and the consent card show.
    pub fn new(id: &str, name: &str, version: &str, description: &str) -> Self {
        let mut value = Map::new();
        value.insert("manifestVersion".into(), json!(2));
        value.insert("id".into(), json!(id));
        value.insert("name".into(), json!({ "en": name }));
        value.insert("version".into(), json!(version));
        value.insert("description".into(), json!({ "en": description }));
        value.insert("engines".into(), json!({ "cmux": "^2.0" }));
        value.insert("runtime".into(), json!({ "main": "dist/main.js" }));
        Manifest { value }
    }

    /// Sets `name` in the object at `key`, making the object when it is missing.
    fn insert_in(&mut self, key: &str, name: &str, value: Value) {
        let mut map = match self.value.remove(key) {
            Some(Value::Object(map)) => map,
            _ => Map::new(),
        };
        map.insert(name.into(), value);
        self.value.insert(key.into(), Value::Object(map));
    }

    /// Sets a top-level field the builder has no method for (`publisher`,
    /// `repository`, `license`, `icon`, `settings`, `files`, ...).
    pub fn field(mut self, key: &str, value: Value) -> Self {
        self.value.insert(key.into(), value);
        self
    }

    fn implement(
        mut self,
        interface: &str,
        export: &str,
        title: &str,
        symbol: &str,
        options: Option<Value>,
    ) -> Self {
        let mut place = Map::new();
        place.insert("export".into(), json!(export));
        place.insert("title".into(), json!({ "en": title }));
        place.insert("symbol".into(), json!(symbol));
        if let Some(options) = options {
            place.insert("options".into(), options);
        }
        self.insert_in("implements", interface, Value::Object(place));
        self.activate(&format!("onInterface:{interface}"))
    }

    fn activate(mut self, trigger: &str) -> Self {
        let list = self.value.entry("activation").or_insert_with(|| json!([]));
        if let Value::Array(items) = list
            && !items.iter().any(|t| t == trigger)
        {
            items.push(json!(trigger));
        }
        self
    }

    /// A sidebar section (`cmux.section/1`) drawn by the script's `export`.
    pub fn section(self, export: &str, title: &str, symbol: &str, region: Region) -> Self {
        let options = json!({ "defaultRegion": region.as_str() });
        self.implement("cmux.section/1", export, title, symbol, Some(options))
    }

    /// A pane (`cmux.pane/1`) drawn by the script's `export`.
    pub fn pane(self, export: &str, title: &str, symbol: &str) -> Self {
        self.implement("cmux.pane/1", export, title, symbol, None)
    }

    /// Appends `entry` to the list `list` in the options of the data-only place `interface`
    /// (no script runs for it, so it adds no activation).
    fn append_data(mut self, interface: &str, list: &str, entry: Value) -> Self {
        let implements = self.value.entry("implements").or_insert_with(|| json!({}));
        if let Value::Object(places) = implements
            && let Some(Value::Object(options)) = places
                .entry(interface)
                .or_insert_with(|| json!({ "options": {} }))
                .get_mut("options")
            && let Value::Array(items) = options.entry(list).or_insert_with(|| json!([]))
        {
            items.push(entry);
        }
        self
    }

    /// A slash command in the agent chat composer (`cmux.composer.command/1`): the `/` menu lists
    /// it as `/name`, and picking it writes `insert` over the typed `/word`. Data only: cmux reads
    /// it from the manifest, and a save updates the menu without a restart.
    pub fn slash_command(self, name: &str, description: &str, insert: &str) -> Self {
        let entry = json!({ "name": name, "description": description, "insert": insert });
        self.append_data("cmux.composer.command/1", "commands", entry)
    }

    /// An item the person names with `@prefix` in the composer (`cmux.composer.mention/1`); the
    /// daemon answers the completions. `insert` is what the mention writes (the label when None).
    pub fn mention(self, prefix: &str, id: &str, label: &str, insert: Option<&str>) -> Self {
        let mut item = json!({ "id": id, "label": label });
        if let Some(insert) = insert {
            item["insert"] = json!(insert);
        }
        let mut me = self.append_data("cmux.composer.mention/1", "items", item);
        if let Some(Value::Object(options)) = me
            .value
            .get_mut("implements")
            .and_then(|p| p.get_mut("cmux.composer.mention/1"))
            .and_then(|p| p.get_mut("options"))
        {
            options.insert("prefix".into(), json!(prefix));
        }
        me
    }

    /// A chat widget (`cmux.chat.widget/1`) drawn by the script's `export`: a card in the agent
    /// chat under each tool call whose name matches one of `tools` (`*` matches any run of
    /// characters), and for widget parts that name this extension. With no `tools` it draws only
    /// the widget parts.
    pub fn chat_widget(self, export: &str, title: &str, symbol: &str, tools: &[&str]) -> Self {
        let options = (!tools.is_empty()).then(|| json!({ "tools": tools }));
        self.implement("cmux.chat.widget/1", export, title, symbol, options)
    }

    /// Asks for `scope`; `why` is what the consent card shows the person.
    pub fn scope(mut self, scope: &str, why: &str) -> Self {
        self.insert_in("scopes", scope, json!(why));
        self
    }

    /// Says the extension listens to `stream` and asks for the scope it needs (unless the
    /// manifest already asks for it). An unknown stream is an error naming the known ones.
    pub fn listen(self, stream: &str) -> Result<Self, String> {
        let Some(event) = event(stream) else {
            let known: Vec<&str> = EVENTS.iter().map(|e| e.name).collect();
            return Err(format!(
                "cmux sends no event stream {stream:?}; known: {}",
                known.join(", ")
            ));
        };
        if self.value.get("scopes").and_then(|s| s.get(event.scope)).is_some() {
            return Ok(self);
        }
        Ok(self.scope(event.scope, event.docs))
    }

    /// The manifest as JSON, ready to write as `cmux-app.json`.
    pub fn to_json(&self) -> Value {
        Value::Object(self.value.clone())
    }

    /// What cmux's validator says about this manifest (empty when it would load it).
    pub fn validate(&self) -> Vec<Issue> {
        validate(&self.to_json())
    }
}

/// What cmux's validator says about a manifest.
pub fn validate(manifest: &Value) -> Vec<Issue> {
    cmux_app_manifest::validate_manifest(manifest)
}

/// Validates an extension folder the way cmux does before it loads it: `cmux-app.json`, and the
/// files and catalog it names.
pub fn check_package(dir: &Path) -> PackageReport {
    cmux_app_manifest::validate_package(dir)
}
