//! A person's design system outside one folder (RFD 0009 slice 8). The system a check holds a
//! scene to, and the one the Settings page shows, is built in layers, lowest first, each a
//! `cmux.design/1` document merged over the ones below (`System::merge`):
//!
//! 1. cmux's own system (`System::cmux`).
//! 2. The active theme file's `design` layer (`appearance.themeFile`, `themes/NAME.json` or a
//!    shipped one): a theme pack's type and spacing (DESIGN.md 6.4).
//! 3. The person's `design.json` beside the settings file (`~/.config/cmux/design.json`),
//!    shared by every extension they make.
//! 4. The extension folder's `cmux-design.json` (or `ext design --system FILE`).
//!
//! The merge reads the base fresh each time, so when cmux's own system changes in an update a
//! person keeps what they set and inherits the rest. A person's file may record the base it was
//! written against (`"base"`, written by `cmux ext design --stamp`): each role cmux changed since
//! is listed in `changed`, which the viewer marks. A layer that does not read is one `system`
//! warning and is skipped; the layers under it still apply.

use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::design::Finding;
use super::design_system::{FILE, FORMAT, System, layer_problem};

/// The person's file, beside the settings file.
pub(super) const PERSON_FILE: &str = "design.json";

/// One layer's source: where it is read from and its text (or why it could not be read).
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Source {
    /// `theme`, `person` or `folder`.
    pub kind: &'static str,
    /// How a message names it: the file's path, or `theme NAME`.
    pub label: String,
    /// The document; `None` when there is no such layer.
    pub doc: Option<Result<Value, String>>,
}

impl Source {
    /// The layer at `path`: absent when the file is missing.
    pub(super) fn file(kind: &'static str, path: &Path) -> Self {
        let doc = match std::fs::read_to_string(path) {
            Ok(text) => Some(serde_json::from_str::<Value>(&text).map_err(|e| e.to_string())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => Some(Err(e.to_string())),
        };
        Self { kind, label: path.display().to_string(), doc }
    }

    /// The extension folder's `cmux-design.json`. Messages name it `cmux-design.json`, as
    /// ext dev always has.
    pub(super) fn folder(dir: &Path) -> Self {
        Self { label: FILE.to_string(), ..Self::file("folder", &dir.join(FILE)) }
    }

    /// The active theme file's `design` layer: absent when no theme file is active or it has
    /// none. The theme file is JSONC; its other keys are settings (`cmux_config::theme_file`).
    pub(super) fn theme(config_dir: &Path, settings_root: &Value) -> Self {
        let name = cmux_config::theme_file::name_in(settings_root).map(str::to_string);
        let label = format!("theme {}", name.as_deref().unwrap_or("(none)"));
        let doc = name.and_then(|name| {
            match cmux_config::theme_file::source(config_dir, &name, None)? {
                Ok(text) => match cmux_config::jsonc::parse(&text) {
                    Ok(theme) => theme.get("design").cloned().map(Ok),
                    // The theme file's own reader reports a file that does not parse.
                    Err(_) => None,
                },
                Err(problem) => Some(Err(problem)),
            }
        });
        Self { kind: "theme", label, doc }
    }
}

/// Where this person's layers live.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Places {
    /// The folder of the settings file (`~/.config/cmux`).
    pub config_dir: PathBuf,
    /// The settings file as written (`{}` when missing or unreadable).
    pub settings_root: Value,
}

impl Places {
    /// The settings file cmux reads (`CMUX_NEXT_CONFIG_FILE`, else `~/.config/cmux/cmux-next.json`).
    pub(super) fn current() -> Self {
        let settings = cmux_config::config_path();
        let config_dir = settings.parent().map(Path::to_path_buf).unwrap_or_default();
        let settings_root = std::fs::read_to_string(&settings)
            .ok()
            .and_then(|text| cmux_config::jsonc::parse(&text).ok())
            .filter(Value::is_object)
            .unwrap_or_else(|| json!({}));
        Self { config_dir, settings_root }
    }

    /// `~/.config/cmux/design.json`.
    pub(super) fn person_file(&self) -> PathBuf {
        self.config_dir.join(PERSON_FILE)
    }

    /// The layers above cmux's for an extension in `folder` (none: the person's system alone),
    /// or checked against `system` (`ext design --system FILE`) in the folder's place.
    pub(super) fn sources(&self, folder: Option<&Path>, system: Option<&Path>) -> Vec<Source> {
        let mut sources = vec![
            Source::theme(&self.config_dir, &self.settings_root),
            Source::file("person", &self.person_file()),
        ];
        if let Some(file) = system {
            sources.push(Source::file("folder", file));
        } else if let Some(dir) = folder {
            sources.push(Source::folder(dir));
        }
        sources
    }
}

