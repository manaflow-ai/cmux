//! What a system banner says, built from what the app knows for sure (where)
//! and what the poster said (state and message): title = `workspace › tab
//! [· machine]`, subtitle = the state headline (`Claude finished`, `Needs
//! input`) and the poster's subtitle, body = the message as plain text. The
//! app writes the title, so a terminal program cannot pose as another
//! terminal. Moved from the app's `NotificationBannerFormatter`.
//!
//! Lengths count user-perceived characters (grapheme clusters), as the app's
//! strings do. The markdown rules match the app's regexes exactly, written
//! by hand: the `regex` crate has no backreference or lookahead.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// The body's length limit: about four banner lines.
pub const MAX_BODY_CHARACTERS: usize = 240;
/// A workspace or tab name's length limit in the title.
pub const MAX_NAME_CHARACTERS: usize = 40;

/// What the banner is built from.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Facts {
    /// The daemon's title, an OSC 7501 alert's localized title, a burst digest's count.
    pub headline: String,
    pub poster_subtitle: Option<String>,
    pub body: String,
    /// None (no tab in the store) keeps the headline as the title.
    pub workspace: Option<String>,
    pub tab: Option<String>,
    pub host: Option<String>,
    /// False keeps the body's lines as given (an approval's command).
    pub plain: bool,
    pub max_body_characters: usize,
    pub max_name_characters: usize,
}

impl Default for Facts {
    fn default() -> Self {
        Self {
            headline: String::new(),
            poster_subtitle: None,
            body: String::new(),
            workspace: None,
            tab: None,
            host: None,
            plain: true,
            max_body_characters: MAX_BODY_CHARACTERS,
            max_name_characters: MAX_NAME_CHARACTERS,
        }
    }
}

/// The banner's three lines.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Content {
    pub title: String,
    pub subtitle: Option<String>,
    pub body: String,
}

/// The banner for `facts`.
pub fn content(facts: &Facts) -> Content {
    let headline = facts.headline.trim();
    let poster = facts.poster_subtitle.as_deref().and_then(non_empty);
    let body = if facts.plain {
        plain_text(&facts.body, facts.max_body_characters)
    } else {
        facts.body.clone()
    };
    let Some(workspace) = facts.workspace.as_deref().and_then(non_empty) else {
        let title = non_empty(headline)
            .or_else(|| facts.tab.as_deref().and_then(non_empty))
            .unwrap_or("cmux");
        return Content { title: title.to_owned(), subtitle: poster.map(str::to_owned), body };
    };
    let tab = facts.tab.as_deref().and_then(non_empty).filter(|tab| *tab != workspace);
    let mut title = clip(workspace, facts.max_name_characters, false);
    if let Some(tab) = tab {
        title.push_str(" › ");
        title.push_str(&clip(tab, facts.max_name_characters, false));
    }
    if let Some(host) = facts.host.as_deref().and_then(non_empty) {
        title.push_str(" · ");
        title.push_str(host);
    }
    let mut state = headline.to_owned();
    // "Fix login needs input" in tab "Fix login": the title already names the chat.
    if let Some(tab) = tab {
        let tab: Vec<&str> = tab.graphemes(true).collect();
        let said: Vec<&str> = headline.graphemes(true).collect();
        if said.len() > tab.len() + 1
            && said.starts_with(&tab)
            && at(&said, tab.len(), " ")
            && let Some((head, more)) = tail(&said, tab.len() + 1).split_first()
        {
            state = head.to_uppercase() + &more.concat();
        }
    }
    let subtitle: Vec<&str> = [non_empty(&state), poster].into_iter().flatten().collect();
    let subtitle = subtitle.join(" · ");
    Content { title, subtitle: (!subtitle.is_empty()).then_some(subtitle), body }
}

/// `markdown` as banner text: no heading, quote or emphasis marks, links and
/// images as their text, code fences dropped (their code kept), list items as
/// bullets, blank lines removed, cut on a word to `limit` with an ellipsis.
pub fn plain_text(markdown: &str, limit: usize) -> String {
    let all: Vec<&str> = markdown.graphemes(true).collect();
    let mut lines: Vec<String> = Vec::new();
    // Split on the newline character only: "\r\n" is one character and stays.
    for raw in all.split(|grapheme| *grapheme == "\n") {
        let raw = raw.concat();
        let trimmed = raw.trim_matches(is_space);
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") || trimmed.is_empty() {
            continue;
        }
        let mut line: Vec<&str> = trimmed.graphemes(true).collect();
        line = strip_heading(line);
        line = strip_quote(line);
        let mut line = bullet(line);
        for rule in [image as Rule, link, bold, emphasis, strike] {
            line = replace_all(&line, rule);
        }
        let line = line.replace('`', "");
        let line = line.trim_matches(is_space);
        if !line.is_empty() {
            lines.push(line.to_owned());
        }
    }
    clip(&lines.join("\n"), limit, true)
}

