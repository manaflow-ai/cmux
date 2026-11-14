//! Theme files (`appearance.themeFile`, `<config dir>/themes/<name>.json`):
//! a partial overlay of the look settings, applied over cmux-next.json and
//! under managed values. Port of Swift `ThemeFileOverlay` and
//! `ThemeFileSetting` (CmuxNextSettings), so the daemon, the CLI and the
//! phone read a theme file as the Mac app does.
//!
//! The file is JSONC in cmux-next.json's own shape, nested
//! (`{"appearance": {"accent": "blue"}}`) or dotted at the top
//! (`{"appearance.accent": "blue"}`). Each value passes the schema check
//! `cmux settings set` uses; a refused one is dropped with a diagnostic
//! naming the file, the line and the key, and the others still apply. A file
//! that does not parse keeps its last good text ([`ThemeFile::or_last_good`]),
//! so a half-saved file never breaks the window.
//!
//! Besides settings, a file may carry its own terminal colors (`"colors"`
//! or a `"ghostty"` block), which become `appearance.themeEdits` of the
//! terminal theme it names ([`colors`]). [`render`] writes the current look
//! as a theme file: applying it changes nothing.

mod colors;
pub mod render;

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

use crate::domains::Domains;
use crate::keypath::{dotted, key_path};
use crate::refusal::Refusal;
use crate::render::compact;
use crate::schema::{Accepted, DomainKind, Row, Schema, Validation, accepts};
use crate::value::with_value;

/// The folder beside cmux-next.json that holds the theme files.
pub const FOLDER_NAME: &str = "themes";
pub const FILE_EXTENSION: &str = "json";
/// A theme file larger than this is refused unread: a look is a few hundred bytes.
pub const MAXIMUM_BYTES: usize = 256 * 1024;
/// The setting that names the active theme file.
pub const SETTING_KEY: &str = "appearance.themeFile";
/// The theme file JSON Schema's name in the themes folder. The leading dot
/// keeps it out of the list of theme files.
pub const SCHEMA_FILE_NAME: &str = ".schema.json";

/// Keys a theme file reads that are not settings.
pub const RESERVED_KEYS: [&str; 5] = ["name", "description", "$schema", "colors", "ghostty"];
/// Look keys that are no part of a look: the theme file itself, the star
/// list and its rotation, per-machine and per-display maps, and the saved
/// custom densities.
const EXCLUDED_KEYS: [&str; 7] = [
    SETTING_KEY,
    "appearance.favoriteThemes",
    "appearance.rotateFavoriteThemes",
    "appearance.machineColors",
    "appearance.displayBackgrounds",
    "appearance.displayBackgroundRotations",
    "appearance.customDensities",
];
const LOOK_PREFIXES: [&str; 7] = [
    "appearance.",
    "ui.animation",
    "ui.calm",
    "ui.paneAnimations",
    "ui.reducedBackgrounds",
    "browser.omnibar.glass",
    "app.uiScale",
];
/// Look keys outside those prefixes: the terminal font and the sidebar's
/// shape and edges.
const LOOK_KEYS: [&str; 6] = [
    "terminal.fontFamily",
    "terminal.fontSize",
    "sidebar.style",
    "sidebar.border",
    "sidebar.borderWidth",
    "sidebar.sectionLook",
];

/// Whether a theme file may set `row`: a look setting an agent may set too.
pub fn is_look(row: &Row) -> bool {
    let id = row.key.as_str();
    row.agent_settable
        && !EXCLUDED_KEYS.contains(&id)
        && (LOOK_KEYS.contains(&id) || LOOK_PREFIXES.iter().any(|prefix| id.starts_with(prefix)))
}

/// Every look row, in schema order.
pub fn look_rows(schema: &Schema) -> impl Iterator<Item = &Row> {
    schema.rows_in(None).filter(|row| is_look(row))
}