/// One layer as the resolve read it.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Layer {
    pub kind: &'static str,
    pub label: String,
    /// Merged; false when it did not read (its problem is in `Resolved::problems`).
    pub applied: bool,
}

/// One cmux value that changed since a person's file was written: a type role, the spacing
/// scale or a limit.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Change {
    /// `type.numeral`, `space`, `limits.typeRoles`.
    pub key: String,
    /// cmux's value when the file was written, and now.
    pub was: Value,
    pub now: Value,
    /// A layer above cmux's sets it, so the person's value still holds; else the new value
    /// shows through.
    pub kept: bool,
    /// The file that recorded the base.
    pub file: String,
}

impl Change {
    fn to_json(&self) -> Value {
        json!({ "key": self.key, "was": self.was, "now": self.now, "kept": self.kept,
                "file": self.file, "text": self.text() })
    }

    /// `type.numeral: cmux changed it from 34 pt semibold to 36 pt semibold (yours holds)`.
    pub(super) fn text(&self) -> String {
        let number = |v: &Value| v.as_f64().map(|n| n.to_string()).unwrap_or_else(|| v.to_string());
        let show = |v: &Value| match v {
            Value::Object(style) => format!(
                "{} pt {}{}",
                style.get("size").map(number).unwrap_or_default(),
                style.get("weight").and_then(Value::as_str).unwrap_or("regular"),
                if style.get("monospaced") == Some(&Value::Bool(true)) {
                    " monospaced"
                } else {
                    ""
                }
            ),
            Value::Array(steps) => steps.iter().map(number).collect::<Vec<_>>().join(" "),
            Value::Null => "nothing".into(),
            other => number(other),
        };
        let then = if self.kept { "yours holds" } else { "you get the new one" };
        format!(
            "{}: cmux changed it from {} to {} ({then})",
            self.key,
            show(&self.was),
            show(&self.now)
        )
    }
}

/// The system for a set of layers, what each layer did, and what cmux changed under them.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Resolved {
    pub system: System,
    pub layers: Vec<Layer>,
    /// A `system` finding per layer that did not read.
    pub problems: Vec<Finding>,
    pub changed: Vec<Change>,
}

impl Resolved {
    /// The layers over cmux's, merged in order; a layer that does not read is skipped.
    pub(super) fn from_sources(sources: &[Source]) -> Self {
        let mut system = System::cmux();
        let mut layers = vec![Layer { kind: "cmux", label: "cmux".into(), applied: true }];
        let mut problems = Vec::new();
        let mut changed: Vec<Change> = Vec::new();
        let mut sets: Vec<Value> = Vec::new();
        for source in sources {
            let Some(doc) = &source.doc else { continue };
            let merged = doc
                .as_ref()
                .map_err(Clone::clone)
                .and_then(|doc| system.merge(doc).map(|next| (doc, next)));
            match merged {
                Ok((doc, next)) => {
                    system = next;
                    layers.push(Layer {
                        kind: source.kind,
                        label: source.label.clone(),
                        applied: true,
                    });
                    if let Some(base) = doc.get("base") {
                        changed.retain(|c| c.file != source.label);
                        changed.extend(changes(base, &source.label));
                    }
                    sets.push(doc.clone());
                }
                Err(problem) => {
                    let instead = if source.kind == "folder" && sets.is_empty() {
                        "checking against cmux's design system instead".to_string()
                    } else {
                        "the layers under it still apply".to_string()
                    };
                    problems.push(layer_problem(&source.label, &problem, &instead));
                    layers.push(Layer {
                        kind: source.kind,
                        label: source.label.clone(),
                        applied: false,
                    });
                }
            }
        }
        for change in &mut changed {
            change.kept = sets.iter().any(|doc| sets_key(doc, &change.key));
        }
        Self { system, layers, problems, changed }
    }

    /// The system an extension in `folder` is checked against, from this person's places.
    pub(super) fn for_folder(folder: &Path) -> Self {
        Self::from_sources(&Places::current().sources(Some(folder), None))
    }

    pub(super) fn to_json(&self) -> Value {
        json!({
            "system": self.system.to_json(),
            "layers": self.layers.iter().map(|l| json!({ "kind": l.kind, "file": l.label, "applied": l.applied })).collect::<Vec<_>>(),
            "changed": self.changed.iter().map(Change::to_json).collect::<Vec<_>>(),
            "design": self.problems.iter().map(Finding::to_json).collect::<Vec<_>>(),
            "base": base(),
        })
    }
}

