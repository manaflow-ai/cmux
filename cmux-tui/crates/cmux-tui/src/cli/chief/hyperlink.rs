//! Terminal hyperlinks (OSC 8) in the Chief's replies. Three forms are links:
//! - a subagent link `[a1](cmux://chief/<home id>/session/<session id>)` (optchat-chief
//!   `link_subagents`): a Cmd-click in any terminal opens the subagent through the cmux app's
//!   `link.open` (Lawrence 2026-10-10);
//! - a Markdown web link `[label](https://…)`: the label is the link, the target is hidden;
//! - a bare web URL `https://…`: the URL is its own link (Lawrence 2026-10-14, "make sure chief
//!   renders URLs when it makes sense to", cx-ebm.59.1).
//!
//! Only http, https and the subagent form are links; a target with a control byte, a space or a
//! backslash never is (it could end the escape early). Everything else prints as written. Plain
//! text when stdout is not a terminal, NO_COLOR is set or TERM is dumb.

use std::io::IsTerminal;

/// The longest target written as a hyperlink; a longer one prints as written.
const MAX_URL: usize = 2048;
/// The shortest piece of a wrapped bare URL that is linked on its own line.
const MIN_PIECE: usize = 8;

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

/// Whether `url` is a web URL that may be written inside an escape: http or https with a host,
/// printable ASCII only, no space and no backslash.
fn is_web_link(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://")) else {
        return false;
    };
    url.len() <= MAX_URL
        && rest.bytes().next().is_some_and(|b| b.is_ascii_alphanumeric() || b == b'[')
        && url.bytes().all(|b| b.is_ascii_graphic() && b != b'\\')
}

/// Whether `label` is a subagent id: `a` and 1 to 6 digits.
fn is_id(label: &str) -> bool {
    label
        .strip_prefix('a')
        .is_some_and(|d| (1..=6).contains(&d.len()) && d.bytes().all(|b| b.is_ascii_digit()))
}

/// A link found in a reply: the bytes `start..end` of the text, shown as `label`, to `url`.
struct Found<'a> {
    end: usize,
    label: &'a str,
    url: &'a str,
}

/// The Markdown link `[label](url)` at the start of `text`, when it is one of the linked forms.
fn markdown_link(text: &str) -> Option<Found<'_>> {
    let after = text.strip_prefix('[')?;
    let (label, tail) = after.split_once("](")?;
    if label.is_empty() || label.contains(['\n', '[', ']']) {
        return None;
    }
    // The target ends at the `)` that closes the link: parentheses inside it must balance
    // (a Wikipedia URL); a space or line break means it is not a link.
    let mut depth = 0usize;
    let mut end = None;
    for (index, c) in tail.char_indices() {
        match c {
            '(' => depth += 1,
            ')' if depth == 0 => {
                end = Some(index);
                break;
            }
            ')' => depth -= 1,
            c if c.is_whitespace() => return None,
            _ => {}
        }
    }
    let (url, _) = tail.split_at_checked(end?)?;
    let linked = if is_subagent_link(url) { is_id(label) } else { is_web_link(url) };
    // `[` label `](` url `)`
    linked.then(|| Found { end: 1 + label.len() + 2 + url.len() + 1, label, url })
}

/// The bare web URL at the start of `text`: up to a space, a quote, `<`, `>` or a backtick,
/// without the sentence's trailing punctuation or a `)`/`]` it did not open.
fn bare_url(text: &str) -> Option<Found<'_>> {
    if !(text.starts_with("https://") || text.starts_with("http://")) {
        return None;
    }
    let mut url = text
        .split(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '<' | '>' | '`'))
        .next()
        .unwrap_or(text);
    loop {
        let trimmed = url.trim_end_matches(['.', ',', ';', ':', '!', '?', '*', '_']);
        // A closing bracket the URL did not open ends the sentence, not the URL.
        let trimmed = [('(', ')'), ('[', ']')]
            .into_iter()
            .find(|&(open, close)| {
                trimmed.ends_with(close)
                    && trimmed.matches(open).count() < trimmed.matches(close).count()
            })
            .and_then(|(_, close)| trimmed.strip_suffix(close))
            .unwrap_or(trimmed);
        if trimmed.len() == url.len() {
            break;
        }
        url = trimmed;
    }
    is_web_link(url).then_some(Found { end: url.len(), label: url, url })
}

/// Whether `c` belongs to a word (a bare URL glued to a word is not one).
fn word(c: char) -> bool {
    c.is_alphanumeric() || c == '_' || c == '/'
}

