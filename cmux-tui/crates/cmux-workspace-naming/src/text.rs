//! The text rules every name shares, with Swift's semantics: lengths and prefixes count grapheme
//! clusters (Swift `Character`s), newlines are `Character.isNewline`, trimming is Foundation's
//! `whitespacesAndNewlines`.

use unicode_segmentation::UnicodeSegmentation;

/// The most characters a workspace name keeps (`NewWorkspaceName.maxLength`).
pub const MAX_LENGTH: usize = 80;

/// Swift's `Character.isNewline`.
fn is_newline(grapheme: &str) -> bool {
    matches!(
        grapheme,
        "\n" | "\r" | "\r\n" | "\u{0B}" | "\u{0C}" | "\u{85}" | "\u{2028}" | "\u{2029}"
    )
}

/// Swift's `Character.isWhitespace`: its first scalar is Unicode white space.
fn is_whitespace(grapheme: &str) -> bool {
    grapheme.chars().next().is_some_and(char::is_whitespace)
}

/// Foundation's `CharacterSet.whitespaces` (space separators and tab).
pub(crate) fn is_horizontal_space(c: char) -> bool {
    c.is_whitespace()
        && !matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// `text.split(whereSeparator:)` with empty pieces dropped, joined by one space.
fn split_join(text: &str, separator: fn(&str) -> bool) -> String {
    let mut out = String::with_capacity(text.len());
    let mut piece = false;
    let mut pending = false;
    for grapheme in text.graphemes(true) {
        if separator(grapheme) {
            pending = piece;
            continue;
        }
        if pending {
            out.push(' ');
            pending = false;
        }
        out.push_str(grapheme);
        piece = true;
    }
    out
}

/// The first `count` grapheme clusters of `text`.
pub(crate) fn prefix(text: &str, count: usize) -> &str {
    match text.grapheme_indices(true).nth(count) {
        Some((end, _)) => text.get(..end).unwrap_or(text),
        None => text,
    }
}

/// The number of grapheme clusters (Swift's `String.count`).
pub fn char_count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// One line, trimmed, at most [`MAX_LENGTH`] characters; `None` when empty
/// (`NewWorkspaceName.clean`).
pub fn clean(raw: Option<&str>) -> Option<String> {
    let line = split_join(raw?, is_newline);
    let line = line.trim_matches(char::is_whitespace);
    (!line.is_empty()).then(|| prefix(line, MAX_LENGTH).to_owned())
}

/// Trimmed, `None` when empty: the reader's page-title cleanup (no newline join, no length cap).
pub(crate) fn trimmed(raw: Option<&str>) -> Option<&str> {
    let text = raw?.trim_matches(char::is_whitespace);
    (!text.is_empty()).then_some(text)
}

/// The most characters a snippet keeps (`WorkspaceActivityName.snippetLimit`).
pub const SNIPPET_LIMIT: usize = 120;

/// One line of at most [`SNIPPET_LIMIT`] characters, cut with `…`; `None` when empty
/// (`WorkspaceActivityName.snippet`).
pub fn snippet(text: Option<&str>) -> Option<String> {
    let line = split_join(text?, is_whitespace);
    if line.is_empty() {
        return None;
    }
    if char_count(&line) > SNIPPET_LIMIT {
        return Some(format!("{}…", prefix(&line, SNIPPET_LIMIT - 1)));
    }
    Some(line)
}

/// A shell's name as an idle terminal reports it (`TerminalTitle.isBareShell`): it says nothing
/// about the work.
pub fn is_bare_shell(title: &str) -> bool {
    let title = title.strip_prefix('-').unwrap_or(title);
    matches!(
        title,
        "zsh" | "bash" | "fish" | "sh" | "nu" | "dash" | "ksh" | "tcsh" | "pwsh" | "login" | "~"
    )
}

/// The blank page's and the New Tab page's addresses: what a page tab's record carries as its
/// title, never a name.
pub fn is_placeholder(title: &str) -> bool {
    matches!(title.to_lowercase().as_str(), "about:blank" | "chrome://newtab" | "chrome://newtab/")
}

/// The daemon's numbered default, `workspace-N`, exactly (`WorkspaceModel.isNumberedDefaultName`).
pub fn is_numbered_default_name(name: &str) -> bool {
    name.strip_prefix("workspace-")
        .is_some_and(|number| !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()))
}

/// A name the daemon gave: empty, `~` or `workspace-N`, trimmed (`WorkspaceModel.isDefaultName`).
pub fn is_default_workspace_name(name: &str) -> bool {
    let name = name.trim_matches(char::is_whitespace);
    name.is_empty() || name == "~" || is_numbered_default_name(name)
}

/// `NSString.lastPathComponent`: the last component, trailing slashes ignored; `/` for the root.
pub fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    trimmed.rsplit('/').next().unwrap_or(trimmed)
}

fn hex(byte: u8) -> Option<u8> {
    (byte as char).to_digit(16).map(|d| d as u8)
}

fn percent_decode(text: &str) -> String {
    let mut out = Vec::with_capacity(text.len());
    let mut rest = text.as_bytes();
    while let Some((&byte, tail)) = rest.split_first() {
        if byte == b'%'
            && let [h, l, after @ ..] = tail
            && let (Some(high), Some(low)) = (hex(*h), hex(*l))
        {
            out.push(high << 4 | low);
            rest = after;
            continue;
        }
        out.push(byte);
        rest = tail;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_owned())
}

/// The host of an address as `URL(string:)?.host()` reads it (percent-decoded, brackets off an IP
/// literal); `None` without a scheme and authority or with an empty host.
pub fn url_host(url: &str) -> Option<String> {
    let (scheme, after_scheme) = url.split_once(':')?;
    let mut scheme_chars = scheme.chars();
    if !scheme_chars.next()?.is_ascii_alphabetic()
        || !scheme_chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let rest = after_scheme.strip_prefix("//")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if let Some(literal) = host_port.strip_prefix('[') {
        literal.split_once(']')?.0
    } else {
        host_port.split_once(':').map_or(host_port, |(host, _)| host)
    };
    (!host.is_empty()).then(|| percent_decode(host))
}

/// The host without a leading `www.`.
pub fn site(url: &str) -> Option<String> {
    url_host(url).map(|host| match host.strip_prefix("www.") {
        Some(bare) => bare.to_owned(),
        None => host,
    })
}
