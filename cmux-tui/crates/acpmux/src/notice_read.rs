//! A tool's notice read back from its text alone: the head `prompt_provenance::notice_text`
//! renders (`[notice from SENDER on HOST · FIRE] TITLE`, the body, `Links: URL (LABEL), …`),
//! when it came with no notice provenance: relayed by the lane-gh broker, by a peer, or sent by
//! an older client. A chat then draws it as the notice it is (its detector's name, its severity,
//! its title), never the relay host and the raw head (Leo, 2026-11-25, on such rows: "how can we
//! improve this?"), and a repeat of one condition folds into the earlier one ([`condition_key`]).
//! The web draws what this reads (webviews inboxNotice.ts `notice`); it parses no head itself.
use serde_json::{Value, json};

use crate::prompt_provenance::{MAX_NOTICE_LINKS, MAX_NOTICE_TITLE_CHARS};

/// The longest sender or host a head names, as the web's reader takes (agentNotice.ts).
const MAX_NAME_CHARS: usize = 64;

/// The notice `text` renders, past a peer's `From another agent (…)…:` line and the lane-gh
/// broker's label: `{sender, host?, severity, title, links, key, read: true}`; None when its
/// first line is no notice head.
pub fn read(text: &str) -> Option<Value> {
    let text = crate::hub::inbox::relay_body(without_peer_line(text.trim())).trim();
    let mut lines = text.lines();
    let (sender, host, severity, title) = head(lines.next()?)?;
    let links: Vec<Value> = text
        .lines()
        .skip(1)
        .last()
        .and_then(|l| l.trim().strip_prefix("Links: "))
        .map(links_of)
        .unwrap_or_default();
    let mut notice = json!({
        "sender": sender, "severity": severity, "title": title, "links": links,
        "key": condition_key(sender, title), "read": true,
    });
    if let Some(host) = host {
        notice["host"] = json!(host);
    }
    Some(notice)
}

/// The condition a notice reports, so a repeat of it folds whatever its counts say now: its
/// sender and title, lowercased, every run of digits one `#`, whitespace one space.
/// `now` · "Runner label stalled: trusted xcode-27.2, 9 queued" and the same with 12 queued
/// are one condition; another label is another.
pub fn condition_key(sender: &str, title: &str) -> String {
    let mut key = format!("{}\n", sender.trim().to_lowercase());
    let mut digit = false;
    let mut space = false;
    for c in title.trim().chars().flat_map(char::to_lowercase) {
        if c.is_ascii_digit() {
            if !digit {
                key.push('#');
            }
            digit = true;
            space = false;
            continue;
        }
        digit = false;
        if c.is_whitespace() {
            if !space {
                key.push(' ');
            }
            space = true;
            continue;
        }
        space = false;
        key.push(c);
    }
    key
}

/// `text` past a peer's lead line (`From another agent (NAME), not the person:`, hub/bridge.rs).
fn without_peer_line(text: &str) -> &str {
    match text.split_once('\n') {
        Some((first, rest))
            if first.starts_with("From another agent (") && first.ends_with(':') =>
        {
            rest.trim_start()
        }
        _ => text,
    }
}

fn name_ok(s: &str, extra: &[char]) -> bool {
    (1..=MAX_NAME_CHARS).contains(&s.len())
        && s.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c) || extra.contains(&c))
}

/// `[notice from SENDER( on HOST)?( · FIRE| · WARN)?] TITLE`: the web's `RENDERED_HEAD`.
fn head(line: &str) -> Option<(&str, Option<&str>, &'static str, &str)> {
    let rest = line.trim_end().strip_prefix("[notice from ")?;
    let (tag, title) = rest.split_once("] ")?;
    let title = title.trim();
    if title.is_empty() || title.chars().count() > MAX_NOTICE_TITLE_CHARS {
        return None;
    }
    let (tag, severity) = match tag.rsplit_once(" · ") {
        Some((tag, "FIRE")) => (tag, "fire"),
        Some((tag, "WARN")) => (tag, "warn"),
        Some(_) => return None,
        None => (tag, "info"),
    };
    let (sender, host) = match tag.split_once(" on ") {
        Some((sender, host)) => (sender, Some(host)),
        None => (tag, None),
    };
    if !name_ok(sender, &['@', '/', ':']) || host.is_some_and(|h| !name_ok(h, &[])) {
        return None;
    }
    Some((sender, host, severity, title))
}

/// The Links line's links: `, `-separated, each starting `https://`, a label in parentheses.
fn links_of(line: &str) -> Vec<Value> {
    let mut parts: Vec<&str> = Vec::new();
    let mut rest = line.trim();
    while let Some(at) = rest.get(2..).and_then(|r| r.find(", https://")) {
        parts.push(&rest[..at + 2]);
        rest = &rest[at + 4..];
    }
    parts.push(rest);
    parts
        .into_iter()
        .filter(|p| p.starts_with("https://"))
        .take(MAX_NOTICE_LINKS)
        .map(|p| match p.split_once(" (") {
            Some((url, label)) if label.ends_with(')') => {
                json!({"url": url, "label": &label[..label.len() - 1]})
            }
            _ => json!({"url": p}),
        })
        .collect()
}

#[cfg(test)]
#[path = "notice_read_tests.rs"]
mod tests;
