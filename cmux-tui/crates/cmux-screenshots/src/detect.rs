//! The folders the Screenshots pane lists, in menu order (Swift `ScreenshotSourceDetector`):
//! macOS's screenshot folder, macOS's floating-preview folder, every installed tool's save folder
//! and history ([`Tool`]), then the person's own folders.
//!
//! Pure over an [`Environment`] the app provides (preferences, a few small files, folder
//! existence, `realpath`). A folder shows only when it exists, and two sources never share a
//! folder: the first wins, so CleanShot X saving into the macOS folder shows once, as macOS's.

use crate::rule::ScanRule;
use crate::tools::Tool;
use std::collections::HashSet;

/// The macOS screenshot preferences domain.
pub const SYSTEM_DOMAIN: &str = "com.apple.screencapture";
/// The prefix of the folders macOS writes a screenshot into while its preview shows.
pub const PREVIEW_FOLDER_PREFIX: &str = "NSIRD_screencaptureui_";

/// What the detector reads from this Mac (Swift `ScreenshotEnvironment`).
pub trait Environment {
    /// The person's home folder, absolute.
    fn home(&self) -> String;
    /// This process's temporary folder (`$TMPDIR`), absolute.
    fn temporary_directory(&self) -> String;
    /// A string preference; None when unset or not a string.
    fn preference(&self, key: &str, domain: &str) -> Option<String>;
    /// Every string preference of `domain`, in any order.
    fn string_preferences(&self, domain: &str) -> Vec<(String, String)>;
    /// A small text file's contents; None when missing or unreadable.
    fn text(&self, path: &str) -> Option<String>;
    /// Whether a folder (not a file) is at `path`.
    fn is_directory(&self, path: &str) -> bool;
    /// `path` with every symlink resolved (`realpath`); None when it cannot be resolved.
    fn real_path(&self, path: &str) -> Option<String>;
}

/// Where a source comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Origin {
    /// macOS's screenshot folder.
    System,
    /// macOS's floating-preview folders.
    SystemPreview,
    /// A tool's save folder.
    Tool(Tool),
    /// A tool's history.
    ToolHistory(Tool),
    /// A folder the person added.
    Custom,
}

impl Origin {
    /// Whether files dropped on the pane may be saved here (not into previews or a history).
    pub const fn accepts_drops(self) -> bool {
        matches!(self, Self::System | Self::Custom | Self::Tool(_))
    }

    /// The C ABI name of the origin's case.
    pub const fn name(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::SystemPreview => "systemPreview",
            Self::Tool(_) => "tool",
            Self::ToolHistory(_) => "toolHistory",
            Self::Custom => "custom",
        }
    }

    /// The tool of a tool or history source.
    pub const fn tool(self) -> Option<Tool> {
        match self {
            Self::Tool(t) | Self::ToolHistory(t) => Some(t),
            _ => None,
        }
    }
}

/// A folder the pane lists.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Source {
    /// Stable id: `system`, `system.preview`, `tool.<raw>`, `tool.<raw>.history`, `custom.<path>`.
    pub id: String,
    /// The folder, symlinks resolved (FSEvents reports real paths).
    pub folder: String,
    /// Where it comes from; the app labels it from this.
    pub origin: Origin,
    /// What is listed there.
    pub rule: ScanRule,
}

impl Source {
    /// Whether files dropped on the pane may be saved here.
    pub const fn accepts_drops(&self) -> bool {
        self.origin.accepts_drops()
    }
}

/// Whether a preference key names a save folder (`exportPath`, `saveFolder`, `SaveLocation`...).
pub fn looks_like_folder_key(key: &str) -> bool {
    let lowered = key.to_lowercase();
    if lowered.starts_with("ns") || lowered.contains("recent") {
        return false;
    }
    ["path", "folder", "location", "directory", "savedir", "exportdir"]
        .iter()
        .any(|w| lowered.contains(w))
}

/// A path with `.`, `..` and repeated slashes removed and no trailing slash
/// (`URL.standardizedFileURL.path`).
pub fn standardize(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            _ => parts.push(part),
        }
    }
    format!("/{}", parts.join("/"))
}

/// `base` with `relative` appended (`appendingPathComponent`; not standardized).
pub fn join(base: &str, relative: &str) -> String {
    let relative = relative.trim_start_matches('/');
    if relative.is_empty() {
        return base.to_owned();
    }
    format!("{}/{relative}", base.trim_end_matches('/'))
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Finds the sources over an environment.
pub struct Detector<'a, E: Environment + ?Sized> {
    env: &'a E,
}

impl<'a, E: Environment + ?Sized> Detector<'a, E> {
    /// A detector reading `env`.
    pub const fn new(env: &'a E) -> Self {
        Self { env }
    }