/// Whether `name` can name a theme file: a plain file name with no `/`, no
/// leading dot, no surrounding spaces or control characters, and no `.json`
/// (the setting holds the bare name).
pub fn is_valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 200
        && name == crate::text::trim_whitespaces(name)
        && !name.starts_with('.')
        && !name.contains('/')
        && !name.contains(':')
        && !name.to_lowercase().ends_with(&format!(".{FILE_EXTENSION}"))
        && !name.chars().any(crate::text::is_control)
}

/// `<config dir>/themes`.
pub fn folder(config_dir: &Path) -> PathBuf {
    config_dir.join(FOLDER_NAME)
}

/// `<config dir>/themes/<name>.json`.
pub fn path(config_dir: &Path, name: &str) -> PathBuf {
    folder(config_dir).join(format!("{name}.{FILE_EXTENSION}"))
}

/// The file `name` reads from: the user's, else the shipped one in `bundled`.
pub fn readable_path(config_dir: &Path, name: &str, bundled: Option<&Path>) -> Option<PathBuf> {
    let own = path(config_dir, name);
    if own.is_file() {
        return Some(own);
    }
    bundled.map(|dir| dir.join(format!("{name}.{FILE_EXTENSION}"))).filter(|p| p.is_file())
}

/// The theme files cmux ships (`Resources/theme-files`, the app's
/// `Contents/Resources/theme-files`), so the daemon and the CLI read them
/// with no app bundle. A user's file of the same name wins.
const SHIPPED: [(&str, &str); 5] = [
    ("charcoal", include_str!("../../../../../Resources/theme-files/charcoal.json")),
    ("classic-desktop", include_str!("../../../../../Resources/theme-files/classic-desktop.json")),
    ("claude-desktop", include_str!("../../../../../Resources/theme-files/claude-desktop.json")),
    ("harbor", include_str!("../../../../../Resources/theme-files/harbor.json")),
    ("phosphor", include_str!("../../../../../Resources/theme-files/phosphor.json")),
];

/// The text of the shipped theme file `name`.
pub fn shipped(name: &str) -> Option<&'static str> {
    SHIPPED.iter().find(|(shipped, _)| *shipped == name).map(|(_, text)| *text)
}

/// The theme file `root` names; `None` when unset or not a valid name.
pub fn name_in(root: &Value) -> Option<&str> {
    crate::value::value_at(root, &key_path(SETTING_KEY))
        .and_then(Value::as_str)
        .filter(|name| is_valid_name(name))
}

/// The names of the theme files in the folder and the shipped ones, each once, sorted.
pub fn names(config_dir: &Path, bundled: Option<&Path>) -> Vec<String> {
    let mut names: BTreeSet<String> = SHIPPED.iter().map(|(name, _)| (*name).to_string()).collect();
    for dir in std::iter::once(folder(config_dir)).chain(bundled.map(Path::to_path_buf)) {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|ext| ext.eq_ignore_ascii_case(FILE_EXTENSION))
                && let Some(stem) = path.file_stem().and_then(|stem| stem.to_str())
                && is_valid_name(stem)
            {
                names.insert(stem.to_string());
            }
        }
    }
    let mut names: Vec<String> = names.into_iter().collect();
    names.sort_by_key(|name| name.to_lowercase());
    names
}

/// Reads `name`'s text (the user's, else the shipped one): `None` when there
/// is no file, `Err` when it cannot be read or is too large.
pub fn source(
    config_dir: &Path,
    name: &str,
    bundled: Option<&Path>,
) -> Option<Result<String, String>> {
    match readable_path(config_dir, name, bundled) {
        Some(path) => Some(read_text(&path)),
        None => shipped(name).map(|text| Ok(text.to_string())),
    }
}

pub(crate) fn read_text(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    if bytes.len() > MAXIMUM_BYTES {
        return Err(format!("larger than {} KB", MAXIMUM_BYTES / 1024));
    }
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// What a theme file diagnostic is about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ThemeDiagnosticKind {
    /// The file is not a JSON object (a save mid-edit); its last good text applies.
    UnreadableFile,
    /// A refused value or key, or a missing file; the rest still applies.
    InvalidValue,
    /// A color the contrast guard raised.
    CorrectedValue,
}

