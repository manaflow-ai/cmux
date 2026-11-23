//! Reading a pack folder: `cmux-pack.json` and the files under `assets/`.
//!
//! A pack is refused whole only when there is nothing to read (no manifest,
//! unreadable, too large, not a JSON object, not a `cmuxPack`); the look in
//! use then stays. Anything else falls back per key or per slot: a value the
//! pack has no capability for, a value the schema refuses, an asset outside
//! the pack, an unknown slot or variant, an unknown section. Each section is
//! read under `catch_unwind`, so a pack that trips a bug in the reader loses
//! that section, never the app.

use std::collections::BTreeSet;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

use cmux_config::domains::Domains;
use cmux_config::keypath::{dotted, key_path};
use cmux_config::render::compact;
use cmux_config::schema::Schema;
use cmux_config::theme_file::{self, ThemeDiagnosticKind, ThemeFile};
use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::capability::Capability;

/// The manifest's file name in a pack folder.
pub const MANIFEST: &str = "cmux-pack.json";
/// The format this cmux reads.
pub const FORMAT: u64 = 1;
/// A manifest larger than this is refused unread.
pub const MAXIMUM_MANIFEST_BYTES: u64 = 512 * 1024;
/// An asset larger than this is dropped (a video wallpaper fits).
pub const MAXIMUM_ASSET_BYTES: u64 = 256 * 1024 * 1024;
/// At most this many values are read from `look`; the rest are dropped.
pub const MAXIMUM_VALUES: usize = 4096;
/// The folder in a pack that `file:` and `folder:` values may point into.
pub const ASSETS: &str = "assets";
/// A value nested deeper than this is dropped rather than walked for paths.
const MAXIMUM_ASSET_DEPTH: usize = 32;
/// Asset kinds a background may name.
const ASSET_EXTENSIONS: [&str; 10] =
    ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "mp4", "mov", "m4v"];
/// Top-level manifest keys.
const KNOWN_KEYS: [&str; 10] = [
    "$schema",
    "cmuxPack",
    "id",
    "name",
    "version",
    "description",
    "capabilities",
    "look",
    "colors",
    "slots",
];

/// Why a pack could not be read at all. The look in use stays.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    NoManifest(PathBuf),
    Unreadable { path: PathBuf, problem: String },
    NotAPack { path: PathBuf, problem: String },
}

impl std::fmt::Display for LoadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoadError::NoManifest(dir) => write!(f, "{}: no {MANIFEST}", dir.display()),
            LoadError::Unreadable { path, problem } | LoadError::NotAPack { path, problem } => {
                write!(f, "{}: {problem}", path.display())
            }
        }
    }
}

impl std::error::Error for LoadError {}

/// One value, slot or section the pack lost, and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PackDiagnostic {
    /// `look`, `colors`, `slots`, `assets`, `capabilities` or the manifest itself (`""`).
    pub section: String,
    /// The dotted key, slot id or asset path, when it is about one.
    pub key: Option<String>,
    pub message: String,
    pub value: Option<String>,
}

impl PackDiagnostic {
    fn new(
        section: &str,
        key: Option<&str>,
        message: impl Into<String>,
        value: Option<&Value>,
    ) -> Self {
        PackDiagnostic {
            section: section.to_string(),
            key: key.map(str::to_string),
            message: message.into(),
            value: value.map(compact),
        }
    }

    /// One line: `look: appearance.accent = "pink": expected one of ...`.
    /// Every part may be the pack's own text (an unknown key, its value), and
    /// the line goes to a terminal, so control characters come out escaped
    /// (`\u{1b}`), never raw: a pack cannot drive the reader's terminal.
    pub fn display(&self) -> String {
        let value = self.value.as_ref().map(|value| format!(" = {value}")).unwrap_or_default();
        let line = match (&self.key, self.section.is_empty()) {
            (Some(key), false) => format!("{}: {key}{value}: {}", self.section, self.message),
            (Some(key), true) => format!("{key}{value}: {}", self.message),
            (None, false) => format!("{}: {}", self.section, self.message),
            (None, true) => self.message.clone(),
        };
        terminal_safe(&line)
    }
}

/// `text` with each control character (C0, DEL, C1) written as its Rust
/// escape; everything else unchanged.
fn terminal_safe(text: &str) -> String {
    if !text.chars().any(char::is_control) {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + 8);
    for c in text.chars() {
        if c.is_control() {
            out.extend(c.escape_default());
        } else {
            out.push(c);
        }
    }
    out
}

