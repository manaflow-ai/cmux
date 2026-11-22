//! The few settings-file keys the daemon reads itself. The app owns the
//! file (it writes it, `CmuxConfigFile`); the daemon and the CLI only read
//! it, so every client that talks to this daemon gets the same value
//! (plans/cmux-next/settings-react.md: preferences belong to the config
//! layer of the machine). The managed (MDM) layer is not read here.

use std::cell::Cell;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use serde_json::Value;

/// Environment variable that names another settings file, as in the app
/// (`CmuxConfigFile.overrideKey`), so test launches never read the user's.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// The app's settings file (`CmuxConfigFile.defaultURL`), under the home.
const NEXT_FILE: &str = ".config/cmux/cmux-next.json";
/// Classic cmux's file, which the app copies to [`NEXT_FILE`] at its first
/// launch.
const CLASSIC_FILE: &str = ".config/cmux/cmux.json";

/// The settings file the app reads and writes: `CMUX_NEXT_CONFIG_FILE`,
/// else `<home>/.config/cmux/cmux-next.json`; while that file does not exist
/// yet (the app never ran), classic `cmux.json`, which the app would seed it
/// from.
pub fn config_path() -> PathBuf {
    let env = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if env(CONFIG_OVERRIDE).is_some() {
        return path_from(env);
    }
    let home = crate::platform::home_dir().unwrap_or_default();
    let next = home.join(NEXT_FILE);
    let classic = home.join(CLASSIC_FILE);
    if !next.exists() && classic.exists() { classic } else { next }
}

/// `CMUX_NEXT_CONFIG_FILE` (a leading `~` is the home), else the app's file
/// under `HOME`, from the environment `env`.
pub fn path_from(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> PathBuf {
    if let Some(path) = env(CONFIG_OVERRIDE) {
        let path = PathBuf::from(path);
        if let Ok(rest) = path.strip_prefix("~")
            && let Some(home) = env("HOME")
        {
            return PathBuf::from(home).join(rest);
        }
        return path;
    }
    let home = env("HOME").map(PathBuf::from).unwrap_or_default();
    home.join(NEXT_FILE)
}

/// Settings-file `workspaces.newPlacement`: where a new workspace goes in
/// the personal sidebar order when its creator names no place. Same values
/// and default as the app's `NewWorkspacePlacement`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NewWorkspacePlacement {
    /// First, below the home workspace's row, above every group.
    #[default]
    Top,
    /// Right after the session's active workspace, in its group (`Top`
    /// when there is none, or it is the home workspace).
    AfterCurrent,
    /// After every row.
    Bottom,
}

thread_local! {
    /// A creation path that names its own place (reopen, Home): every
    /// workspace this thread creates meanwhile goes there. Unit tests set it
    /// too ([`NewWorkspacePlacement::set_for_test`]).
    static SCOPED: Cell<Option<NewWorkspacePlacement>> = const { Cell::new(None) };
}

/// The last value read, with the identity of the file it came from.
struct CachedPlacement {
    path: PathBuf,
    modified: Option<SystemTime>,
    len: u64,
    value: NewWorkspacePlacement,
}

/// So a creation only stats the file while it does not change.
static CACHE: Mutex<Option<CachedPlacement>> = Mutex::new(None);

impl NewWorkspacePlacement {
    /// The value in settings text `text`. A missing key, a value the app does
    /// not know and a file that does not parse give the default, as in the
    /// app (which reports the bad value as a diagnostic).
    pub fn from_config_text(text: &str) -> Self {
        let Ok(document) = serde_json::from_str::<Value>(&strip_jsonc(text)) else {
            return Self::default();
        };
        match document.pointer("/workspaces/newPlacement").and_then(Value::as_str) {
            Some("afterCurrent") => Self::AfterCurrent,
            Some("bottom") => Self::Bottom,
            _ => Self::default(),
        }
    }

    /// The value in the settings file at `path`; the default without one.
    /// Only a regular file is read (never a FIFO or a device).
    pub fn from_config_file(path: &Path) -> Self {
        let Ok(metadata) = std::fs::metadata(path) else { return Self::default() };
        if !metadata.is_file() {
            return Self::default();
        }
        let (modified, len) = (metadata.modified().ok(), metadata.len());
        let mut cache = CACHE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(cached) = cache.as_ref()
            && cached.path == path
            && (cached.modified, cached.len) == (modified, len)
        {
            return cached.value;
        }
        let value = std::fs::read_to_string(path)
            .map(|text| Self::from_config_text(&text))
            .unwrap_or_default();
        *cache = Some(CachedPlacement { path: path.to_path_buf(), modified, len, value });
        value
    }

    /// The value a workspace this daemon creates now uses: a scoped place
    /// ([`Self::scoped`]), else the settings file, read at each creation (a
    /// change applies to the next workspace with no reload). Unit tests
    /// never read the developer's file: they get the default.
    pub(crate) fn current() -> Self {
        if let Some(scoped) = SCOPED.with(Cell::get) {
            return scoped;
        }
        if cfg!(test) { Self::default() } else { Self::from_config_file(&config_path()) }
    }

