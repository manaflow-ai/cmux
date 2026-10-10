//! Terminal hyperlinks (OSC 8) for the Chief's subagent links. The Chief's posted reply names
//! each subagent as `[a1](cmux://chief/<home id>/session/<session id>)` (optchat-chief
//! `link_subagents`); on a terminal the label becomes a hyperlink to that URL, so a Cmd-click in
//! any terminal opens the subagent through the cmux app's `link.open` (Lawrence 2026-10-10).
//! Only that exact form: every other link prints as written. Plain text when stdout is not a
//! terminal, NO_COLOR is set or TERM is dumb.

use std::io::IsTerminal;

/// Whether stdout takes hyperlinks.
pub(super) fn enabled() -> bool {
    std::io::stdout().is_terminal()
        && std::env::var_os("NO_COLOR").is_none()
        && std::env::var("TERM").map_or(true, |term| term != "dumb")
}

/// `label` as an OSC 8 hyperlink to `url`.
pub(super) fn osc8(url: &str, label: &str) -> String {
    format!("\x1b]8;;{url}\x1b\\{label}\x1b]8;;\x1b\\")
}

/// Whether `url` is a Chief subagent link: `cmux://chief/<8 lowercase hex>/session/<token>`.
fn is_subagent_link(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("cmux://chief/") else { return false };
    let Some((home, session)) = rest.split_once("/session/") else { return false };
    home.len() == 8
        && home.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && (1..=200).contains(&session.len())
        && session.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// Whether `label` is a subagent id: `a` and 1 to 6 digits.
fn is_id(label: &str) -> bool {
    label
        .strip_prefix('a')
        .is_some_and(|d| (1..=6).contains(&d.len()) && d.bytes().all(|b| b.is_ascii_digit()))
}

/// `text` with each subagent link `[a1](url)` replaced by `label(a1, url)`, and the links found.
fn replace(text: &str, label: impl Fn(&str, &str) -> String) -> (String, Vec<(String, String)>) {
    let mut out = String::with_capacity(text.len());
    let mut found = Vec::new();
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        let after = &rest[open + 1..];
        let link = after.find("](").and_then(|close| {
            let id = &after[..close];
            let tail = &after[close + 2..];
            let end = tail.find(')')?;
            let url = &tail[..end];
            (is_id(id) && is_subagent_link(url)).then(|| (id, url, open + 1 + close + 2 + end + 1))
        });
        match link {
            Some((id, url, consumed)) => {
                out.push_str(&rest[..open]);
                out.push_str(&label(id, url));
                found.push((id.to_owned(), url.to_owned()));
                rest = &rest[consumed..];
            }
            None => {
                out.push_str(&rest[..open + 1]);
                rest = &rest[open + 1..];
            }
        }
    }
    out.push_str(rest);
    (out, found)
}

/// `text` with each subagent link written as an OSC 8 hyperlink on its label.
pub(super) fn render(text: &str) -> String {
    replace(text, |id, url| osc8(url, id)).0
}

/// `text` with each subagent link shown as its label, and the links (label, url), so a view
/// that wraps by display width can add the hyperlinks when it prints (`mark`).
pub(super) fn split(text: &str) -> (String, Vec<(String, String)>) {
    replace(text, |id, _| id.to_owned())
}

/// `line` with each whole-word label of `links` written as its hyperlink.
pub(super) fn mark(line: &str, links: &[(String, String)]) -> String {
    if links.is_empty() {
        return line.to_owned();
    }
    let word = |c: char| c.is_alphanumeric() || c == '_';
    let mut out = String::with_capacity(line.len());
    let mut chars = line.char_indices().peekable();
    let mut copied = 0;
    while let Some((i, c)) = chars.next() {
        if c != 'a' || line[..i].chars().next_back().is_some_and(word) {
            continue;
        }
        let end =
            line[i + 1..].find(|c: char| !c.is_ascii_digit()).map_or(line.len(), |e| i + 1 + e);
        if line[end..].chars().next().is_some_and(word) {
            continue;
        }
        if let Some((label, url)) = links.iter().rev().find(|(label, _)| label == &line[i..end]) {
            out.push_str(&line[copied..i]);
            out.push_str(&osc8(url, label));
            copied = end;
            while chars.peek().is_some_and(|(j, _)| *j < end) {
                chars.next();
            }
        }
    }
    out.push_str(&line[copied..]);
    out
}