/// One problem in a theme file, as `themes/NAME.json:LINE: key: message`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct ThemeDiagnostic {
    pub kind: ThemeDiagnosticKind,
    /// The dotted key (`colors.background` for a color); `appearance.themeFile`
    /// for the file itself (missing, a bad name).
    pub path: String,
    pub message: String,
    /// `themes/NAME.json`; `None` when the file itself is missing.
    pub file: Option<String>,
    /// The 1-based line of the entry, when it was found in the text.
    pub line: Option<usize>,
    /// The refused value, compact.
    pub value: Option<String>,
}

impl ThemeDiagnostic {
    /// One line, as a compiler prints it: `themes/tokyo.json:3: appearance.accent: message`.
    pub fn display(&self) -> String {
        let place = match (&self.file, self.line) {
            (Some(file), Some(line)) => format!("{file}:{line}: "),
            (Some(file), None) => format!("{file}: "),
            (None, _) => String::new(),
        };
        let value = self.value.as_ref().map(|value| format!(" = {value}")).unwrap_or_default();
        if self.path.is_empty() {
            format!("{place}{}", self.message)
        } else {
            format!("{place}{}{value}: {}", self.path, self.message)
        }
    }
}

/// One theme file read as a look.
#[derive(Debug, Clone, PartialEq)]
pub struct ThemeFile {
    pub name: String,
    /// The file was found and read.
    pub is_loaded: bool,
    /// The file is there but is no JSON object: see [`ThemeFile::or_last_good`].
    pub is_unparsable: bool,
    /// Each value the file sets, by key path, in key order.
    pub values: Vec<(Vec<String>, Value)>,
    pub diagnostics: Vec<ThemeDiagnostic>,
    /// The color tokens the contrast guard raised (`foreground`).
    pub corrected: Vec<String>,
}

impl ThemeFile {
    /// The file `name` read from `source` (`None`: no file), over `base` (the
    /// settings it applies over: the terminal theme its colors edit and the
    /// edits it keeps). A relative picture resolves against `folder`.
    pub fn read(
        name: &str,
        source: Option<Result<&str, String>>,
        base: &Value,
        folder: Option<&Path>,
        schema: &Schema,
        domains: &Domains,
    ) -> ThemeFile {
        let mut reader = Reader {
            file: format!("{FOLDER_NAME}/{name}.{FILE_EXTENSION}"),
            folder,
            schema,
            domains,
            text: "",
            values: Vec::new(),
            diagnostics: Vec::new(),
            corrected: Vec::new(),
            is_unparsable: false,
        };
        let is_loaded = reader.read(source, base);
        let mut values = reader.values;
        values.sort_by(|a, b| a.0.cmp(&b.0));
        ThemeFile {
            name: name.to_string(),
            is_loaded,
            is_unparsable: reader.is_unparsable,
            values,
            diagnostics: reader.diagnostics,
            corrected: reader.corrected,
        }
    }

    /// This read, or when the file does not parse, `last_good`'s text read
    /// again with this read's problems kept: a half-saved file never changes
    /// the look.
    pub fn or_last_good(
        self,
        last_good: Option<&str>,
        base: &Value,
        folder: Option<&Path>,
        schema: &Schema,
        domains: &Domains,
    ) -> ThemeFile {
        match last_good {
            Some(text) if self.is_unparsable => {
                let mut good =
                    ThemeFile::read(&self.name, Some(Ok(text)), base, folder, schema, domains);
                good.diagnostics.extend(self.diagnostics);
                good
            }
            _ => self,
        }
    }

    /// `root` with every value set, except keys a managed layer sets (dotted).
    pub fn applied(&self, root: &Value, managed: &BTreeSet<String>) -> Value {
        self.values.iter().fold(root.clone(), |root, (path, value)| {
            let id = dotted(path);
            let is_managed = managed.iter().any(|key| {
                *key == id
                    || id.starts_with(&format!("{key}."))
                    || key.starts_with(&format!("{id}."))
            });
            if is_managed { root } else { with_value(&root, value.clone(), path) }
        })
    }

