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

/// The settings file's text, or `None` when there is none to read.
pub fn text() -> Option<String> {
    let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty());
    let home = || var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    if let Some(path) = var(CONFIG_OVERRIDE) {
        let path = PathBuf::from(path);
        let path = match path.strip_prefix("~") {
            Ok(rest) => home().join(rest),
            Err(_) => path,
        };
        return std::fs::read_to_string(path).ok();
    }
    let home = home();
    std::fs::read_to_string(home.join(".config/cmux/cmux-next.json"))
        .or_else(|_| std::fs::read_to_string(home.join(".config/cmux/cmux.json")))
        .ok()
}

/// The settings document (JSONC: whole-line `//` comments allowed), or
/// `None` when it does not parse.
pub fn document(text: &str) -> Option<Value> {
    let plain: String = text
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");
    serde_json::from_str::<Value>(&plain).ok()
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