/// `text` cut to `limit` characters with "…" (the ellipsis counts), on the
/// last space within the final 30 characters when `on_word`.
fn clip(text: &str, limit: usize, on_word: bool) -> String {
    let all: Vec<&str> = text.graphemes(true).collect();
    if all.len() <= limit || limit <= 1 {
        return text.to_owned();
    }
    let mut cut = seg(&all, 0, limit - 1);
    if on_word
        && let Some(space) = cut.iter().rposition(|grapheme| whitespace(grapheme))
        && cut.len() - space < 30
    {
        cut = seg(cut, 0, space);
    }
    cut.concat().trim().to_owned() + "…"
}

/// `text` without surrounding whitespace, None when nothing is left.
fn non_empty(text: &str) -> Option<&str> {
    let trimmed = text.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

/// The app's `.whitespaces`: spaces (Unicode Zs) and tab, never a newline.
fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

fn first(grapheme: &str) -> char {
    grapheme.chars().next().unwrap_or('\0')
}

/// A regex `\s`: a whitespace character, newlines included.
fn whitespace(grapheme: &str) -> bool {
    first(grapheme).is_whitespace()
}

/// What a regex `.` refuses.
fn newline(grapheme: &str) -> bool {
    matches!(first(grapheme), '\n' | '\u{b}' | '\u{c}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// A regex `\w`.
fn word(grapheme: &str) -> bool {
    let c = first(grapheme);
    c.is_alphanumeric() || c == '_'
}

fn at(line: &[&str], index: usize, text: &str) -> bool {
    line.get(index) == Some(&text)
}

/// The grapheme at `index`, "" past the end.
fn grapheme<'s>(line: &[&'s str], index: usize) -> &'s str {
    line.get(index).copied().unwrap_or("")
}

/// `line[from..to]`, empty when out of range.
fn seg<'a, 's>(line: &'a [&'s str], from: usize, to: usize) -> &'a [&'s str] {
    line.get(from..to).unwrap_or(&[])
}

/// `line[from..]`, empty past the end.
fn tail<'a, 's>(line: &'a [&'s str], from: usize) -> &'a [&'s str] {
    line.get(from..).unwrap_or(&[])
}

/// `^#{1,6}\s+` removed.
fn strip_heading(line: Vec<&str>) -> Vec<&str> {
    let hashes = line.iter().take_while(|grapheme| **grapheme == "#").count();
    if !(1..=6).contains(&hashes) || !line.get(hashes).is_some_and(|g| whitespace(g)) {
        return line;
    }
    let spaces = tail(&line, hashes).iter().take_while(|grapheme| whitespace(grapheme)).count();
    tail(&line, hashes + spaces).to_vec()
}

/// `^(>\s?)+` removed.
fn strip_quote(line: Vec<&str>) -> Vec<&str> {
    let mut end = 0;
    while at(&line, end, ">") {
        end += 1;
        if line.get(end).is_some_and(|g| whitespace(g)) {
            end += 1;
        }
    }
    tail(&line, end).to_vec()
}

/// `^[-*+]\s+` as "• ".
fn bullet(line: Vec<&str>) -> String {
    let marked = matches!(line.first(), Some(&("-" | "*" | "+")));
    if !marked || !line.get(1).is_some_and(|g| whitespace(g)) {
        return line.concat();
    }
    let spaces = tail(&line, 1).iter().take_while(|grapheme| whitespace(grapheme)).count();
    "• ".to_owned() + &tail(&line, 1 + spaces).concat()
}

/// A match starting at the index: where it ends and what replaces it.
type Rule = fn(&[&str], usize) -> Option<(usize, String)>;

