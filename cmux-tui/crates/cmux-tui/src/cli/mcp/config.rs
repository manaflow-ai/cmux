//! The MCP server's switch: `mcp.enabled` in cmux.json, owned by the config
//! layer (the app writes the file; this only reads it). Off unless the file
//! says `true`.

use std::path::{Path, PathBuf};

use serde_json::Value;

/// Environment variable that names another settings file, as in the app
/// (`CmuxConfigFile.overrideKey`), so test launches never read the user's.
pub(super) const CONFIG_OVERRIDE: &str = "CMUX_NEXT_CONFIG_FILE";

/// The settings file: `CMUX_NEXT_CONFIG_FILE`, else
/// `$HOME/.config/cmux/cmux.json`.
pub(super) fn path() -> PathBuf {
    path_from(|name| std::env::var_os(name).filter(|value| !value.is_empty()))
}

pub(super) fn path_from(env: impl Fn(&str) -> Option<std::ffi::OsString>) -> PathBuf {
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
    home.join(".config/cmux/cmux.json")
}

/// Whether `mcp.enabled` is `true`. A missing file, a missing key and
/// `false` are off; an unreadable file or a non-boolean value is an error
/// the caller reports, so a typo never turns the server on.
pub(super) fn enabled(path: &Path) -> Result<bool, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    enabled_in(&text).map_err(|error| format!("{}: {error}", path.display()))
}

pub(super) fn enabled_in(text: &str) -> Result<bool, String> {
    if text.trim().is_empty() {
        return Ok(false);
    }
    let document: Value = serde_json::from_str(&strip_jsonc(text))
        .map_err(|error| format!("cmux.json is not valid JSONC: {error}"))?;
    match document.get("mcp").and_then(|mcp| mcp.get("enabled")) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(enabled)) => Ok(*enabled),
        Some(_) => Err("mcp.enabled must be true or false".into()),
    }
}

/// JSONC to JSON: drops `//` and `/* */` comments, then trailing commas,
/// outside strings (the dialect the app's `JSONC` parser reads).
pub(super) fn strip_jsonc(text: &str) -> String {
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