    /// The dotted keys the file sets.
    pub fn keys(&self) -> Vec<String> {
        self.values.iter().map(|(path, _)| dotted(path)).collect()
    }
}

struct Reader<'a> {
    file: String,
    folder: Option<&'a Path>,
    schema: &'a Schema,
    domains: &'a Domains,
    text: &'a str,
    values: Vec<(Vec<String>, Value)>,
    diagnostics: Vec<ThemeDiagnostic>,
    corrected: Vec<String>,
    is_unparsable: bool,
}

impl<'a> Reader<'a> {
    fn read(&mut self, source: Option<Result<&'a str, String>>, base: &Value) -> bool {
        let text = match source {
            None => {
                self.refuse_file(&format!("there is no file {}", self.file));
                return false;
            }
            Some(Err(error)) => {
                self.unreadable(&error, None);
                return false;
            }
            Some(Ok(text)) => text,
        };
        self.text = text;
        let parsed = match crate::jsonc::parse(text) {
            Ok(parsed) => parsed,
            Err(error) => {
                let line = match error {
                    crate::jsonc::JsoncError::Malformed { offset } => Some(line_at(text, offset)),
                    _ => None,
                };
                self.unreadable(&error.to_string(), line);
                return false;
            }
        };
        let Value::Object(members) = parsed else {
            self.unreadable("root is not an object", Some(1));
            return false;
        };
        let mut entries: Vec<(&String, &Value)> = members.iter().collect();
        entries.sort_by_key(|(key, _)| *key);
        for (key, value) in entries {
            if RESERVED_KEYS.contains(&key.as_str()) {
                continue;
            }
            self.walk(value, key_path(key));
        }
        colors::read(self, &members, base);
        true
    }

    fn walk(&mut self, value: &Value, path: Vec<String>) {
        if path.is_empty() {
            return;
        }
        if let Some(row) = self.schema.row_at(&path) {
            self.take(row, value);
        } else if let Value::Object(members) = value {
            let mut keys: Vec<&String> = members.keys().collect();
            keys.sort();
            for key in keys {
                let mut child = path.clone();
                child.push(key.clone());
                self.walk(&members[key], child);
            }
        } else {
            self.refuse(&dotted(&path), Some(value), "not a cmux setting");
        }
    }

    fn take(&mut self, row: &Row, written: &Value) {
        if !is_look(row) {
            return self.refuse(&row.key, Some(written), "a theme file sets only look settings");
        }
        let value = if row.validation == Validation::Domain(DomainKind::BackdropSelection) {
            self.picture(written)
        } else {
            written.clone()
        };
        if let Err(refusal) = accepts(row, &value, self.domains) {
            return self.refuse(&row.key, Some(&value), &expectation(&refusal));
        }
        // A key written twice (nested and dotted) keeps the later one in key order.
        self.values.retain(|(path, _)| *path != row.path);
        self.values.push((row.path.clone(), value));
    }

    /// A `file:` or `folder:` background relative to the themes folder, or at
    /// `~`, as an absolute path; any other value as written.
    fn picture(&self, value: &Value) -> Value {
        let Some(raw) = value.as_str() else { return value.clone() };
        let Some((prefix, rest)) = ["file:", "folder:"]
            .into_iter()
            .find_map(|prefix| raw.strip_prefix(prefix).map(|rest| (prefix, rest)))
        else {
            return value.clone();
        };
        if rest.is_empty() || rest.starts_with('/') {
            return value.clone();
        }
        if let Some(after) = rest.strip_prefix('~')
            && (after.is_empty() || after.starts_with('/'))
        {
            let home = std::env::var("HOME").unwrap_or_default();
            return Value::String(format!("{prefix}{}", standardized(&format!("{home}{after}"))));
        }
        let Some(folder) = self.folder else { return value.clone() };
        Value::String(format!("{prefix}{}", standardized(&folder.join(rest).to_string_lossy())))
    }