/// A pack, read and checked: what it applies and what it lost.
#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    /// `owner/name`.
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub description: Option<String>,
    pub dir: PathBuf,
    pub capabilities: BTreeSet<Capability>,
    /// The theme file the pack compiles to (`theme_file`'s format): every
    /// value that passed, plus `colors` and `slots`.
    pub theme: Map<String, Value>,
    pub diagnostics: Vec<PackDiagnostic>,
}

impl Pack {
    /// The theme file name the pack applies as (`appearance.themeFile`).
    pub fn theme_name(&self) -> String {
        theme_name(&self.id)
    }

    /// The compiled theme file's text.
    pub fn theme_text(&self) -> String {
        let mut text = serde_json::to_string_pretty(&Value::Object(self.theme.clone()))
            .unwrap_or_else(|_| "{}".to_string());
        text.push('\n');
        text
    }

    /// The dotted settings keys the pack sets (no `colors` or `slots`).
    pub fn keys(&self) -> Vec<String> {
        self.theme
            .keys()
            .filter(|key| !theme_file::RESERVED_KEYS.contains(&key.as_str()) && *key != "slots")
            .cloned()
            .collect()
    }
}

/// `pack-OWNER-NAME`: a valid theme file name for pack `id`.
pub fn theme_name(id: &str) -> String {
    let slug: String = id
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    format!("pack-{slug}")
}

/// What a pack is read with.
pub struct Context<'a> {
    pub schema: &'a Schema,
    pub domains: &'a Domains,
    /// The settings the pack applies over (the terminal theme its `colors` edit).
    pub base: &'a Value,
}

/// Reads the pack in `dir`. `edits` are dotted look values over the pack's
/// own (live edit); they pass the same checks.
pub fn load(
    dir: &Path,
    edits: &Map<String, Value>,
    context: &Context<'_>,
) -> Result<Pack, LoadError> {
    let path = dir.join(MANIFEST);
    let text = read_manifest(&path)?;
    let parsed = cmux_config::jsonc::parse(&text)
        .map_err(|error| LoadError::NotAPack { path: path.clone(), problem: error.to_string() })?;
    let Value::Object(manifest) = parsed else {
        return Err(LoadError::NotAPack {
            path,
            problem: "the manifest is not a JSON object".into(),
        });
    };
    read(dir, &manifest, edits, context).ok_or(LoadError::NotAPack {
        path,
        problem: format!("not a cmux pack: it needs \"cmuxPack\": {FORMAT}"),
    })
}

fn read_manifest(path: &Path) -> Result<String, LoadError> {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(LoadError::NoManifest(
                path.parent().map(Path::to_path_buf).unwrap_or_default(),
            ));
        }
        Err(error) => {
            return Err(LoadError::Unreadable {
                path: path.to_path_buf(),
                problem: error.to_string(),
            });
        }
    };
    if !metadata.is_file() {
        return Err(LoadError::Unreadable {
            path: path.to_path_buf(),
            problem: "not a file".into(),
        });
    }
    if metadata.len() > MAXIMUM_MANIFEST_BYTES {
        return Err(LoadError::Unreadable {
            path: path.to_path_buf(),
            problem: format!("larger than {} KB", MAXIMUM_MANIFEST_BYTES / 1024),
        });
    }
    let bytes = std::fs::read(path).map_err(|error| LoadError::Unreadable {
        path: path.to_path_buf(),
        problem: error.to_string(),
    })?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// The pack in `manifest`; `None` when it is no `cmuxPack`.
