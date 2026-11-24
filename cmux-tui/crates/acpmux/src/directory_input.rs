//! A `cd` argument resolved against a base folder (a session's, never a client process's cwd),
//! and a folder's child folders. The daemon's directory requests (`server/requests.rs`) and the
//! TUI's `cd` (`tui/directory.rs`) share it, so it stays in the headless build.
use anyhow::Result;
use std::path::{Path, PathBuf};

pub fn cd_argument(text: &str) -> Option<&str> {
    let text = text.trim();
    if text == "cd" {
        return Some("");
    }
    let rest = text.strip_prefix("cd ").or_else(|| text.strip_prefix("cd\t"))?.trim();
    if rest.contains(['\n', '\r', ';', '|', '&', '`']) || rest.contains("$(") {
        return None;
    }
    Some(rest)
}
/// The value without surrounding whitespace and one pair of matching quotes.
pub fn unquote(value: &str) -> &str {
    let value = value.trim();
    ['"', '\'']
        .into_iter()
        .find_map(|quote| value.strip_prefix(quote)?.strip_suffix(quote))
        .unwrap_or(value)
}
pub fn resolve(base: &Path, value: &str, home: &Path, previous: Option<&str>) -> Result<PathBuf> {
    let value = unquote(value);
    let path = match value {
        "-" => PathBuf::from(previous.ok_or_else(|| anyhow::anyhow!("No previous directory yet"))?),
        "~" => home.to_owned(),
        "" => base.to_owned(),
        s if s.starts_with("~/") => home.join(s.get(2..).unwrap_or_default()),
        s => base.join(s),
    };
    Ok(path)
}
pub fn children(path: &Path) -> Vec<PathBuf> {
    let mut entries: Vec<_> = std::fs::read_dir(path)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    entries.sort();
    entries
}