    fn unreadable(&mut self, problem: &str, line: Option<usize>) {
        self.is_unparsable = true;
        self.diagnostics.push(ThemeDiagnostic {
            kind: ThemeDiagnosticKind::UnreadableFile,
            path: String::new(),
            message: format!("could not be read ({problem}); the last good version still applies"),
            file: Some(self.file.clone()),
            line,
            value: None,
        });
    }

    /// The file itself (missing, unreadable) is reported at `appearance.themeFile`.
    fn refuse_file(&mut self, message: &str) {
        self.diagnostics.push(ThemeDiagnostic {
            kind: ThemeDiagnosticKind::InvalidValue,
            path: SETTING_KEY.to_string(),
            message: message.to_string(),
            file: None,
            line: None,
            value: None,
        });
    }

    fn refuse(&mut self, path: &str, value: Option<&Value>, message: &str) {
        let line = line_of_key(self.text, path);
        self.diagnostics.push(ThemeDiagnostic {
            kind: ThemeDiagnosticKind::InvalidValue,
            path: path.to_string(),
            message: message.to_string(),
            file: Some(self.file.clone()),
            line,
            value: value.map(compact),
        });
    }

    fn correct(&mut self, message: String, value: &str, token: &str) {
        self.diagnostics.push(ThemeDiagnostic {
            kind: ThemeDiagnosticKind::CorrectedValue,
            path: SETTING_KEY.to_string(),
            message,
            file: Some(self.file.clone()),
            line: line_of_key(self.text, &format!("colors.{token}")),
            value: Some(compact(&Value::String(value.to_string()))),
        });
        if !self.corrected.iter().any(|t| t == token) {
            self.corrected.push(token.to_string());
        }
    }
}

/// What a refused value should have been, as Swift's `expectation` words it.
fn expectation(refusal: &Refusal) -> String {
    let Refusal::InvalidValue { accepted, .. } = refusal else { return refusal.to_string() };
    match accepted {
        Accepted::Choices(choices) => format!("expected one of {}", choices.join(", ")),
        Accepted::Range { min, max } => format!("expected a number from {min} to {max}"),
        Accepted::ChoicesOrRange { choices, min, max } => {
            format!("expected one of {} or a number from {min} to {max}", choices.join(", "))
        }
        Accepted::ChoicesOrShape { choices, shape } => {
            format!("expected one of {} or {shape}", choices.join(", "))
        }
        Accepted::Shape(shape) => format!("expected {shape}"),
        Accepted::Domain { name, values: Some(values) } if values.len() <= 12 => {
            format!("expected a {name}: {}", values.join(", "))
        }
        Accepted::Domain { name, .. } => format!("expected an installed {name}"),
    }
}

/// `path` with `.` and `..` components folded (Foundation's `standardizedFileURL`).
fn standardized(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            part => parts.push(part),
        }
    }
    format!("/{}", parts.join("/"))
}

/// The 1-based line of byte `offset`.
fn line_at(text: &str, offset: usize) -> usize {
    text.bytes().take(offset).filter(|&b| b == b'\n').count() + 1
}

/// The line where `dotted` (or its last component, for a nested key) is
/// written as a key, when it is.
fn line_of_key(text: &str, dotted: &str) -> Option<usize> {
    let mut candidates = vec![dotted.to_string()];
    if let Some((_, last)) = dotted.rsplit_once('.') {
        candidates.push(last.to_string());
    }
    candidates.iter().find_map(|key| {
        let needle = format!("\"{key}\"");
        text.match_indices(&needle).find_map(|(at, matched)| {
            let after = text.get(at + matched.len()..).unwrap_or_default().trim_start();
            after.starts_with(':').then(|| line_at(text, at))
        })
    })
}

#[cfg(test)]
mod tests;
