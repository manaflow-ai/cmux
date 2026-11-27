//! Markdown for chat message bubbles: CommonMark block and inline structure plus the GFM
//! extensions (tables, task lists, strikethrough, extended autolinks), written for chat.
//!
//! - A newline inside a paragraph is a line break (chat text keeps its lines).
//! - Raw HTML is never interpreted: tags are literal text. Images are never loaded:
//!   `![alt](src)` is the text "[Image: alt]" (the host's localized form), a link when its URL
//!   is allowed.
//! - Message text is untrusted: a link is a link only when the host's [`LinkPolicy`] allows its
//!   URL (the macOS app's `MarkdownLinkPolicy`: http, https, mailto and its extra rules).
//! - Table rows keep cells beyond the header's count (GFM drops them); a pipe in a code span
//!   does not split a cell.
//!
//! The parser is pure and thread safe. Top-level blocks carry their source line range, so a
//! stream re-parses only from the start of its last top-level block ([`parse_tail`]).
//!
//! It is the Home transcript's parser, moved from Swift (MessagesLab's catalyst
//! MarkdownParser.swift) with the same results: string comparisons the Swift parser made on
//! `Character`s compare grapheme clusters here, its `String` equality is canonical equivalence,
//! and span offsets are UTF-16 code units. The app decodes [`encode`]'s bytes into its own model
//! and draws it (`src/ffi.rs`, include/cmux_chat_markdown.h).

mod block;
mod chars;
pub mod encode;
pub mod ffi;
mod inline;

use std::collections::HashMap;

/// Inline styles of a run of display text (bits; the app's `MDStyle`).
pub mod style {
    pub const EMPHASIS: u16 = 1;
    pub const STRONG: u16 = 2;
    pub const STRIKE: u16 = 4;
    pub const CODE: u16 = 8;
    pub const LINK: u16 = 16;
    pub const IMAGE: u16 = 32;
}

/// One styled run: a UTF-16 range of [`Text::string`].
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Span {
    pub location: usize,
    pub length: usize,
    pub style: u16,
    pub link: Option<String>,
    /// An image's source exactly as written (`![alt](src)`), for the host's image provider only.
    pub image: Option<String>,
}