fn read(
    dir: &Path,
    manifest: &Map<String, Value>,
    edits: &Map<String, Value>,
    context: &Context<'_>,
) -> Option<Pack> {
    let format = manifest.get("cmuxPack").and_then(Value::as_u64)?;
    let mut diagnostics = Vec::new();
    if format > FORMAT {
        diagnostics.push(PackDiagnostic::new(
            "",
            Some("cmuxPack"),
            format!("made for pack format {format}; this cmux reads {FORMAT}, so it applies what it knows"),
            None,
        ));
    }
    let id = pack_id(dir, manifest, &mut diagnostics);
    let name = text_field(manifest, "name", 200, &mut diagnostics).unwrap_or_else(|| id.clone());
    let version = text_field(manifest, "version", 64, &mut diagnostics);
    let description = text_field(manifest, "description", 2000, &mut diagnostics);
    for key in manifest.keys().filter(|key| !KNOWN_KEYS.contains(&key.as_str())) {
        diagnostics.push(PackDiagnostic::new("", Some(key), "not a pack section; skipped", None));
    }
    let capabilities = capabilities(manifest.get("capabilities"), &mut diagnostics);

    let mut theme = Map::new();
    theme.insert("name".into(), Value::String(name.clone()));
    if let Some(description) = &description {
        theme.insert("description".into(), Value::String(description.clone()));
    }
    let mut reader = Reader { dir, capabilities: &capabilities, context, theme, diagnostics };
    reader.guarded("look", |reader| reader.look(manifest.get("look"), edits));
    reader.guarded("colors", |reader| reader.colors(manifest.get("colors")));
    reader.guarded("slots", |reader| reader.slots(manifest.get("slots")));
    reader.guarded("look", Reader::check);
    let Reader { theme, diagnostics, .. } = reader;
    Some(Pack {
        id,
        name,
        version,
        description,
        dir: dir.to_path_buf(),
        capabilities,
        theme,
        diagnostics,
    })
}

fn pack_id(
    dir: &Path,
    manifest: &Map<String, Value>,
    diagnostics: &mut Vec<PackDiagnostic>,
) -> String {
    let written = manifest.get("id");
    if let Some(id) = written.and_then(Value::as_str).filter(|id| is_valid_id(id)) {
        return id.to_string();
    }
    let stem = dir.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let fallback = format!(
        "local/{}",
        stem.chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '-' {
                c.to_ascii_lowercase()
            } else {
                '-'
            })
            .take(64)
            .collect::<String>()
    );
    diagnostics.push(PackDiagnostic::new(
        "",
        Some("id"),
        format!("expected \"owner/name\" (lowercase letters, digits, - . _); using {fallback}"),
        written,
    ));
    fallback
}

/// `owner/name`, each part 1 to 64 of `a-z 0-9 - . _`, not starting with `.`.
pub fn is_valid_id(id: &str) -> bool {
    let part = |part: &str| {
        (1..=64).contains(&part.len())
            && !part.starts_with('.')
            && part
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "-._".contains(c))
    };
    matches!(id.split_once('/'), Some((owner, name)) if part(owner) && part(name))
}

fn text_field(
    manifest: &Map<String, Value>,
    key: &str,
    maximum: usize,
    diagnostics: &mut Vec<PackDiagnostic>,
) -> Option<String> {
    let value = manifest.get(key)?;
    match value.as_str() {
        Some(text) if text.chars().count() <= maximum && !text.chars().any(char::is_control) => {
            Some(text.to_string())
        }
        _ => {
            diagnostics.push(PackDiagnostic::new(
                "",
                Some(key),
                format!("expected text of at most {maximum} characters"),
                Some(value),
            ));
            None
        }
    }
}

fn capabilities(
    value: Option<&Value>,
    diagnostics: &mut Vec<PackDiagnostic>,
) -> BTreeSet<Capability> {
    let mut declared = BTreeSet::new();
    match value {
        None => diagnostics.push(PackDiagnostic::new(
            "capabilities",
            None,
            "the pack declares none, so it can change nothing",
            None,
        )),
        Some(Value::Array(items)) => {
            for item in items {
                match item.as_str().and_then(Capability::parse) {
                    Some(capability) => {
                        declared.insert(capability);
                    }
                    None => diagnostics.push(PackDiagnostic::new(
                        "capabilities",
                        None,
                        format!(
                            "not a capability; expected one of {}",
                            Capability::ALL.map(Capability::name).join(", ")
                        ),
                        Some(item),
                    )),
                }
            }
        }
        Some(other) => diagnostics.push(PackDiagnostic::new(
            "capabilities",
            None,
            "expected a list of capability names",
            Some(other),
        )),
    }
    declared
}

struct Reader<'a> {
    dir: &'a Path,
    capabilities: &'a BTreeSet<Capability>,
    context: &'a Context<'a>,
    theme: Map<String, Value>,
    diagnostics: Vec<PackDiagnostic>,
}