impl Resolved {
    /// The line under the system's name: the layers it is built from, as a person names them.
    pub(super) fn note(&self) -> String {
        let names: Vec<String> = self
            .layers
            .iter()
            .filter(|l| l.applied && l.kind != "cmux")
            .map(|l| match l.kind {
                "person" => Path::new(&l.label)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| l.label.clone()),
                _ => l.label.clone(),
            })
            .collect();
        if names.is_empty() {
            "cmux's own design system; add design.json beside your settings to make it yours".into()
        } else {
            format!("Built on cmux, then {}", names.join(", then "))
        }
    }

    /// The Settings page's scene: the SDK's DesignSystemView of this system, its changed roles
    /// marked, drawn by the real app runtime in QuickJS as the daemon's app host draws a pane. The
    /// ops are one batch a SceneStore applies.
    #[cfg(unix)]
    pub(super) fn scene(&self) -> Result<Value, String> {
        use cmux_app_host::{AppInfo, AppVm, FromHost, InitParams, Limits};
        if DESIGN_VIEW.is_empty() {
            return Err(
                "this cmux was built without bun, so it has no design view (its build packs \
                        design_view/src/main.ts with bun)"
                    .into(),
            );
        }
        let mut vm = AppVm::new(Limits::default())?;
        vm.init(InitParams {
            app: AppInfo { id: "cmux/design-system".into(), version: "1.0.0".into() },
            settings: json!({}),
            api_version: cmux_app_manifest::capabilities::Capabilities::get().api_version.clone(),
            ops: Some(Vec::new()),
            known_ops: None,
            locale: None,
            strings: Value::Null,
            main: DESIGN_VIEW.into(),
            main_name: Some("design_view/dist/main.js".into()),
        })
        .map_err(|e| format!("the design view did not load: {e:?}"))?;
        let context = json!({
            "surface": "pane",
            "design": {
                "system": self.system.to_json(),
                "changed": self.changed.iter().map(Change::to_json).collect::<Vec<_>>(),
                "note": self.note(),
            },
        });
        let mount = "design-system";
        if let Some(refused) =
            vm.mount(mount, "renderDesign", &context).map_err(|e| format!("{e:?}"))?
        {
            return Err(format!("the design view did not draw: {refused}"));
        }
        let mut ops = Vec::new();
        for message in vm.take_outbox() {
            match message {
                FromHost::Scene { ops: batch, .. } => {
                    ops.extend(batch.as_array().cloned().unwrap_or_default())
                }
                FromHost::Fatal { .. } => {
                    return Err(format!("the design view stopped: {message:?}"));
                }
                _ => {}
            }
        }
        Ok(Value::Array(ops))
    }

    #[cfg(not(unix))]
    pub(super) fn scene(&self) -> Result<Value, String> {
        Err("the design view draws on macOS and Linux".into())
    }
}

/// The packed DesignSystemView pane (`design_view/src/main.ts`), packed by build.rs into
/// `$OUT_DIR` (build output, not committed); empty in a build that had no bun.
#[cfg(unix)]
pub(super) const DESIGN_VIEW: &str =
    include_str!(concat!(env!("OUT_DIR"), "/design_view/dist/main.js"));

/// The values of cmux's own system a person's file records as its `base`: every cmux type role,
/// the spacing scale and the limits.
pub(super) fn base() -> Value {
    let cmux = System::cmux().to_json();
    json!({ "type": cmux["type"], "space": cmux["space"], "limits": cmux["limits"] })
}

/// What changed between the base a file recorded and cmux's now. A role cmux no longer has is
/// a change to `null`; one it added is no change (nobody set it).
fn changes(recorded: &Value, file: &str) -> Vec<Change> {
    let now = base();
    let mut out = Vec::new();
    let change = |key: String, was: &Value, now: &Value| Change {
        key,
        was: was.clone(),
        now: now.clone(),
        kept: false,
        file: file.to_string(),
    };
    if let Some(types) = recorded.get("type").and_then(Value::as_object) {
        for (role, was) in types {
            let current = now["type"].get(role).cloned().unwrap_or(Value::Null);
            if !same_style(was, &current) {
                out.push(change(format!("type.{role}"), was, &current));
            }
        }
    }
    if let Some(was) = recorded.get("space").filter(|s| s.is_array())
        && !same_numbers(was, &now["space"])
    {
        out.push(change("space".into(), was, &now["space"]));
    }
    if let Some(limits) = recorded.get("limits").and_then(Value::as_object) {
        for (key, was) in limits {
            let current = now["limits"].get(key).cloned().unwrap_or(Value::Null);
            if was.as_f64() != current.as_f64() {
                out.push(change(format!("limits.{key}"), was, &current));
            }
        }
    }
    out
}

