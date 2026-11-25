//! The MCP server's switch: `mcp.enabled` in the settings file, owned by the config
//! layer (the app writes the file; this only reads it). On when the file
//! says `true`, or leaves it unset while cmux's tools for agents in cmux are
//! on (`agents.cmuxMcp`, on by default: a missing file too). Off when the
//! file says `false`, or leaves it unset with `agents.cmuxMcp` `off`.

use std::path::{Path, PathBuf};

use serde_json::Value;

pub(super) use cmux_tui_core::user_settings::strip_jsonc;
#[cfg(test)]
pub(super) use cmux_tui_core::user_settings::{CONFIG_OVERRIDE, path_from};

/// The settings file the app writes: `CMUX_NEXT_CONFIG_FILE`, else
/// `~/.config/cmux/cmux-next.json`.
pub(super) fn path() -> PathBuf {
    cmux_tui_core::user_settings::config_path()
}

/// `mcp.enabled` as the file says it, with an unset key (or no file)
/// following `agents.cmuxMcp`: `Some(true)` while that is on (the default),
/// `None` when it is `off`, so the caller can tell "not set" from `false`; an
/// unreadable file or a non-boolean value is an error the caller reports,
/// so a typo never turns the server on.
pub(super) fn setting(path: &Path) -> Result<Option<bool>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    setting_in(&text).map_err(|error| format!("{}: {error}", path.display()))
}

#[cfg(test)]
pub(super) fn enabled_in(text: &str) -> Result<bool, String> {
    setting_in(text).map(|value| value.unwrap_or(false))
}

fn setting_in(text: &str) -> Result<Option<bool>, String> {
    // A BOM or a file of only comments reads as empty, as the settings owner reads it.
    let stripped = strip_jsonc(text.trim_start_matches('\u{feff}'));
    let document: Value = if stripped.trim().is_empty() {
        Value::Null
    } else {
        serde_json::from_str(&stripped)
            .map_err(|error| format!("cmux.json is not valid JSONC: {error}"))?
    };
    match document.get("mcp").and_then(|mcp| mcp.get("enabled")) {
        None | Some(Value::Null)
            if cmux_tui_core::user_settings::AgentsCmuxMcp::from_config_text(text)
                == cmux_tui_core::user_settings::AgentsCmuxMcp::On =>
        {
            Ok(Some(true))
        }
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(enabled)) => Ok(Some(*enabled)),
        Some(_) => Err("mcp.enabled must be true or false".into()),
    }
}