impl Reader<'_> {
    /// Runs `section` so a panic in it costs only that section's values.
    fn guarded(&mut self, name: &str, section: impl FnOnce(&mut Self)) {
        let before = self.theme.clone();
        let outcome = catch_unwind(AssertUnwindSafe(|| section(self)));
        if outcome.is_err() {
            self.theme = before;
            self.diagnostics.push(PackDiagnostic::new(
                name,
                None,
                "reading this section failed; it is skipped and the rest applies",
                None,
            ));
        }
    }

    fn allows(&mut self, section: &str, key: &str, capability: Capability, value: &Value) -> bool {
        if self.capabilities.contains(&capability) {
            return true;
        }
        self.diagnostics.push(PackDiagnostic::new(
            section,
            Some(key),
            format!("needs the {} capability, which the pack does not declare", capability.name()),
            Some(value),
        ));
        false
    }

    fn look(&mut self, look: Option<&Value>, edits: &Map<String, Value>) {
        let mut values: Vec<(String, Value)> = Vec::new();
        match look {
            None => {}
            Some(Value::Object(members)) => {
                let mut keys: Vec<&String> = members.keys().collect();
                keys.sort();
                for key in keys {
                    self.flatten(&members[key], key_path(key), &mut values);
                }
            }
            Some(other) => self.diagnostics.push(PackDiagnostic::new(
                "look",
                None,
                "expected an object of settings",
                Some(other),
            )),
        }
        // Edits go through the same flattening as the manifest, so a nested
        // edit (`sidebar` = `{"sectionLook": ..}`) replaces, is checked and is
        // reported under the dotted keys it sets.
        for (key, value) in edits {
            let mut flat = Vec::new();
            self.flatten(value, key_path(key), &mut flat);
            for (key, value) in flat {
                values.retain(|(written, _)| *written != key);
                values.push((key, value));
            }
        }
        if values.len() > MAXIMUM_VALUES {
            self.diagnostics.push(PackDiagnostic::new(
                "look",
                None,
                format!("more than {MAXIMUM_VALUES} values; the rest are dropped"),
                None,
            ));
            values.truncate(MAXIMUM_VALUES);
        }
        for (key, value) in values {
            if !self.allows("look", &key, Capability::of_key(&key), &value) {
                continue;
            }
            let Some(value) = self.asset(&key, value) else { continue };
            self.theme.insert(key, value);
        }
    }

    /// A nested `look` written as dotted keys: a schema row is a leaf, an
    /// object that is no row goes one level down, anything else is kept for
    /// the schema check to name.
    fn flatten(&self, value: &Value, path: Vec<String>, out: &mut Vec<(String, Value)>) {
        flatten(self.context.schema, value, path, out);
    }

    /// `value` with every `file:` and `folder:` string in it (at any depth:
    /// a schedule maps times to pictures) made an absolute path inside the
    /// pack's `assets/`. `None` (dropped) when any string in it points
    /// anywhere else: a `file:`/`folder:` outside `assets/`, a `system:`
    /// picture, or an absolute path the pack did not resolve from its own
    /// files. A pack shows only pictures it ships.
    fn asset(&mut self, key: &str, value: Value) -> Option<Value> {
        let mut resolved = value.clone();
        match self.assets_in(&mut resolved, 0) {
            Ok(()) => Some(resolved),
            Err(problem) => {
                self.diagnostics.push(PackDiagnostic::new(
                    "assets",
                    Some(key),
                    problem,
                    Some(&value),
                ));
                None
            }
        }
    }

    /// Resolves (in place) or refuses every string in `value`.
    fn assets_in(&self, value: &mut Value, depth: usize) -> Result<(), String> {
        if depth > MAXIMUM_ASSET_DEPTH {
            return Err("nested too deep".into());
        }
        match value {
            Value::String(raw) => {
                if let Some(resolved) = self.asset_string(raw)? {
                    *raw = resolved;
                }
                Ok(())
            }
            Value::Array(items) => {
                items.iter_mut().try_for_each(|item| self.assets_in(item, depth + 1))
            }
            Value::Object(members) => {
                members.values_mut().try_for_each(|member| self.assets_in(member, depth + 1))
            }
            _ => Ok(()),
        }
    }

    /// `Some(resolved)` for a `file:`/`folder:` string inside the pack's
    /// assets, `None` for a string that names no file, an error for any
    /// other path.
    fn asset_string(&self, raw: &str) -> Result<Option<String>, String> {
        if let Some((prefix, rest)) = ["file:", "folder:"]
            .into_iter()
            .find_map(|prefix| raw.strip_prefix(prefix).map(|rest| (prefix, rest)))
        {
            let path = self.resolve_asset(rest, prefix == "folder:")?;
            return Ok(Some(format!("{prefix}{}", path.display())));
        }
        if raw.starts_with("system:") {
            return Err(format!(
                "a pack shows only its own pictures (file:{ASSETS}/NAME), not system: ones"
            ));
        }
        if raw.starts_with('/')
            || raw.starts_with('~')
            || raw.starts_with('\\')
            || Path::new(raw).is_absolute()
        {
            return Err(format!("a pack names only its own files, as file:{ASSETS}/NAME"));
        }
        Ok(None)
    }

    fn resolve_asset(&self, relative: &str, is_folder: bool) -> Result<PathBuf, String> {
        let written = Path::new(relative);
        let inside = written.components().all(|part| matches!(part, Component::Normal(_)));
        if relative.is_empty() || !inside || !relative.starts_with(&format!("{ASSETS}/")) {
            return Err(format!("a pack names only its own files, as {ASSETS}/NAME"));
        }
        let pack =
            self.dir.canonicalize().map_err(|_| "the pack folder is unreadable".to_string())?;
        let root = self
            .dir
            .join(ASSETS)
            .canonicalize()
            .map_err(|_| format!("the pack has no {ASSETS} folder"))?;
        // `assets` may itself be a link: it must still lead into the pack.
        if root == pack || !root.starts_with(&pack) {
            return Err(format!("the pack's {ASSETS} folder points outside the pack"));
        }
        let path = self
            .dir
            .join(written)
            .canonicalize()
            .map_err(|_| "no such file in the pack".to_string())?;
        if !path.starts_with(&root) {
            return Err(format!("points outside the pack's {ASSETS} folder"));
        }
        let metadata = std::fs::metadata(&path).map_err(|error| error.to_string())?;
        if is_folder {
            return if metadata.is_dir() { Ok(path) } else { Err("not a folder".into()) };
        }
        let extension =
            path.extension().map(|ext| ext.to_string_lossy().to_lowercase()).unwrap_or_default();
        if !metadata.is_file() || !ASSET_EXTENSIONS.contains(&extension.as_str()) {
            return Err(format!(
                "expected a picture or video file ({})",
                ASSET_EXTENSIONS.join(", ")
            ));
        }
        if metadata.len() > MAXIMUM_ASSET_BYTES {
            return Err(format!("larger than {} MB", MAXIMUM_ASSET_BYTES / (1024 * 1024)));
        }
        Ok(path)
    }

    fn colors(&mut self, colors: Option<&Value>) {
        let Some(colors) = colors else { return };
        if !self.allows("colors", "colors", Capability::Colors, colors) {
            return;
        }
        match colors {
            Value::Object(members) => {
                let kept: Map<String, Value> =
                    members.iter().map(|(key, value)| (key.clone(), value.clone())).collect();
                self.theme.insert("colors".into(), Value::Object(kept));
            }
            other => self.diagnostics.push(PackDiagnostic::new(
                "colors",
                None,
                "expected an object of colors",
                Some(other),
            )),
        }
    }

    fn slots(&mut self, slots: Option<&Value>) {
        let Some(slots) = slots else { return };
        if !self.allows("slots", "slots", Capability::Components, slots) {
            return;
        }
        let Value::Object(members) = slots else {
            self.diagnostics.push(PackDiagnostic::new(
                "slots",
                None,
                "expected an object of slot id to variant id",
                Some(slots),
            ));
            return;
        };
        let known = known_slots();
        let mut kept = Map::new();
        for (slot, variant) in members {
            let Some(variants) =
                known.iter().find(|(id, _)| id == slot).map(|(_, variants)| variants)
            else {
                self.diagnostics.push(PackDiagnostic::new(
                    "slots",
                    Some(slot),
                    "not a theme slot (schemas/theme/slots.json); it keeps its default",
                    Some(variant),
                ));
                continue;
            };
            match variant.as_str() {
                Some(id) if variants.iter().any(|known| known == id) => {
                    kept.insert(slot.clone(), variant.clone());
                }
                _ => self.diagnostics.push(PackDiagnostic::new(
                    "slots",
                    Some(slot),
                    format!("expected one of {}; it keeps its default", variants.join(", ")),
                    Some(variant),
                )),
            }
        }
        if !kept.is_empty() {
            self.theme.insert("slots".into(), Value::Object(kept));
        }
    }

    /// Runs the theme file reader over the compiled file: the same per-key
    /// schema check `cmux settings set` and the app apply. A refused value is
    /// taken out of the compiled file so the app never sees it.
    fn check(&mut self) {
        let mut checked = self.theme.clone();
        checked.remove("slots");
        let text = Value::Object(checked).to_string();
        let file = ThemeFile::read(
            "pack",
            Some(Ok(text.as_str())),
            self.context.base,
            None,
            self.context.schema,
            self.context.domains,
        );
        let kept: BTreeSet<String> = file.keys().into_iter().collect();
        for diagnostic in &file.diagnostics {
            if diagnostic.kind != ThemeDiagnosticKind::InvalidValue {
                continue;
            }
            let (section, key) = match diagnostic.path.strip_prefix("colors.") {
                Some(color) => ("colors", color.to_string()),
                None if diagnostic.path == "colors" => ("colors", "colors".to_string()),
                None => ("look", diagnostic.path.clone()),
            };
            if section == "colors" {
                if key == "colors" {
                    // The whole map is refused (no terminal theme to edit, not an object).
                    self.theme.remove("colors");
                } else if let Some(Value::Object(colors)) = self.theme.get_mut("colors") {
                    colors.remove(&key);
                }
            }
            self.diagnostics.push(PackDiagnostic {
                section: section.into(),
                key: Some(key),
                message: diagnostic.message.clone(),
                value: diagnostic.value.clone(),
            });
        }
        let reserved = |key: &str| theme_file::RESERVED_KEYS.contains(&key) || key == "slots";
        self.theme.retain(|key, _| reserved(key) || kept.contains(key));
        if matches!(self.theme.get("colors"), Some(Value::Object(colors)) if colors.is_empty()) {
            self.theme.remove("colors");
        }
    }
}

