//! The MCP server's switch: `mcp.enabled` in the settings file, owned by the config
//! layer (the app writes the file; this only reads it). Off unless the file
//! says `true`.

use std::path::{Path, PathBuf};

use serde_json::Value;

pub(super) use cmux_tui_core::user_settings::strip_jsonc;
#[cfg(test)]
pub(super) use cmux_tui_core::user_settings::{CONFIG_OVERRIDE, path_from};

/// The settings file the app writes: `CMUX_NEXT_CONFIG_FILE`, else
/// `~/.config/cmux/cmux-next.json` (classic `cmux.json` before the app's
/// first launch).
pub(super) fn path() -> PathBuf {
    cmux_tui_core::user_settings::config_path()
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
