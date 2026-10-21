//! What a harness's pending versions bring (`_acpmux/harness/changelog`):
//! the harness's own published changelog, parsed into one entry per version
//! (newest first) with its date when it names one and its bullet items as
//! markdown lines. Claude Code publishes `CHANGELOG.md` in
//! anthropics/claude-code (`## x.y.z` sections); Codex publishes GitHub
//! releases of openai/codex (`rust-v<version>` tags). Any other family has
//! no source, and the reply has no entries. Fetching and the saved copy live
//! in `changelog_fetch.rs`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::probe::compare_versions;

/// One version's changes.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub version: String,
    /// `YYYY-MM-DD`, when the changelog names it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    /// One markdown line per bullet, without its marker.
    pub items: Vec<String>,
}

/// How a published changelog is written.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    /// A `CHANGELOG.md` with one `## <version>` section per version.
    Markdown,
    /// The GitHub releases API's JSON list; `prefix` is the tag's text before the version.
    Releases { prefix: &'static str },
}

/// Where a family's changelog is fetched from. The daemon uses
/// [`Sources::public`]; tests point both at a loopback server (a debug build
/// only, see `changelog_fetch.rs`).
#[derive(Clone, Debug)]
pub struct Sources {
    /// Claude Code's raw `CHANGELOG.md`.
    pub claude: String,
    /// The GitHub releases API of openai/codex.
    pub codex: String,
}

impl Sources {
    pub fn public() -> Self {
        Self {
            claude: "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"
                .into(),
            codex: "https://api.github.com/repos/openai/codex/releases?per_page=30".into(),
        }
    }
}

/// A family's published changelog: how it is written and the page a person reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Published {
    pub format: Format,
    /// The full changelog for a person (the reply's `source`).
    pub page: &'static str,
}

/// The changelog `family` publishes, if acpmux knows one.
pub fn published(family: &str) -> Option<Published> {
    match family {
        "claude" => Some(Published {
            format: Format::Markdown,
            page: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md",
        }),
        "codex" => Some(Published {
            format: Format::Releases { prefix: "rust-v" },
            page: "https://github.com/openai/codex/releases",
        }),
        _ => None,
    }
}

/// The URL `family`'s changelog is fetched from.
pub fn fetch_url<'a>(family: &str, sources: &'a Sources) -> Option<&'a str> {
    match family {
        "claude" => Some(&sources.claude),
        "codex" => Some(&sources.codex),
        _ => None,
    }
}

/// Bounds on what one changelog keeps: versions, items per version, and characters per item.
pub const MAX_ENTRIES: usize = 300;
const MAX_ITEMS: usize = 40;
const MAX_ITEM_CHARS: usize = 600;

/// Parses `body` as `format` wrote it: entries newest first.
pub fn parse(format: Format, body: &str) -> Vec<Entry> {
    match format {
        Format::Markdown => parse_markdown(body),
        Format::Releases { prefix } => serde_json::from_str::<Value>(body)
            .map(|json| parse_releases(&json, prefix))
            .unwrap_or_default(),
    }
}

/// A `CHANGELOG.md`: each `## <version>` heading (`## 2.1.3`, `## [2.1.3] - 2025-10-01`,
/// `## v2.1.3 (2025-10-01)`) starts an entry; its bullets are the items. A heading that names no
/// version (`## Unreleased`) and its bullets are skipped.
pub fn parse_markdown(text: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = Vec::new();
    let mut open = false;
    for line in text.lines() {
        if let Some(heading) = line.strip_prefix("## ") {
            if entries.len() >= MAX_ENTRIES {
                break;
            }
            open = match heading_version(heading) {
                Some((version, date)) => {
                    entries.push(Entry { version, date, items: Vec::new() });
                    true
                }
                None => false,
            };
            continue;
        }
        if line.starts_with("# ") {
            open = false;
            continue;
        }
        let Some(entry) = entries.last_mut().filter(|_| open) else { continue };
        bullet_line(&mut entry.items, line);
    }
    entries
}

/// The GitHub releases API's list: each published, non-prerelease release whose tag is
/// `<prefix><version>` (or `v<version>`) is an entry dated by its publication; its body's bullets
/// are the items. Newest version first.
pub fn parse_releases(json: &Value, prefix: &str) -> Vec<Entry> {
    let mut entries: Vec<Entry> = json
        .as_array()
        .into_iter()
        .flatten()
        .filter(|r| r["draft"] != true && r["prerelease"] != true)
        .filter_map(|r| {
            let tag = r["tag_name"].as_str()?;
            let version = tag.strip_prefix(prefix).or_else(|| tag.strip_prefix('v'))?;
            // A release candidate or alpha tag (`0.47.0-alpha.1`) is not a version people get.
            if version.contains('-') || compare_versions(version, version).is_none() {
                return None;
            }
            let date = r["published_at"].as_str().and_then(|d| d.get(..10)).filter(|d| is_date(d));
            let mut items = Vec::new();
            for line in r["body"].as_str().unwrap_or("").lines() {
                bullet_line(&mut items, line);
            }
            Some(Entry { version: version.to_owned(), date: date.map(str::to_owned), items })
        })
        .collect();
    entries.sort_by(|a, b| {
        compare_versions(&b.version, &a.version).unwrap_or(std::cmp::Ordering::Equal)
    });
    entries.truncate(MAX_ENTRIES);
    entries
}