/// `text` with each link replaced by `write(label, url)`, and the links found (label, url).
#[allow(
    clippy::string_slice,
    reason = "INVARIANT: index and copied are char boundaries of text: each step adds a char's len_utf8, a run of ASCII backticks plus a find inside it, or the byte length of a link parsed from it"
)]
fn replace(text: &str, write: impl Fn(&str, &str) -> String) -> (String, Vec<(String, String)>) {
    let mut out = String::with_capacity(text.len());
    let mut found = Vec::new();
    let mut copied = 0;
    let mut index = 0;
    while index < text.len() {
        let rest = &text[index..];
        // Code (a `span` or a fenced block) is shown as written: its links stay text.
        if rest.starts_with('`') {
            let fence = rest.len() - rest.trim_start_matches('`').len();
            let close =
                rest[fence..].find(&rest[..fence]).map_or(rest.len(), |at| fence + at + fence);
            index += close;
            continue;
        }
        let glued = text[..index].chars().next_back().is_some_and(word);
        let link = markdown_link(rest).or_else(|| if glued { None } else { bare_url(rest) });
        if let Some(link) = link {
            out.push_str(&text[copied..index]);
            out.push_str(&write(link.label, link.url));
            found.push((link.label.to_owned(), link.url.to_owned()));
            index += link.end;
            copied = index;
            continue;
        }
        index += rest.chars().next().map_or(1, char::len_utf8);
    }
    out.push_str(&text[copied..]);
    (out, found)
}

/// `text` with each link written as an OSC 8 hyperlink on its label.
pub(super) fn render(text: &str) -> String {
    replace(text, |label, url| osc8(url, label)).0
}

/// `text` with each link shown as its label, and the links (label, url), so a view that wraps by
/// display width can add the hyperlinks when it prints (`mark`).
pub(super) fn split(text: &str) -> (String, Vec<(String, String)>) {
    replace(text, |label, _| label.to_owned())
}

/// `line`, one wrapped line of a message, with each label of that message's `links` that stands
/// alone (not inside a longer word) written as its hyperlink. A bare URL the view hard-broke over
/// lines (`render::wrap` starts it on a new line) links each of its pieces to the whole URL: a
/// piece that fills its line, and the last piece that starts one.
#[allow(
    clippy::string_slice,
    reason = "INVARIANT: index and copied are char boundaries of line: each step adds a char's len_utf8 or the byte length of a label match_at found starting there"
)]
pub(super) fn mark(line: &str, links: &[(String, String)]) -> String {
    if links.is_empty() {
        return line.to_owned();
    }
    let mut out = String::with_capacity(line.len());
    let mut copied = 0;
    let mut index = 0;
    while index < line.len() {
        if let Some((len, url)) = match_at(line, index, links) {
            out.push_str(&line[copied..index]);
            out.push_str(&osc8(url, &line[index..index + len]));
            index += len;
            copied = index;
            continue;
        }
        index += line[index..].chars().next().map_or(1, char::len_utf8);
    }
    out.push_str(&line[copied..]);
    out
}

/// The link that starts at byte `index` of `line`: its length there and its URL. The newest
/// link wins a tie, so a label used twice links to the latest target.
#[allow(
    clippy::string_slice,
    reason = "INVARIANT: mark passes a char boundary index; rest[label.len()..] follows a starts_with(label) check, and run ends at a find on rest"
)]
fn match_at<'a>(
    line: &str,
    index: usize,
    links: &'a [(String, String)],
) -> Option<(usize, &'a str)> {
    let rest = &line[index..];
    let before = line[..index].chars().next_back();
    let free_before = |label: &str| !(label.starts_with(word) && before.is_some_and(word));
    let free_after = |label: &str| {
        !(label.ends_with(word) && rest[label.len()..].chars().next().is_some_and(word))
    };
    // `max_by_key` keeps the last of the longest: the newest link.
    let whole = links
        .iter()
        .filter(|(label, _)| {
            !label.is_empty()
                && rest.starts_with(label.as_str())
                && free_before(label)
                && free_after(label)
        })
        .max_by_key(|(label, _)| label.len());
    if let Some((label, url)) = whole {
        return Some((label.len(), url.as_str()));
    }
    // A piece of a wrapped bare URL starts the line's text: the whole line inside the URL (its
    // first or a middle piece), or its last piece, without the punctuation after it.
    if !line[..index].trim().is_empty() {
        return None;
    }
    let run = &rest[..rest.find(char::is_whitespace).unwrap_or(rest.len())];
    let fills = run.len() == rest.len();
    let last = run.trim_end_matches(['.', ',', ';', ':', '!', '?', '*', '_', ')', ']']);
    let piece = |url: &'a String| {
        if fills && run.len() >= MIN_PIECE && url.len() > run.len() && url.contains(run) {
            Some((run.len(), url.as_str()))
        } else if last.len() >= MIN_PIECE && url.len() > last.len() && url.ends_with(last) {
            Some((last.len(), url.as_str()))
        } else {
            None
        }
    };
    links.iter().rev().filter(|(label, url)| label == url).find_map(|(_, url)| piece(url))
}