/// Every leftmost match of `rule` replaced, left to right, as a regex replace does.
fn replace_all(text: &str, rule: Rule) -> String {
    let line: Vec<&str> = text.graphemes(true).collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < line.len() {
        if let Some((end, replacement)) = rule(&line, index) {
            out.push_str(&replacement);
            index = end;
        } else {
            out.push_str(grapheme(&line, index));
            index += 1;
        }
    }
    out
}

/// `[` then `([^\]]*)\]\([^)]*\)` from `open`: the text's end and the match's.
fn bracketed(line: &[&str], open: usize, at_least: usize) -> Option<(usize, usize)> {
    if !at(line, open, "[") {
        return None;
    }
    let close = open + 1 + tail(line, open + 1).iter().position(|g| *g == "]")?;
    if close - open - 1 < at_least || !at(line, close + 1, "(") {
        return None;
    }
    let paren = close + 2 + tail(line, close + 2).iter().position(|g| *g == ")")?;
    Some((close, paren + 1))
}

/// `!\[([^\]]*)\]\([^)]*\)` as its text.
fn image(line: &[&str], start: usize) -> Option<(usize, String)> {
    if !at(line, start, "!") {
        return None;
    }
    let (close, end) = bracketed(line, start + 1, 0)?;
    Some((end, seg(line, start + 2, close).concat()))
}

/// `\[([^\]]+)\]\([^)]*\)` as its text.
fn link(line: &[&str], start: usize) -> Option<(usize, String)> {
    let (close, end) = bracketed(line, start, 1)?;
    Some((end, seg(line, start + 1, close).concat()))
}

/// `(\*\*|__)(\S(?:.*?\S)?)\1` as its text.
fn bold(line: &[&str], start: usize) -> Option<(usize, String)> {
    let mark =
        ["*", "_"].into_iter().find(|mark| at(line, start, mark) && at(line, start + 1, mark))?;
    let text = start + 2;
    if line.get(text).is_none_or(|g| whitespace(g)) {
        return None;
    }
    let closes = |index: usize| at(line, index, mark) && at(line, index + 1, mark);
    // The optional group first (greedy), its middle as short as it can be (lazy).
    let mut last = text + 1;
    while last < line.len() {
        if !whitespace(grapheme(line, last)) && closes(last + 1) {
            return Some((last + 3, seg(line, text, last + 1).concat()));
        }
        if newline(grapheme(line, last)) {
            break;
        }
        last += 1;
    }
    closes(text + 1).then(|| (text + 3, grapheme(line, text).to_owned()))
}

/// `(^|[^\w*])\*(\S(?:[^*]*?\S)?)\*(?![\w*])` as its lead and text: single-star
/// emphasis, not `2*3*4` (the opening star follows no word character).
fn emphasis(line: &[&str], start: usize) -> Option<(usize, String)> {
    let free = |index: usize| line.get(index).is_none_or(|g| !word(g) && *g != "*");
    let mut leads = Vec::with_capacity(2);
    if start == 0 {
        leads.push(start);
    }
    if line.get(start).is_some_and(|g| !word(g) && *g != "*") {
        leads.push(start + 1);
    }
    for star in leads {
        if !at(line, star, "*") {
            continue;
        }
        let lead = seg(line, start, star).concat();
        let text = star + 1;
        if line.get(text).is_none_or(|g| whitespace(g)) {
            continue;
        }
        let mut last = text + 1;
        while last < line.len() {
            if !whitespace(grapheme(line, last)) && at(line, last + 1, "*") && free(last + 2) {
                return Some((last + 2, lead + &seg(line, text, last + 1).concat()));
            }
            if grapheme(line, last) == "*" {
                break;
            }
            last += 1;
        }
        if at(line, text + 1, "*") && free(text + 2) {
            return Some((text + 2, lead + grapheme(line, text)));
        }
    }
    None
}

/// `~~(.+?)~~` as its text.
fn strike(line: &[&str], start: usize) -> Option<(usize, String)> {
    if !(at(line, start, "~") && at(line, start + 1, "~")) {
        return None;
    }
    let text = start + 2;
    let mut end = text + 1;
    while end <= line.len() {
        if newline(grapheme(line, end - 1)) {
            return None;
        }
        if at(line, end, "~") && at(line, end + 1, "~") {
            return Some((end + 2, seg(line, text, end).concat()));
        }
        end += 1;
    }
    None
}

#[cfg(test)]
#[path = "banner_tests.rs"]
mod tests;