/// The entries in `(from, to]`, newest first, at most `limit`. A bound that is None does not
/// limit; with a bound, a version that cannot be compared with it is left out.
pub fn range(entries: &[Entry], from: Option<&str>, to: Option<&str>, limit: usize) -> Vec<Entry> {
    use std::cmp::Ordering::{Equal, Greater, Less};
    entries
        .iter()
        .filter(|e| from.is_none_or(|f| compare_versions(&e.version, f) == Some(Greater)))
        .filter(|e| {
            to.is_none_or(|t| matches!(compare_versions(&e.version, t), Some(Less | Equal)))
        })
        .take(limit)
        .cloned()
        .collect()
}

/// A heading's version and date: the first word that is a version (after `[`, `v`), and the first
/// `YYYY-MM-DD` after it.
fn heading_version(heading: &str) -> Option<(String, Option<String>)> {
    let mut words = heading.split_whitespace();
    let first = words.next()?;
    let version = first.trim_matches(|c| c == '[' || c == ']').trim_start_matches('v');
    if !version.starts_with(|c: char| c.is_ascii_digit())
        || !version.contains('.')
        || compare_versions(version, version).is_none()
    {
        return None;
    }
    let date = words
        .map(|w| w.trim_matches(|c: char| !c.is_ascii_digit()))
        .find(|w| is_date(w))
        .map(str::to_owned);
    Some((version.to_owned(), date))
}

fn is_date(text: &str) -> bool {
    let b = text.as_bytes();
    b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b.iter().enumerate().all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
}

/// Adds `line` to `items`: a bullet (`- `, `* `, `+ `, at any depth) is a new item; an indented
/// line after one continues it; anything else (a sub-heading, a blank line, prose) is skipped.
fn bullet_line(items: &mut Vec<String>, line: &str) {
    let trimmed = line.trim_start();
    let bullet = ["- ", "* ", "+ "].iter().find_map(|m| trimmed.strip_prefix(m));
    if let Some(text) = bullet {
        let text = text.trim();
        if !text.is_empty() && items.len() < MAX_ITEMS {
            items.push(capped(text));
        }
        return;
    }
    let indented = line.len() > trimmed.len();
    if indented && !trimmed.is_empty() && !trimmed.starts_with('#') {
        if let Some(last) = items.last_mut() {
            let joined = format!("{last} {}", trimmed.trim_end());
            *last = capped(&joined);
        }
    }
}

fn capped(text: &str) -> String {
    match text.char_indices().nth(MAX_ITEM_CHARS) {
        Some((at, _)) => format!("{}…", &text[..at]),
        None => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../../tests/fixtures/claude-changelog.md");

    #[test]
    fn markdown_sections_become_entries_newest_first() {
        let entries = parse_markdown(FIXTURE);
        let versions: Vec<&str> = entries.iter().map(|e| e.version.as_str()).collect();
        assert_eq!(versions, ["2.1.305", "2.1.304", "2.1.303", "2.1.300", "1.0.9"]);
        assert_eq!(
            entries[0].items,
            [
                "Added `/rewind` to go back to an earlier point in the chat",
                "Fixed a crash when a hook printed invalid JSON on a long line",
                "Nested detail under a bullet",
            ]
        );
        assert_eq!(entries[3].date.as_deref(), Some("2025-10-01"));
        assert_eq!(entries[4].date.as_deref(), Some("2025-06-30"));
        assert!(entries.iter().all(|e| !e.items.is_empty()), "{entries:?}");
    }

    #[test]
    fn range_keeps_versions_after_the_installed_one_up_to_the_newest() {
        let entries = parse_markdown(FIXTURE);
        let pending = range(&entries, Some("2.1.303"), Some("2.1.305"), 50);
        let versions: Vec<&str> = pending.iter().map(|e| e.version.as_str()).collect();
        assert_eq!(versions, ["2.1.305", "2.1.304"]);
        assert!(range(&entries, Some("2.1.305"), Some("2.1.305"), 50).is_empty());
        assert_eq!(range(&entries, None, None, 2).len(), 2, "limit bounds the reply");
        assert_eq!(range(&entries, Some("not a version"), None, 50), Vec::<Entry>::new());
    }

    #[test]
    fn releases_skip_prereleases_and_strip_the_tag_prefix() {
        let json = serde_json::json!([
            {"tag_name": "rust-v0.47.0-alpha.1", "prerelease": true, "body": "- alpha"},
            {"tag_name": "rust-v0.46.0", "published_at": "2025-10-14T18:00:00Z",
             "body": "## New Features\n- Faster startup\n* Better `/status`\n\n**Full Changelog**: x"},
            {"tag_name": "rust-v0.47.0", "published_at": "2025-10-16T18:00:00Z", "body": "- Fixes"},
            {"tag_name": "something-else", "body": "- no"},
        ]);
        let entries = parse_releases(&json, "rust-v");
        assert_eq!(
            entries,
            [
                Entry {
                    version: "0.47.0".into(),
                    date: Some("2025-10-16".into()),
                    items: vec!["Fixes".into()]
                },
                Entry {
                    version: "0.46.0".into(),
                    date: Some("2025-10-14".into()),
                    items: vec!["Faster startup".into(), "Better `/status`".into()],
                },
            ]
        );
    }

    #[test]
    fn only_known_families_have_a_changelog() {
        assert!(published("claude").is_some() && published("codex").is_some());
        assert_eq!(published("gemini"), None);
        assert_eq!(fetch_url("opencode", &Sources::public()), None);
    }
}