    /// Runs `body` with every workspace this thread creates placed at
    /// `self`: a creation path that names its own place.
    pub(crate) fn scoped<T>(self, body: impl FnOnce() -> T) -> T {
        let _guard = ScopedPlacement(SCOPED.with(|cell| cell.replace(Some(self))));
        body()
    }

    /// The value [`Self::current`] gives on this thread until the guard drops.
    #[cfg(test)]
    pub(crate) fn set_for_test(self) -> ScopedPlacement {
        ScopedPlacement(SCOPED.with(|cell| cell.replace(Some(self))))
    }
}

/// Restores the scoped placement that was set before.
pub(crate) struct ScopedPlacement(Option<NewWorkspacePlacement>);

impl Drop for ScopedPlacement {
    fn drop(&mut self) {
        SCOPED.with(|cell| cell.set(self.0));
    }
}

/// JSONC to JSON: drops `//` and `/* */` comments, then trailing commas,
/// outside strings (the dialect the app's `JSONC` parser reads).
pub fn strip_jsonc(text: &str) -> String {
    drop_trailing_commas(&drop_comments(text))
}

/// The text without comments; strings are copied unchanged.
fn drop_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start, mut in_string) = (0, 0, false);
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            match byte {
                b'\\' => index += 2,
                b'"' => {
                    in_string = false;
                    index += 1;
                }
                _ => index += 1,
            }
            continue;
        }
        match (byte, bytes.get(index + 1)) {
            (b'"', _) => {
                in_string = true;
                index += 1;
            }
            (b'/', Some(b'/')) => {
                output.push_str(&text[start..index]);
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
                start = index;
            }
            (b'/', Some(b'*')) => {
                output.push_str(&text[start..index]);
                index += 2;
                while index < bytes.len()
                    && !(bytes[index] == b'*' && bytes.get(index + 1) == Some(&b'/'))
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
                start = index;
            }
            _ => index += 1,
        }
    }
    output.push_str(&text[start.min(bytes.len())..]);
    output
}

/// Removes a comma whose next non-space byte closes an object or array.
fn drop_trailing_commas(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start, mut in_string) = (0, 0, false);
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            match byte {
                b'\\' => index += 2,
                b'"' => {
                    in_string = false;
                    index += 1;
                }
                _ => index += 1,
            }
            continue;
        }
        if byte == b'"' {
            in_string = true;
        } else if byte == b','
            && matches!(
                bytes[index + 1..].iter().find(|byte| !byte.is_ascii_whitespace()),
                Some(b'}' | b']')
            )
        {
            output.push_str(&text[start..index]);
            start = index + 1;
        }
        index += 1;
    }
    output.push_str(&text[start.min(bytes.len())..]);
    output
}

#[cfg(test)]
mod tests {
    use super::NewWorkspacePlacement as Placement;

    #[test]
    fn new_placement_reads_cmux_json_with_the_app_default() {
        assert_eq!(Placement::from_config_text(""), Placement::Top);
        assert_eq!(Placement::from_config_text("{}"), Placement::Top);
        assert_eq!(
            Placement::from_config_text(
                "{\n  // order\n  \"workspaces\": {\"newPlacement\": \"bottom\",},\n}"
            ),
            Placement::Bottom
        );
        assert_eq!(
            Placement::from_config_text(r#"{"workspaces": {"newPlacement": "afterCurrent"}}"#),
            Placement::AfterCurrent
        );
        assert_eq!(
            Placement::from_config_text(r#"{"workspaces": {"newPlacement": "sideways"}}"#),
            Placement::Top
        );
        assert_eq!(Placement::from_config_text("{not json"), Placement::Top);
    }

    #[test]
    fn a_scoped_placement_wins_and_nests() {
        assert_eq!(Placement::current(), Placement::Top);
        let outer = Placement::Bottom.set_for_test();
        Placement::AfterCurrent
            .scoped(|| assert_eq!(Placement::current(), Placement::AfterCurrent));
        assert_eq!(Placement::current(), Placement::Bottom);
        drop(outer);
        assert_eq!(Placement::current(), Placement::Top);
    }

    #[test]
    fn a_changed_settings_file_is_read_again() {
        let path =
            std::env::temp_dir().join(format!("cmux-new-placement-{}.json", std::process::id()));
        std::fs::write(&path, r#"{"workspaces": {"newPlacement": "bottom"}}"#).unwrap();
        assert_eq!(Placement::from_config_file(&path), Placement::Bottom);
        std::fs::write(&path, r#"{"workspaces": {"newPlacement": "afterCurrent", "x": 1}}"#)
            .unwrap();
        assert_eq!(Placement::from_config_file(&path), Placement::AfterCurrent);
        std::fs::remove_file(&path).unwrap();
        assert_eq!(Placement::from_config_file(&path), Placement::Top);
        assert_eq!(
            Placement::from_config_file(&std::env::temp_dir()),
            Placement::Top,
            "a directory is not read"
        );
    }
}