fn same_style(a: &Value, b: &Value) -> bool {
    let weight =
        |v: &Value| v.get("weight").and_then(Value::as_str).unwrap_or("regular").to_string();
    let mono = |v: &Value| v.get("monospaced").and_then(Value::as_bool).unwrap_or(false);
    a.get("size").and_then(Value::as_f64) == b.get("size").and_then(Value::as_f64)
        && weight(a) == weight(b)
        && mono(a) == mono(b)
}

fn same_numbers(a: &Value, b: &Value) -> bool {
    let nums = |v: &Value| -> Vec<Option<f64>> {
        v.as_array().map(|a| a.iter().map(Value::as_f64).collect()).unwrap_or_default()
    };
    nums(a) == nums(b)
}

/// Whether a layer's document sets the value a change names.
fn sets_key(doc: &Value, key: &str) -> bool {
    match key.split_once('.') {
        Some((group, name)) => doc.get(group).and_then(|g| g.get(name)).is_some(),
        None => doc.get(key).is_some(),
    }
}

/// `ext design --stamp`: record cmux's base in the person's file, so a later update's changes
/// are listed against it. A missing file is written with only its format, a name and the base.
pub(super) fn stamp(places: &Places, json_out: bool) -> i32 {
    let path = places.person_file();
    let mut doc = match Source::file("person", &path).doc {
        None => json!({ "design": FORMAT, "name": "My design" }),
        Some(Ok(doc)) if doc.is_object() => doc,
        Some(Ok(_)) => {
            eprintln!("cmux: {}: the file is not a JSON object", path.display());
            return super::exit::MANIFEST_INVALID;
        }
        Some(Err(problem)) => {
            eprintln!("cmux: {}: {problem}", path.display());
            return super::exit::MANIFEST_INVALID;
        }
    };
    doc["base"] = base();
    let written =
        serde_json::to_string_pretty(&doc).map_err(std::io::Error::other).and_then(|text| {
            path.parent().map(std::fs::create_dir_all).transpose()?;
            std::fs::write(&path, text + "\n")
        });
    if let Err(e) = written {
        eprintln!("cmux: {}: {e}", path.display());
        return super::exit::LOAD_FAILED;
    }
    if json_out {
        println!(
            "{}",
            json!({ "ok": true, "file": path.display().to_string(), "base": doc["base"] })
        );
    } else {
        println!(
            "{}: recorded cmux's design system as its base; `cmux ext design --show` lists what cmux changes after this",
            path.display()
        );
    }
    super::exit::OK
}

/// `ext design --show [DIR] [--scene]`: the system an extension in DIR (or none) gets, layer by
/// layer; `--scene` adds the Settings page's scene ops to the JSON.
pub(super) fn show(resolved: &Resolved, scene: bool, json_out: bool) -> i32 {
    if json_out || scene {
        let mut out = resolved.to_json();
        out["note"] = json!(resolved.note());
        if scene {
            match resolved.scene() {
                Ok(ops) => out["scene"] = ops,
                Err(problem) => {
                    eprintln!("cmux: {problem}");
                    return super::exit::LOAD_FAILED;
                }
            }
        }
        println!("{out}");
        return super::exit::OK;
    }
    let system = &resolved.system;
    println!("{} (built on cmux)", system.name);
    for layer in &resolved.layers {
        println!(
            "  layer {}: {}{}",
            layer.kind,
            layer.label,
            if layer.applied { "" } else { " (skipped)" }
        );
    }
    let roles: Vec<String> = system
        .roles
        .iter()
        .map(|r| {
            format!("{} {} {}{}", r.name, r.size, r.weight, if r.monospaced { " mono" } else { "" })
        })
        .collect();
    println!("  type: {}", roles.join(", "));
    println!("  {}", system.scale_text());
    if !system.colors.is_empty() {
        let colors: Vec<String> = system.colors.iter().map(|(n, r)| format!("{n} = {r}")).collect();
        println!("  colors: {}", colors.join(", "));
    }
    println!("  limits: {} type roles, {} accents a view", system.max_roles, system.max_accents);
    for change in &resolved.changed {
        println!("  {}", change.text());
    }
    for text in super::design::lines(&resolved.problems) {
        println!("  {}", text.replace('\n', "\n  "));
    }
    super::exit::OK
}

#[cfg(test)]
#[path = "design_layers_tests.rs"]
mod tests;