    /// An absolute path, a `~/` path or a `file://` URL as a folder path; None for anything else.
    pub fn expand(&self, value: &str) -> Option<String> {
        let text = value.trim();
        if let Some(rest) = text.strip_prefix("file://") {
            let path = match rest.find('/') {
                Some(slash) => &rest[slash..],
                None => return None,
            };
            let path = path.split(['?', '#']).next().unwrap_or_default();
            return Some(standardize(&percent_decode(path)?));
        }
        if text == "~" {
            return Some(self.env.home());
        }
        if let Some(rest) = text.strip_prefix("~/") {
            return Some(join(&self.env.home(), rest));
        }
        if text.starts_with('/') {
            return Some(standardize(text));
        }
        None
    }

    fn existing(&self, value: &str) -> Option<String> {
        self.expand(value).filter(|folder| self.env.is_directory(folder))
    }

    /// macOS's screenshot folder: the `location` preference, else the Desktop.
    pub fn system_folder(&self) -> String {
        self.env
            .preference("location", SYSTEM_DOMAIN)
            .and_then(|location| self.existing(&location))
            .unwrap_or_else(|| join(&self.env.home(), "Desktop"))
    }

    /// A tool's save folder: a known key, its settings file, else any string preference whose key
    /// names a folder and whose value is an existing folder (keys in sorted order).
    pub fn save_folder(&self, tool: Tool) -> Option<String> {
        for domain in tool.preference_domains() {
            for key in tool.folder_keys() {
                if let Some(folder) =
                    self.env.preference(key, domain).and_then(|v| self.existing(&v))
                {
                    return Some(folder);
                }
            }
        }
        if let Some(file) = tool.settings_file()
            && let Some(folder) = self
                .env
                .text(&join(&self.env.home(), file.path))
                .and_then(|text| file.format.value(file.key, &text))
                .and_then(|value| self.existing(&value))
        {
            return Some(folder);
        }
        for domain in tool.preference_domains() {
            let mut values = self.env.string_preferences(domain);
            values.sort_by(|a, b| a.0.cmp(&b.0));
            for (key, value) in values {
                if looks_like_folder_key(&key)
                    && let Some(folder) = self.existing(&value)
                {
                    return Some(folder);
                }
            }
        }
        None
    }

    /// The folder as the kernel names it (symlinks resolved), else standardized.
    pub fn real_folder(&self, folder: &str) -> String {
        self.env.real_path(folder).unwrap_or_else(|| standardize(folder))
    }

    /// Every source, in menu order: macOS folder, macOS previews, tools (save folder then their
    /// fixed folders), then `extra_folders` (absolute or `~/` paths). `find_tools` false skips tools.
    pub fn detect(&self, find_tools: bool, extra_folders: &[String]) -> Vec<Source> {
        let mut sources = Vec::new();
        let mut seen = HashSet::new();
        let mut add = |id: String, folder: String, origin: Origin, rule: ScanRule| {
            if !self.env.is_directory(&folder) {
                return;
            }
            let folder = self.real_folder(&folder);
            if seen.insert(folder.clone()) {
                sources.push(Source { id, folder, origin, rule });
            }
        };
        add("system".into(), self.system_folder(), Origin::System, ScanRule::default());
        add(
            "system.preview".into(),
            join(&self.env.temporary_directory(), "TemporaryItems"),
            Origin::SystemPreview,
            ScanRule::with_depth(1, Some(PREVIEW_FOLDER_PREFIX)),
        );
        if find_tools {
            for tool in Tool::ALL {
                if let Some(folder) = self.save_folder(tool) {
                    add(format!("tool.{}", tool.raw()), folder, Origin::Tool(tool), tool.rule());
                }
                for fixed in tool.fixed_folders() {
                    let folder = join(&self.env.home(), fixed.path);
                    let (id, origin) = if fixed.history {
                        (format!("tool.{}.history", tool.raw()), Origin::ToolHistory(tool))
                    } else {
                        (format!("tool.{}", tool.raw()), Origin::Tool(tool))
                    };
                    add(id, folder, origin, fixed.rule);
                }
            }
        }
        for path in extra_folders {
            if let Some(folder) = self.expand(path) {
                add(format!("custom.{folder}"), folder, Origin::Custom, ScanRule::default());
            }
        }
        sources
    }
}

/// The sources as the C ABI's JSON: an array of `{id, folder, origin, tool, toolName,
/// acceptsDrops, rule: {kinds, extraImageExtensions, namePrefixes, depth, folderPrefix}}`.
pub fn sources_json(sources: &[Source]) -> String {
    let list: Vec<serde_json::Value> = sources
        .iter()
        .map(|s| {
            serde_json::json!({
                "id": s.id,
                "folder": s.folder,
                "origin": s.origin.name(),
                "tool": s.origin.tool().map(Tool::raw),
                "toolName": s.origin.tool().map(Tool::display_name),
                "acceptsDrops": s.accepts_drops(),
                "rule": {
                    "kinds": s.rule.kinds,
                    "extraImageExtensions": s.rule.extra_image_extensions,
                    "namePrefixes": s.rule.name_prefixes,
                    "depth": s.rule.depth,
                    "folderPrefix": s.rule.folder_prefix,
                },
            })
        })
        .collect();
    serde_json::Value::Array(list).to_string()
}

#[cfg(test)]
#[path = "detect_tests.rs"]
mod tests;
