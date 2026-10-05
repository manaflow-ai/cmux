//! The user's Ghostty `shell-integration`, `shell-integration-features` and
//! `cursor-style-blink`, read from their Ghostty config files at each spawn
//! of a shell the daemon starts (decision
//! DAEMON-SHELL-FEATURES-FROM-GHOSTTY-FILES). It follows libghostty: the
//! default files in order (`platform::ghostty_config_paths_from`), or only
//! `CMUX_NEXT_GHOSTTY_CONFIG` as the app loads it, then the `config-file`
//! includes after them, each once (`Config.loadRecursiveFiles`); a value
//! replaces the previous one, an empty value resets it, an invalid one is
//! ignored (`cli/args.zig`). schemas/ghostty-shell-features/vectors.json
//! holds what libghostty resolves; the app's test checks libghostty against
//! it and this module replays it.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

/// The app's single-file config override (`GhosttyRuntime.configOverrideKey`).
const CONFIG_OVERRIDE_ENV: &str = "CMUX_NEXT_GHOSTTY_CONFIG";
const MODE_KEY: &str = "shell-integration";
const FEATURES_KEY: &str = "shell-integration-features";
const BLINK_KEY: &str = "cursor-style-blink";
const INCLUDE_KEY: &str = "config-file";
/// Ghostty's `whitespace` for trimming keys, values and parts.
const WHITESPACE: &[char] = &[' ', '\t'];

/// Ghostty's `ShellIntegrationFeatures` with its defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Features {
    pub cursor: bool,
    pub sudo: bool,
    pub title: bool,
    pub ssh_env: bool,
    pub ssh_terminfo: bool,
    pub path: bool,
}

impl Default for Features {
    fn default() -> Self {
        Self {
            cursor: true,
            sudo: false,
            title: true,
            ssh_env: false,
            ssh_terminfo: false,
            path: true,
        }
    }
}

impl Features {
    fn all(on: bool) -> Self {
        Self { cursor: on, sudo: on, title: on, ssh_env: on, ssh_terminfo: on, path: on }
    }

    fn field(&mut self, name: &str) -> Option<&mut bool> {
        Some(match name {
            "cursor" => &mut self.cursor,
            "sudo" => &mut self.sudo,
            "title" => &mut self.title,
            "ssh-env" => &mut self.ssh_env,
            "ssh-terminfo" => &mut self.ssh_terminfo,
            "path" => &mut self.path,
            _ => return None,
        })
    }

    /// `parsePackedStruct`: a bool sets every feature; otherwise each comma
    /// part, trimmed, turns its feature on (`no-` off) over the defaults.
    /// Nil when any part names no feature.
    fn parse(value: &str) -> Option<Self> {
        if let Some(on) = parse_bool(value) {
            return Some(Self::all(on));
        }
        let mut features = Self::default();
        for part in value.split(',') {
            let part = part.trim_matches(WHITESPACE);
            let (name, on) = match part.strip_prefix("no-") {
                Some(name) => (name, false),
                None => (part, true),
            };
            *features.field(name)? = on;
        }
        Some(features)
    }
}

/// Ghostty's `shell-integration`: never, by the shell's name, or one shell
/// forced whatever the command is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum Mode {
    None,
    #[default]
    Detect,
    Bash,
    Elvish,
    Fish,
    Nushell,
    Zsh,
}

impl Mode {
    /// The enum's names exactly; nil for any other value.
    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "none" => Self::None,
            "detect" => Self::Detect,
            "bash" => Self::Bash,
            "elvish" => Self::Elvish,
            "fish" => Self::Fish,
            "nushell" => Self::Nushell,
            "zsh" => Self::Zsh,
            _ => return None,
        })
    }

    /// The vectors' name for the mode.
    #[cfg(test)]
    fn name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Detect => "detect",
            Self::Bash => "bash",
            Self::Elvish => "elvish",
            Self::Fish => "fish",
            Self::Nushell => "nushell",
            Self::Zsh => "zsh",
        }
    }
}

/// The keys the daemon needs, as the user's files set them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) struct Settings {
    pub mode: Mode,
    pub features: Features,
    /// Nil when unset (Ghostty then blinks).
    pub cursor_blink: Option<bool>,
}

impl Settings {
    /// `GHOSTTY_SHELL_FEATURES` as Ghostty's `setupFeatures` writes it:
    /// enabled names sorted, `cursor` with its blink state; empty when none.
    pub(super) fn env_value(&self) -> String {
        let f = self.features;
        let blink =
            if self.cursor_blink.unwrap_or(true) { "cursor:blink" } else { "cursor:steady" };
        [
            (f.cursor, blink),
            (f.path, "path"),
            (f.ssh_env, "ssh-env"),
            (f.ssh_terminfo, "ssh-terminfo"),
            (f.sudo, "sudo"),
            (f.title, "title"),
        ]
        .into_iter()
        .filter_map(|(on, name)| on.then_some(name))
        .collect::<Vec<_>>()
        .join(",")
    }
}

/// The user's settings for a shell whose environment `lookup` reads: its
/// `CMUX_NEXT_GHOSTTY_CONFIG`, else the default files under its
/// `XDG_CONFIG_HOME` and `HOME`. Missing files leave Ghostty's defaults.
pub(super) fn read(lookup: &dyn Fn(&str) -> Option<String>) -> Settings {
    let files = match lookup(CONFIG_OVERRIDE_ENV).filter(|path| !path.is_empty()) {
        Some(path) => vec![PathBuf::from(path)],
        None => crate::platform::ghostty_config_paths_from(
            lookup("XDG_CONFIG_HOME").filter(|v| !v.is_empty()).map(PathBuf::from),
            lookup("HOME").filter(|v| !v.is_empty()).map(PathBuf::from),
        ),
    };
    read_files(&files, lookup("HOME").as_deref())
}