/// A nested `look` value as dotted keys: a schema row is a leaf, an object
/// that is no row goes one level down, anything else is kept for the schema
/// check to name.
fn flatten(schema: &Schema, value: &Value, path: Vec<String>, out: &mut Vec<(String, Value)>) {
    if path.is_empty() || out.len() > MAXIMUM_VALUES {
        return;
    }
    if schema.row_at(&path).is_some() {
        out.push((dotted(&path), value.clone()));
    } else if let Value::Object(members) = value {
        let mut keys: Vec<&String> = members.keys().collect();
        keys.sort();
        for key in keys {
            let mut child = path.clone();
            child.push(key.clone());
            flatten(schema, &members[key], child, out);
        }
    } else {
        out.push((dotted(&path), value.clone()));
    }
}

/// The dotted look values an edit of `key` to `value` sets, flattened the
/// way the manifest's `look` is.
pub fn flatten_edit(schema: &Schema, key: &str, value: &Value) -> Vec<(String, Value)> {
    let mut out = Vec::new();
    flatten(schema, value, key_path(key), &mut out);
    out
}

/// Each slot in `schemas/theme/slots.json` with its variant ids.
fn known_slots() -> &'static [(String, Vec<String>)] {
    static SLOTS: OnceLock<Vec<(String, Vec<String>)>> = OnceLock::new();
    SLOTS.get_or_init(|| {
        let spec: Value =
            serde_json::from_str(include_str!("../../../../schemas/theme/slots.json"))
                .unwrap_or(json!({}));
        spec.get("slots")
            .and_then(Value::as_array)
            .map(|slots| {
                slots
                    .iter()
                    .filter_map(|slot| {
                        let id = slot.get("id")?.as_str()?.to_string();
                        let variants = slot
                            .get("variants")
                            .and_then(Value::as_array)
                            .map(|variants| {
                                variants
                                    .iter()
                                    .filter_map(|variant| {
                                        variant
                                            .as_str()
                                            .or_else(|| variant.get("id")?.as_str())
                                            .map(str::to_string)
                                    })
                                    .collect()
                            })
                            .unwrap_or_default();
                        Some((id, variants))
                    })
                    .collect()
            })
            .unwrap_or_default()
    })
}
