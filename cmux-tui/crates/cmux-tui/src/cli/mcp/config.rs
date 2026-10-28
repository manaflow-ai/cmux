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

/// `mcp.enabled` as the file says it: `None` when the file or the key is
/// missing (or null), so the caller can tell "not set" from `false`; an
/// unreadable file or a non-boolean value is an error the caller reports,
/// so a typo never turns the server on.
pub(super) fn setting(path: &Path) -> Result<Option<bool>, String> {
    let text = match cmux_blocking::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    setting_in(&text).map_err(|error| format!("{}: {error}", path.display()))
}

#[cfg(test)]
pub(super) fn enabled_in(text: &str) -> Result<bool, String> {
    setting_in(text).map(|value| value.unwrap_or(false))
}

fn setting_in(text: &str) -> Result<Option<bool>, String> {
    if text.trim().is_empty() {
        return Ok(None);
    }
    let document: Value = serde_json::from_str(&strip_jsonc(text))
        .map_err(|error| format!("cmux.json is not valid JSONC: {error}"))?;
    match document.get("mcp").and_then(|mcp| mcp.get("enabled")) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(enabled)) => Ok(Some(*enabled)),
        Some(_) => Err("mcp.enabled must be true or false".into()),
    }
}

/// The env acpmux gives the cmux MCP server of an agent chat
/// (`CMUX_AGENT_SESSION`, acpmux `agent_tools.rs`).
const AGENT_SESSION_ENV: &str = "CMUX_AGENT_SESSION";

/// Why `serve` must not run with the settings file at `path`, or `None`
/// when cmux.json turns the server on. An agent chat that cmux started
/// (`CMUX_AGENT_SESSION` set) has it on unless the file says `false`
/// (cx-wx93i, Lawrence 2026-10-14: every agent chat gets the cmux MCP tools
/// by default); any other client needs `"mcp": {"enabled": true}`. The env
/// is no security boundary: the same process can run the cmux CLI.
pub(in crate::cli) fn refusal(path: &Path) -> Option<String> {
    let agent_chat =
        super::super::caller_env::var_os(AGENT_SESSION_ENV).is_some_and(|v| !v.is_empty());
    refusal_for(path, agent_chat)
}

/// The settings file, and whether it turns `serve` on for a client outside
/// a cmux agent chat (Claude Code or Codex started in a terminal), or why
/// it cannot be read (`cmux setup mcp`).
pub(in crate::cli) fn outside_chats() -> (PathBuf, Result<bool, String>) {
    let path = path();
    let on = setting(&path).map(|setting| setting == Some(true));
    (path, on)
}

fn refusal_for(path: &Path, agent_chat: bool) -> Option<String> {
    let messages = super::messages::messages();
    match setting(path) {
        Ok(Some(true)) => None,
        Ok(None) if agent_chat => None,
        Ok(_) => Some(messages.disabled.replace("{path}", &path.display().to_string())),
        Err(error) => Some(messages.config_invalid.replace("{error}", &error)),
    }
}