/// `files` in order, then their `config-file` includes.
pub(super) fn read_files(files: &[PathBuf], home: Option<&str>) -> Settings {
    let mut reader = Reader { settings: Settings::default(), includes: Vec::new(), home };
    for file in files {
        if let Ok(text) = fs::read_to_string(file) {
            reader.apply(&text, file.parent().unwrap_or(Path::new("/")));
        }
    }
    let mut loaded = HashSet::new();
    let mut index = 0;
    while index < reader.includes.len() {
        let path = reader.includes[index].clone();
        index += 1;
        // A file loads once; a second mention is a cycle and is skipped.
        if !loaded.insert(path.clone()) {
            continue;
        }
        if let Ok(text) = fs::read_to_string(&path) {
            reader.apply(&text, path.parent().unwrap_or(Path::new("/")));
        }
    }
    reader.settings
}

struct Reader<'a> {
    settings: Settings,
    includes: Vec<PathBuf>,
    home: Option<&'a str>,
}

impl Reader<'_> {
    /// One file's lines (`LineIterator`): trimmed, blank and `#` lines
    /// skipped, `key = value` with one pair of surrounding quotes removed.
    fn apply(&mut self, text: &str, dir: &Path) {
        for line in text.split('\n') {
            let line = line.trim_matches(|c| WHITESPACE.contains(&c) || c == '\r');
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                // A key with no value: a bool takes true; the others refuse it.
                if line.trim_matches(WHITESPACE) == BLINK_KEY {
                    self.settings.cursor_blink = Some(true);
                }
                continue;
            };
            let mut value = value.trim_matches(WHITESPACE);
            if value.len() >= 2 && value.starts_with('"') && value.ends_with('"') {
                value = &value[1..value.len() - 1];
            }
            match key.trim_matches(WHITESPACE) {
                FEATURES_KEY if value.is_empty() => self.settings.features = Features::default(),
                FEATURES_KEY => {
                    if let Some(features) = Features::parse(value) {
                        self.settings.features = features;
                    }
                }
                // Red: shell-integration is not read yet.
                MODE_KEY if Mode::parse(value).is_some() && value.is_empty() => {}
                BLINK_KEY if value.is_empty() => self.settings.cursor_blink = None,
                BLINK_KEY => {
                    if let Some(on) = parse_bool(value) {
                        self.settings.cursor_blink = Some(on);
                    }
                }
                INCLUDE_KEY if value.is_empty() => self.includes.clear(),
                INCLUDE_KEY => {
                    let path = value.strip_prefix('?').unwrap_or(value);
                    if let Some(path) = self.resolve(path, dir) {
                        self.includes.push(path);
                    }
                }
                _ => {}
            }
        }
    }

    /// An include path: `~/` from `HOME`, relative to the including file.
    fn resolve(&self, path: &str, dir: &Path) -> Option<PathBuf> {
        if path.is_empty() {
            return None;
        }
        if let Some(rest) = path.strip_prefix("~/") {
            return self.home.map(|home| Path::new(home).join(rest));
        }
        let path = Path::new(path);
        Some(if path.is_absolute() { path.to_path_buf() } else { dir.join(path) })
    }
}

/// `parseBool`: exactly `1 t T true` or `0 f F false`.
fn parse_bool(value: &str) -> Option<bool> {
    match value {
        "1" | "t" | "T" | "true" => Some(true),
        "0" | "f" | "F" | "false" => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    /// Every case of the shared vectors resolves as libghostty does.
    #[test]
    fn the_daemon_reads_every_vector_as_libghostty() {
        let vectors: Value = serde_json::from_str(include_str!(
            "../../../../../schemas/ghostty-shell-features/vectors.json"
        ))
        .unwrap();
        let cases = vectors["cases"].as_array().unwrap();
        assert!(cases.len() >= 20);
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let dir = std::env::temp_dir().join(format!(
                "cmux-ghostty-shell-features-{}-{}",
                std::process::id(),
                name.replace(|c: char| !c.is_ascii_alphanumeric(), "-")
            ));
            let _ = fs::remove_dir_all(&dir);
            for (file, text) in case["files"].as_object().unwrap() {
                let path = dir.join(file);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(&path, text.as_str().unwrap()).unwrap();
            }
            let settings = read_files(&[dir.join("config")], None);
            let mut expected = Features::all(false);
            for feature in case["features"].as_array().unwrap() {
                *expected.field(feature.as_str().unwrap()).unwrap() = true;
            }
            assert_eq!(settings.features, expected, "{name}");
            assert_eq!(settings.cursor_blink, case["cursor_blink"].as_bool(), "{name}");
            assert_eq!(settings.mode.name(), case["shell_integration"].as_str().unwrap(), "{name}");
            fs::remove_dir_all(&dir).unwrap();
        }
    }

    /// The env value Ghostty's `setupFeatures` writes: sorted names, the
    /// cursor with its blink state, empty when every feature is off.
    #[test]
    fn the_env_value_is_ghosttys() {
        assert_eq!(Settings::default().env_value(), "cursor:blink,path,title");
        let steady = Settings {
            features: Features::all(true),
            cursor_blink: Some(false),
            ..Settings::default()
        };
        assert_eq!(steady.env_value(), "cursor:steady,path,ssh-env,ssh-terminfo,sudo,title");
        let none =
            Settings { features: Features::all(false), cursor_blink: None, ..Settings::default() };
        assert_eq!(none.env_value(), "");
    }
}