/// Inline content, flattened: the display string and its styled runs. Line breaks are "\n".
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct Text {
    pub string: String,
    pub spans: Vec<Span>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Align {
    None,
    Left,
    Center,
    Right,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Table {
    pub aligns: Vec<Align>,
    pub header: Vec<Text>,
    pub rows: Vec<Vec<Text>>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Item {
    /// The marker as written: "-", "*", "+", "3.", "4)".
    pub marker: String,
    /// None: not a task; false: "[ ]"; true: "[x]".
    pub task: Option<bool>,
    pub blocks: Vec<Block>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct List {
    pub ordered: bool,
    pub start: i64,
    /// Loose: a blank line between items or inside an item.
    pub loose: bool,
    pub items: Vec<Item>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Paragraph(Text),
    Heading(u8, Text),
    /// `closed` is false for a fence that runs to the end of the text (a stream).
    Code {
        lang: String,
        text: String,
        fenced: bool,
        closed: bool,
    },
    Quote(Vec<Block>),
    List(List),
    Table(Table),
    Rule,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Block {
    pub kind: Kind,
    /// Rendering differs from the plain text path ([`Document::is_rich`]).
    pub rich: bool,
    /// A blank line separates this block from the one before it (same container).
    pub blank_before: bool,
    /// Source lines [lower, upper) (top-level blocks only; 0..0 inside containers).
    pub lines: (usize, usize),
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Document {
    pub blocks: Vec<Block>,
    /// Whether rendering differs from plain text: any block other than a plain paragraph, or
    /// any styled run other than an autolink.
    pub is_rich: bool,
}

/// What the host decides about links and images.
pub trait LinkPolicy {
    /// Whether `url` (edge whitespace and controls already removed, a valid RFC 3986 scheme
    /// before its first ":") may be a link: the app's `MarkdownLinkPolicy.sanitize(url) != nil`.
    fn allows(&self, url: &str) -> bool;
    /// The text of an image: "[Image: alt]", or "[Image]" when `alt` is empty.
    fn image_placeholder(&self, alt: &str) -> String;
}

/// The built-in policy: http and https URLs with a host, and mailto URLs, are links; images
/// read "[Image: alt]". The app passes its own (its extra schemes and rules, its language).
#[derive(Clone, Copy, Debug, Default)]
pub struct DefaultPolicy;

impl LinkPolicy for DefaultPolicy {
    fn allows(&self, url: &str) -> bool {
        if url.chars().any(chars::is_edge) || url.chars().count() > 8192 {
            return false;
        }
        let Some((scheme, rest)) = url.split_once(':') else { return false };
        match scheme.to_ascii_lowercase().as_str() {
            "http" | "https" => {
                let Some(after) = rest.strip_prefix("//") else { return false };
                let host = after.split(['/', '?', '#']).next().unwrap_or_default();
                let host = host.rsplit('@').next().unwrap_or_default();
                let host = host.split(':').next().unwrap_or_default();
                !host.is_empty()
            }
            "mailto" => !rest.is_empty(),
            _ => false,
        }
    }

    fn image_placeholder(&self, alt: &str) -> String {
        if alt.is_empty() { "[Image]".to_owned() } else { format!("[Image: {alt}]") }
    }
}

/// An image placeholder from the host's two localized forms: `empty` ("[Image]") and
/// `template` with one "%@" for the alt text ("[Image: %@]").
pub fn placeholder_from_templates(empty: &str, template: &str, alt: &str) -> String {
    if alt.is_empty() {
        return empty.to_owned();
    }
    let mut out = String::with_capacity(template.len().saturating_add(alt.len()));
    let mut rest = template;
    let mut done = false;
    while let Some(p) = rest.find('%') {
        let (head, tail) = rest.split_at(p);
        out.push_str(head);
        if !done && tail.starts_with("%@") {
            out.push_str(alt);
            done = true;
            rest = tail.get(2..).unwrap_or_default();
        } else if tail.starts_with("%%") {
            out.push('%');
            rest = tail.get(2..).unwrap_or_default();
        } else {
            out.push('%');
            rest = tail.get(1..).unwrap_or_default();
        }
    }
    out.push_str(rest);
    out
}

/// The URL string a link destination becomes, or None (not a link): leading and trailing
/// whitespace and control characters removed, then the scheme checked here and the rest by the
/// host's policy.
pub fn sanitize(policy: &dyn LinkPolicy, raw: &str) -> Option<String> {
    let t = raw.trim_matches(chars::is_edge);
    if t.is_empty() || !chars::has_scheme(t) {
        return None;
    }
    policy.allows(t).then(|| t.to_owned())
}

/// Link reference definitions: normalized label to (destination, title).
#[derive(Clone, Debug, Default)]
pub(crate) struct Refs {
    map: HashMap<String, (String, Option<String>)>,
}

impl Refs {
    pub(crate) fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub(crate) fn get(&self, key: &str) -> Option<&(String, Option<String>)> {
        self.map.get(key)
    }

    pub(crate) fn insert_first(&mut self, key: String, value: (String, Option<String>)) {
        self.map.entry(key).or_insert(value);
    }

    /// Whitespace runs (space, tab, newline) become one space; lowercased; canonical form.
    pub(crate) fn normalize(label: &str) -> String {
        use unicode_normalization::UnicodeNormalization;
        use unicode_segmentation::UnicodeSegmentation;
        let mut out = String::with_capacity(label.len());
        let mut pending = false;
        for g in label.graphemes(true) {
            if g == " " || g == "\t" || g == "\n" {
                pending = !out.is_empty();
                continue;
            }
            if pending {
                out.push(' ');
                pending = false;
            }
            for c in g.chars() {
                out.extend(c.to_lowercase());
            }
        }
        if unicode_normalization::is_nfc(&out) { out } else { out.nfc().collect() }
    }
}

/// Cheap pre-check (no allocation): could this text contain markdown syntax? False means the
/// plain path for sure.
pub fn might_contain(text: &[u8]) -> bool {
    let mut line_start = true;
    let mut indent = 0u32;
    for &b in text {
        if b == 10 || b == 13 {
            line_start = true;
            indent = 0;
            continue;
        }
        if line_start && (b == 32 || b == 9) {
            indent = indent.saturating_add(if b == 9 { 4 } else { 1 });
            if indent >= 4 {
                return true; // indented code
            }
            continue;
        }
        match b {
            b'*' | b'_' | b'`' | b'~' | b'|' | b'[' | b'\\' | b'&' | b'<' => return true,
            b'#' | b'>' | b'+' | b'-' | b'=' | b'0'..=b'9' if line_start => return true,
            _ => {}
        }
        line_start = false;
    }
    false
}

/// Parse a whole text.
pub fn parse(text: &str, policy: &dyn LinkPolicy) -> Document {
    let lines = block::split_lines(text);
    let mut refs = Refs::default();
    let mut blocks = block::parse(&lines, &mut refs, None, true, 0, policy);
    // Reference links may point forward: a second pass with every definition.
    if !refs.is_empty() {
        let mut again = Refs::default();
        blocks = block::parse(&lines, &mut again, Some(&refs), true, 0, policy);
    }
    let is_rich = blocks.iter().any(|b| b.rich);
    Document { blocks, is_rich }
}

/// The top-level blocks of `text` from source line `from` on (a stream's re-parse of its last
/// block): one pass with no reference definitions, line ranges counted from the text's start.
pub fn parse_tail(text: &str, from: usize, policy: &dyn LinkPolicy) -> Vec<Block> {
    let lines = block::split_lines(text);
    let tail = lines.get(from.min(lines.len())..).unwrap_or_default();
    let mut refs = Refs::default();
    let mut blocks = block::parse(tail, &mut refs, None, true, 0, policy);
    for b in &mut blocks {
        b.lines = (b.lines.0.saturating_add(from), b.lines.1.saturating_add(from));
    }
    blocks
}

/// Inline content of one text: `breaks` false turns newlines into spaces (table cells).
pub fn parse_inline(text: &str, breaks: bool, policy: &dyn LinkPolicy) -> Text {
    inline::parse(text, breaks, None, policy)
}
