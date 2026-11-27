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
        if bytes.get(i) == Some(&b'%') {
            let hex = text.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(*bytes.get(i)?);
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
mod tests {
    use super::*;
    use crate::rule::{IMAGES_AND_VIDEOS, MediaKind};
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A folder made for one test, removed when it ends.
    struct TempFolder(PathBuf);

    impl TempFolder {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let n = NEXT.fetch_add(1, Ordering::Relaxed);
            let dir =
                std::env::temp_dir().join(format!("cmux-screenshots-{}-{n}", std::process::id()));
            std::fs::create_dir_all(&dir).expect("temp folder");
            Self(std::fs::canonicalize(&dir).expect("real temp folder"))
        }

        fn folder(&self, relative: &str) -> String {
            let dir = self.0.join(relative);
            std::fs::create_dir_all(&dir).expect("folder");
            dir.to_string_lossy().into_owned()
        }

        fn path(&self) -> String {
            self.0.to_string_lossy().into_owned()
        }
    }

    impl Drop for TempFolder {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A fake Mac: preferences and files in memory, folders on disk under a temporary home.
    struct Fixture {
        home: TempFolder,
        temp: TempFolder,
        preferences: HashMap<String, HashMap<String, String>>,
        files: HashMap<String, String>,
    }

    impl Fixture {
        fn new() -> Self {
            let fixture = Self {
                home: TempFolder::new(),
                temp: TempFolder::new(),
                preferences: HashMap::new(),
                files: HashMap::new(),
            };
            fixture.home.folder("Desktop");
            fixture.temp.folder("TemporaryItems");
            fixture
        }

        fn pref(mut self, domain: &str, key: &str, value: &str) -> Self {
            self.preferences.entry(domain.into()).or_default().insert(key.into(), value.into());
            self
        }

        fn file(mut self, relative: &str, text: &str) -> Self {
            self.files.insert(join(&self.home.path(), relative), text.into());
            self
        }

        fn detect(&self, find_tools: bool, extra: &[&str]) -> Vec<Source> {
            let extra: Vec<String> = extra.iter().map(|s| (*s).to_owned()).collect();
            Detector::new(self).detect(find_tools, &extra)
        }
    }

    impl Environment for Fixture {
        fn home(&self) -> String {
            self.home.path()
        }
        fn temporary_directory(&self) -> String {
            self.temp.path()
        }
        fn preference(&self, key: &str, domain: &str) -> Option<String> {
            self.preferences.get(domain)?.get(key).cloned()
        }
        fn string_preferences(&self, domain: &str) -> Vec<(String, String)> {
            self.preferences
                .get(domain)
                .map(|m| m.clone().into_iter().collect())
                .unwrap_or_default()
        }
        fn text(&self, path: &str) -> Option<String> {
            self.files.get(path).cloned()
        }
        fn is_directory(&self, path: &str) -> bool {
            std::fs::metadata(path).is_ok_and(|m| m.is_dir())
        }
        fn real_path(&self, path: &str) -> Option<String> {
            std::fs::canonicalize(path).ok().map(|p| p.to_string_lossy().into_owned())
        }
    }

    fn ids(sources: &[Source]) -> Vec<&str> {
        sources.iter().map(|s| s.id.as_str()).collect()
    }

    #[test]
    fn with_nothing_set_it_lists_the_desktop_and_the_preview_folder() {
        let env = Fixture::new();
        let sources = env.detect(true, &[]);
        assert_eq!(ids(&sources), ["system", "system.preview"]);
        assert_eq!(sources[0].folder, join(&env.home.path(), "Desktop"));
        assert_eq!(sources[1].folder, join(&env.temp.path(), "TemporaryItems"));
        assert_eq!(sources[1].rule.folder_prefix.as_deref(), Some("NSIRD_screencaptureui_"));
        assert_eq!(sources[1].rule.depth, 1);
        assert!(sources[0].accepts_drops());
        assert!(!sources[1].accepts_drops());
    }

    #[test]
    fn reads_the_screencapture_location_with_a_tilde() {
        let env = Fixture::new().pref(SYSTEM_DOMAIN, "location", "~/screenshots");
        let shots = env.home.folder("screenshots");
        assert_eq!(env.detect(false, &[])[0].folder, shots);
    }

    #[test]
    fn a_missing_location_falls_back_to_the_desktop() {
        let env =
            Fixture::new().pref(SYSTEM_DOMAIN, "location", "/nowhere/cmux-screenshots-missing");
        assert!(Detector::new(&env).system_folder().ends_with("/Desktop"));
    }

    /// CleanShot X exports into the macOS folder (shown once) and keeps a history.
    #[test]
    fn clean_shot_into_the_macos_folder_shows_once_and_its_history_shows_too() {
        let env = Fixture::new();
        let shots = env.home.folder("screenshots");
        env.home.folder("Library/Application Support/CleanShot/media");
        let env = env.pref(SYSTEM_DOMAIN, "location", "~/screenshots").pref(
            "pl.maketheweb.cleanshotx",
            "exportPath",
            &shots,
        );
        let sources = env.detect(true, &[]);
        assert_eq!(ids(&sources), ["system", "system.preview", "tool.cleanShotX.history"]);
        let history = sources.last().expect("history");
        assert_eq!(history.origin.tool().map(Tool::display_name), Some("CleanShot X"));
        assert_eq!(history.rule.folder_prefix.as_deref(), Some("media_"));
        assert_eq!(history.origin, Origin::ToolHistory(Tool::CleanShotX));
        assert!(!history.accepts_drops());
    }

    #[test]
    fn reads_kap_and_flameshot_settings_files() {
        let env = Fixture::new();
        let kap = env.home.folder("Kaps");
        let flame = env.home.folder("Flames");
        let env = env
            .file(
                "Library/Application Support/Kap/config.json",
                &format!(r#"{{"kapturesDir": "{kap}"}}"#),
            )
            .file(".config/flameshot/flameshot.ini", "[General]\nsavePath=~/Flames\n");
        let sources = env.detect(true, &[]);
        let by_id: HashMap<&str, &Source> = sources.iter().map(|s| (s.id.as_str(), s)).collect();
        assert_eq!(by_id["tool.kap"].folder, kap);
        assert_eq!(by_id["tool.kap"].rule.kinds, IMAGES_AND_VIDEOS);
        assert_eq!(by_id["tool.flameshot"].folder, flame);
    }

    /// A tool whose key the detector does not know: any string preference naming an existing folder.
    #[test]
    fn finds_an_unknown_key_that_names_a_folder() {
        let env = Fixture::new();
        let saves = env.home.folder("ShottrSaves");
        let env = env
            .pref("cc.ffitch.shottr", "NSWindowFrame", "1 2 3 4")
            .pref("cc.ffitch.shottr", "theme", "dark")
            .pref("cc.ffitch.shottr", "defaultSaveFolder", &saves);
        let sources = env.detect(true, &[]);
        assert_eq!(
            sources.iter().find(|s| s.id == "tool.shottr").map(|s| s.folder.as_str()),
            Some(saves.as_str())
        );
        assert!(looks_like_folder_key("exportPath"));
        assert!(looks_like_folder_key("SaveLocation"));
        assert!(!looks_like_folder_key("NSOSPLastRootDirectory"));
        assert!(!looks_like_folder_key("recentFolders"));
        assert!(!looks_like_folder_key("theme"));
    }

    #[test]
    fn tools_off_lists_only_macos_and_the_persons_folders() {
        let env = Fixture::new();
        env.home.folder("Library/Application Support/CleanShot/media");
        let mine = env.home.folder("Pictures/Mine");
        let sources = env.detect(false, &["~/Pictures/Mine", "relative/ignored"]);
        let origins: Vec<_> = sources.iter().map(|s| s.origin).collect();
        assert_eq!(origins, [Origin::System, Origin::SystemPreview, Origin::Custom]);
        let last = sources.last().expect("custom");
        assert_eq!(last.id, format!("custom.{mine}"));
        assert!(last.folder.ends_with("/Mine"));
        assert!(last.accepts_drops());
    }

    #[test]
    fn a_folder_that_does_not_exist_is_not_listed() {
        let env = Fixture::new();
        assert_eq!(
            ids(&env.detect(true, &["/nowhere/cmux-screenshots-missing"])),
            ["system", "system.preview"]
        );
    }

    #[test]
    fn fixed_folders_carry_their_rules() {
        let env = Fixture::new();
        env.home.folder("Movies");
        env.home.folder("Library/Application Support/so.cap.desktop/recordings");
        let sources = env.detect(true, &[]);
        assert_eq!(
            ids(&sources),
            ["system", "system.preview", "tool.cap.history", "tool.quickTime"]
        );
        assert_eq!(sources[2].rule.kinds, MediaKind::Video.bit());
        assert_eq!(sources[2].rule.depth, 3);
        assert_eq!(sources[3].rule.name_prefixes.len(), 9);
        assert!(sources[3].accepts_drops());
    }

    #[test]
    fn expand_takes_absolute_tilde_and_file_urls() {
        let env = Fixture::new();
        let d = Detector::new(&env);
        let home = env.home.path();
        assert_eq!(d.expand(" ~ ").as_deref(), Some(home.as_str()));
        assert_eq!(d.expand("~/a/b"), Some(join(&home, "a/b")));
        assert_eq!(d.expand("/a/./b/../c/").as_deref(), Some("/a/c"));
        assert_eq!(d.expand("file:///a%20b/c/").as_deref(), Some("/a b/c"));
        assert_eq!(d.expand("file://localhost/x").as_deref(), Some("/x"));
        assert_eq!(d.expand("relative"), None);
        assert_eq!(d.expand("~other"), None);
    }

    #[test]
    fn sources_json_names_the_origin_and_rule() {
        let env = Fixture::new();
        let json: serde_json::Value =
            serde_json::from_str(&sources_json(&env.detect(true, &[]))).expect("json");
        assert_eq!(json[1]["origin"], "systemPreview");
        assert_eq!(json[1]["acceptsDrops"], false);
        assert_eq!(json[1]["rule"]["depth"], 1);
        assert_eq!(json[0]["tool"], serde_json::Value::Null);
    }
}
