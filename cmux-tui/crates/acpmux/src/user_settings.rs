//! The cmux settings file, read only (the app's settings owner writes it):
//! `CMUX_NEXT_CONFIG_FILE`, else `~/.config/cmux/cmux-next.json`, else
//! classic `~/.config/cmux/cmux.json` before the app's first launch copies
//! it. The same file as `cmux_config::config_path` and `seed_path`
//! (cmux-tui `crates/cmux-config/src/location.rs`), without the dependency.
//! Read at each use, so a settings change applies to the next new chat.

use serde_json::Value;
use std::path::PathBuf;

/// The override the app and tests set.
pub const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// What the settings file holds now.
pub enum Settings {
    /// No settings file: every key has its default.
    Missing,
    /// The file, parsed.
    Parsed(Value),
    /// A file that exists but cannot be read or parsed: a key whose default
    /// widens what runs without asking must not take that default.
    Unreadable(String),
}

/// The files `read` looks at, first that exists wins: the override alone,
/// else `cmux-next.json` then classic `cmux.json`. The settings watcher
/// (`hub/settings_watch.rs`) watches these.
pub fn paths() -> Vec<PathBuf> {
    let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty());
    let home = || var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    if let Some(path) = var(CONFIG_OVERRIDE) {
        let path = PathBuf::from(path);
        let path = match path.strip_prefix("~") {
            Ok(rest) => home().join(rest),
            Err(_) => path,
        };
        return vec![path];
    }
    let home = home();
    vec![home.join(".config/cmux/cmux-next.json"), home.join(".config/cmux/cmux.json")]
}

/// The settings file as it is now.
pub fn read() -> Settings {
    let read_one = |path: &std::path::Path| match std::fs::read_to_string(path) {
        Ok(text) => Some(match document(&text) {
            Some(doc) => Settings::Parsed(doc),
            None => Settings::Unreadable(format!("{}: not valid JSONC", path.display())),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => Some(Settings::Unreadable(format!("{}: {e}", path.display()))),
    };
    paths().iter().find_map(|path| read_one(path)).unwrap_or(Settings::Missing)
}

/// The settings file's text, or `None` when there is none to read.
pub fn text() -> Option<String> {
    match read() {
        Settings::Parsed(doc) => Some(doc.to_string()),
        Settings::Missing | Settings::Unreadable(_) => None,
    }
}

/// The settings document (JSONC: `//` and `/* */` comments and trailing
/// commas, as the app's settings owner reads it), or `None` when it does
/// not parse.
pub fn document(text: &str) -> Option<Value> {
    serde_json::from_str::<Value>(&strip_jsonc(text)).ok()
}

/// The value at a dotted settings key (`agents.defaultPermissionMode`), in
/// either form the settings owner writes: nested objects or one flat key.
pub fn value(doc: &Value, key: &str) -> Option<Value> {
    if let Some(v) = doc.get(key) {
        return Some(v.clone());
    }
    let pointer = format!("/{}", key.replace('.', "/"));
    doc.pointer(&pointer).cloned()
}

/// JSONC to JSON: drops `//` and `/* */` comments, then trailing commas,
/// outside strings. A copy of cmux-tui-util's `strip_jsonc` (the dialect the
/// app's JSONC parser reads), kept here so acpmux takes no new dependency.
pub fn strip_jsonc(text: &str) -> String {
    drop_trailing_commas(&drop_comments(text))
}

/// The text without comments; strings are copied unchanged.
fn drop_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start, mut in_string) = (0, 0, false);
    while let Some(&byte) = bytes.get(index) {
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
            // `start` and `index` sit on ASCII bytes outside strings: character boundaries.
            (b'/', Some(b'/')) => {
                output.push_str(text.get(start..index).unwrap_or_default());
                while bytes.get(index).is_some_and(|&b| b != b'\n') {
                    index += 1;
                }
                start = index;
            }
            (b'/', Some(b'*')) => {
                output.push_str(text.get(start..index).unwrap_or_default());
                index += 2;
                while bytes
                    .get(index)
                    .is_some_and(|&b| !(b == b'*' && bytes.get(index + 1) == Some(&b'/')))
                {
                    index += 1;
                }
                index = (index + 2).min(bytes.len());
                start = index;
            }
            _ => index += 1,
        }
    }
    output.push_str(text.get(start..).unwrap_or_default());
    output
}

/// Removes a comma whose next non-space byte closes an object or array.
fn drop_trailing_commas(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let (mut index, mut start, mut in_string) = (0, 0, false);
    while let Some(&byte) = bytes.get(index) {
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
                bytes.iter().skip(index + 1).find(|byte| !byte.is_ascii_whitespace()),
                Some(b'}' | b']')
            )
        {
            output.push_str(text.get(start..index).unwrap_or_default());
            start = index + 1;
        }
        index += 1;
    }
    output.push_str(text.get(start..).unwrap_or_default());
    output
}
