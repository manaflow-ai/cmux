//! A message's Markdown as the one line a preview shows: the daemon's Home
//! rows (`cmux-conversation` `preview_of`) and the Chief's push banner
//! (`cmux-mobile-host` `notify`).
//!
//! A preview never shows syntax. Emphasis, code and heading markers go; a link
//! shows its label; a pipe table is named by its column titles ("Table: Before
//! / After"); a picture (`![alt](source)`) is left out of the words and listed
//! in [`MessagePreview::images`]; a message of pictures alone says how many.
//! Code keeps its text. White space folds to single spaces.
//!
//! This is the Rust port of CmuxHomeCore's `MessagePreview` (Swift), which the
//! Mac and iPhone apps use. Both are held to one case file,
//! `Packages/Shared/CmuxHomeCore/Tests/CmuxHomeCoreTests/MessagePreviewCases.json`,
//! so the daemon, the push and the apps say the same words.
//!
//! ```
//! use cmux_message_preview::{MessagePreview, Words};
//! let preview = MessagePreview::new("| | Before | After |\n|---|---|---|\n| Light | ![b](b.png) | ![a](a.png) |");
//! assert_eq!(preview.text(&Words::english()), "Table: Before / After");
//! assert_eq!(preview.images[0].source, "b.png");
//! ```

mod lines;
mod parse;

/// A picture the message names: `![alt](source)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    /// The alt text, as written.
    pub alt: String,
    /// The source as written (a path, a URL, `cmux-attachment:<hash>`), without angle brackets.
    pub source: String,
}

/// A pipe table the message holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    /// The column titles that have words, in order (a matrix's empty corner is left out).
    pub columns: Vec<String>,
    /// How many body rows it has.
    pub rows: usize,
}

/// The words a preview says for what has no words of its own, in the reader's
/// language. `{}` in `table` and `images` is replaced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Words {
    /// A table with titled columns, given the titles joined by " / ": `Table: {}`.
    pub table: String,
    /// A table whose columns have no titles: `Table`.
    pub untitled_table: String,
    /// One picture alone: `Image`.
    pub image: String,
    /// Several pictures alone, given how many: `{} images`.
    pub images: String,
}

impl Words {
    /// The English words (the apps' `home.preview.*` strings).
    pub fn english() -> Self {
        Self {
            table: "Table: {}".into(),
            untitled_table: "Table".into(),
            image: "Image".into(),
            images: "{} images".into(),
        }
    }

    /// The Japanese words (the apps' `home.preview.*` strings).
    pub fn japanese() -> Self {
        Self {
            table: "表: {}".into(),
            untitled_table: "表".into(),
            image: "画像".into(),
            images: "画像 {} 枚".into(),
        }
    }

    /// The words of a POSIX locale (`ja_JP.UTF-8`): Japanese for `ja`, else English,
    /// as cmux-tui picks its own catalog.
    pub fn for_locale(locale: &str) -> Self {
        if locale.to_ascii_lowercase().starts_with("ja") {
            Self::japanese()
        } else {
            Self::english()
        }
    }
}

impl Default for Words {
    /// English, as the apps fall back to it.
    fn default() -> Self {
        Self::english()
    }
}

/// One piece of the message, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Piece {
    Words(String),
    Table(Table),
}

/// The preview of one message's Markdown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessagePreview {
    pieces: Vec<Piece>,
    /// Every picture the message names, in order, the ones in table cells included.
    pub images: Vec<Image>,
}

impl MessagePreview {
    /// The preview of `markdown`, in one pass over it.
    pub fn new(markdown: &str) -> Self {
        let (pieces, images) = parse::parse(markdown);
        Self { pieces, images }
    }

    /// Every pipe table the message holds, in order.
    pub fn tables(&self) -> impl Iterator<Item = &Table> {
        self.pieces.iter().filter_map(|piece| match piece {
            Piece::Table(table) => Some(table),
            Piece::Words(_) => None,
        })
    }

    /// The preview as one line: its words, each table by its titles, and when
    /// it has no words, its pictures' count. Empty for a message with nothing
    /// to show.
    pub fn text(&self, words: &Words) -> String {
        let parts: Vec<String> = self
            .pieces
            .iter()
            .map(|piece| match piece {
                Piece::Words(w) => w.clone(),
                Piece::Table(t) if t.columns.is_empty() => words.untitled_table.clone(),
                Piece::Table(t) => words.table.replace("{}", &t.columns.join(" / ")),
            })
            .collect();
        let line = folded(&parts.join(" "));
        if !line.is_empty() || self.images.is_empty() {
            return line;
        }
        if self.images.len() == 1 {
            words.image.clone()
        } else {
            words.images.replace("{}", &self.images.len().to_string())
        }
    }
}

/// A message's Markdown as its lines of words, in order: each line's preview, a
/// pipe table as one line ("Table: Before / After"), a code block's lines as
/// written (without the fences), empty lines left out. For a push's last lines
/// (`cmux-mobile-host` `notify`), where one line of the whole message is too little.
///
/// ```
/// use cmux_message_preview::{Words, lines};
/// let md = "**Done.** See [PR 12](https://x/12).\n| A | B |\n|---|---|\n| 1 | 2 |";
/// assert_eq!(lines(md, &Words::english()), ["Done. See PR 12.", "Table: A / B"]);
/// ```
pub fn lines(markdown: &str, words: &Words) -> Vec<String> {
    lines::lines(markdown, words)
}

/// `s` with every run of white space as one space, trimmed.
pub(crate) fn folded(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut space = false;
    for ch in s.chars() {
        if ch.is_whitespace() {
            space = !out.is_empty();
        } else {
            if space {
                out.push(' ');
            }
            space = false;
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
mod tests;
