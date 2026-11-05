//! The text rules of a sidebar row: folders as a shell prompt writes them,
//! a terminal titled by its own folder, the status line and the daemon's
//! next default workspace name (moved from the app's `SidebarMapping`,
//! behavior unchanged).
//!
//! Strings compare as bytes. Swift compared them by canonical equivalence,
//! so a title and a folder that are the same text in two Unicode normal
//! forms (NFC and NFD) were equal there and differ here; both come from the
//! same file system bytes in practice.

use std::borrow::Cow;

/// The status entry key that feeds the row's ports element, not the status
/// line (`cmux workspace status set ports <text>`).
pub const PORTS_KEY: &str = "ports";
/// The status entry key that feeds the row's pull request element.
pub const PULL_REQUEST_KEY: &str = "pr";
/// The prefix of the daemon's default workspace names (`workspace-N`).
pub const DEFAULT_NAME_PREFIX: &str = "workspace-";
/// Shell names a terminal reports as its title while idle
/// (`NewWorkspaceName`'s list), and the home folder.
pub const BARE_SHELLS: [&str; 11] =
    ["zsh", "bash", "fish", "sh", "nu", "dash", "ksh", "tcsh", "pwsh", "login", "~"];

/// Swift's `CharacterSet.whitespaces`: tab and the space separators (Zs).
fn is_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// `text` without leading and trailing tabs and spaces
/// (`trimmingCharacters(in: .whitespaces)`).
pub fn trim_whitespace(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}

/// A folder of this Mac with its home folder `home` as `~`.
pub fn abbreviate<'a>(path: &'a str, home: &str) -> Cow<'a, str> {
    if path == home {
        return Cow::Borrowed("~");
    }
    match path.strip_prefix(home) {
        Some(rest) if rest.starts_with('/') => Cow::Owned(format!("~{rest}")),
        _ => Cow::Borrowed(path),
    }
}

/// A folder of another computer (SSH, Cloud) as its shell prompt writes it:
/// its account's home (`/Users/<name>` or `/home/<name>`) as `~`. The app
/// does not know that machine's home otherwise, and this Mac's home says
/// nothing about it (cx-gaq9).
pub fn abbreviate_remote(path: &str) -> Cow<'_, str> {
    let mut parts = path.split('/');
    let (Some(""), Some(root), Some(user)) = (parts.next(), parts.next(), parts.next()) else {
        return Cow::Borrowed(path);
    };
    if !(root == "Users" || root == "home") || user.is_empty() || user == "Shared" {
        return Cow::Borrowed(path);
    }
    // What follows `/<root>/<user>`: nothing, or `/` and the rest.
    let rest = path.get(1 + root.len() + 1 + user.len()..).unwrap_or_default();
    Cow::Owned(format!("~{rest}"))
}

/// A folder as its machine's prompt writes it: this Mac's against `home`,
/// another computer's against its account's home (`abbreviate_remote`).
pub fn shorten<'a>(path: &'a str, local: bool, home: &str) -> Cow<'a, str> {
    if local { abbreviate(path, home) } else { abbreviate_remote(path) }
}

/// `path` without one trailing `/`, unless it is `/` itself.
pub fn trim_slash(path: &str) -> &str {
    path.strip_suffix('/').filter(|_| path.len() > 1).unwrap_or(path)
}

/// The status line: every entry's text but the ones other elements show
/// (ports, pull request) and the empty ones, joined with ` · `.
pub fn entries_status_line(entries: &[Entry<'_>]) -> Option<String> {
    let texts: Vec<&str> = entries
        .iter()
        .filter(|entry| is_status_entry(entry.key) && !entry.text.is_empty())
        .map(|entry| entry.text)
        .collect();
    if texts.is_empty() { None } else { Some(texts.join(" · ")) }
}

/// The row's second line: the hooks' status line (`set_status`), else the
/// daemon's workspace status entries' (`entries_status_line`); none when
/// that is empty. An empty hooks' line hides the entries' line.
pub fn status_line<'a>(hooks: Option<&'a str>, entries: &[Entry<'_>]) -> Option<Cow<'a, str>> {
    let line = match hooks {
        Some(line) => Cow::Borrowed(line),
        None => Cow::Owned(entries_status_line(entries)?),
    };
    if line.is_empty() { None } else { Some(line) }
}

/// Whether an entry shows in the status line and the status block (every
/// key but the ports and pull request ones).
pub fn is_status_entry(key: &str) -> bool {
    key != PORTS_KEY && key != PULL_REQUEST_KEY
}

/// The index of the first entry with `key` and a text.
pub fn entry(key: &str, entries: &[Entry<'_>]) -> Option<usize> {
    entries.iter().position(|entry| entry.key == key && !entry.text.is_empty())
}

/// One daemon workspace status entry (`WorkspaceStatus.Entry`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry<'a> {
    pub key: &'a str,
    pub text: &'a str,
}

/// The `N` of a `workspace-N` name: ASCII digits only, in range.
fn default_name_number(name: &str) -> Option<i64> {
    let digits = name.strip_prefix(DEFAULT_NAME_PREFIX)?;
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// The daemon's default for the next workspace (`workspace-N`): one more
/// than the highest `workspace-N` name and than the count of workspaces.
/// `existing` are the machine's listed workspace names (its home left out);
/// `reserved` are the names given to creates the daemon has not listed yet,
/// so a key-repeat burst numbers each create once, in press order. A
/// reserved name the machine lists already counts once.
pub fn default_workspace_name(existing: &[&str], reserved: &[&str]) -> String {
    let unlisted: Vec<&str> =
        reserved.iter().filter(|name| !existing.contains(name)).copied().collect();
    let highest =
        existing.iter().chain(&unlisted).filter_map(|name| default_name_number(name)).max();
    let count = i64::try_from(existing.len() + unlisted.len()).unwrap_or(i64::MAX);
    let next = highest.unwrap_or(0).max(count).saturating_add(1);
    format!("{DEFAULT_NAME_PREFIX}{next}")
}
