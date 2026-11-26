//! The structural half of a turn's frames (RFD 0151, "a structural diff beside the pixel hash"):
//! each frame of a page also reads the page's accessibility tree of what is on screen (the browser
//! host's `snapshot(page, {viewport: true})`, written by the capture cell as `<picture>.tree`), and
//! the daemon compares it with the last kept frame's.
//!
//! Why: the 64-bit dHash sees a 9x8 grey picture, so a changed label, a new list row or a toggled
//! checkbox often moves it by no bit at all, and such a frame was dropped as "the same picture".
//! With a tree, a frame whose picture barely moved is still kept when its tree changed and its
//! pixels did too ([`keeps_anyway`]), and every kept frame says what changed in words
//! ([`TreeChange`]), which the chat and `look` show without another picture.
//!
//! Lines are compared as a multiset after dropping what moves without the page changing: element
//! refs (`[ref=e12]`, numbered per read) and focus. Bounded: at most [`MAX_LINES`] lines a tree,
//! [`SAMPLE`] changed lines a frame, each at most [`LINE_CHARS`] characters.

use std::collections::HashMap;

/// Lines of one tree kept for the comparison; a longer tree's tail is not compared.
pub(crate) const MAX_LINES: usize = 20_000;
/// Changed lines a frame names.
pub(crate) const SAMPLE: usize = 6;
/// Characters of one named line.
pub(crate) const LINE_CHARS: usize = 120;
/// The largest tree file read.
pub(crate) const MAX_TREE_BYTES: u64 = 512 << 10;

/// What changed in the page's tree since the frame before.
#[derive(Clone, Debug, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub(crate) struct TreeChange {
    /// Elements (lines) that came.
    pub added: usize,
    /// Elements (lines) that went.
    pub removed: usize,
    /// The first few changed lines, `+ ` or `- ` then the element, trimmed.
    pub lines: Vec<String>,
}

impl TreeChange {
    pub(crate) fn is_empty(&self) -> bool {
        self.added == 0 && self.removed == 0
    }

    /// One line for a person or an agent: `+2 -1 elements: + button "Save"; - text "Draft"`.
    pub(crate) fn summary(&self) -> String {
        if self.is_empty() {
            return "no element changed".to_owned();
        }
        let mut text = format!("+{} -{} elements", self.added, self.removed);
        if !self.lines.is_empty() {
            text.push_str(": ");
            text.push_str(&self.lines.join("; "));
        }
        text
    }
}

/// A tree's comparable lines: no header notes (`# ...`), no refs, no focus, no blank lines.
pub(crate) fn tree_lines(text: &str) -> Vec<String> {
    text.lines()
        .filter(|line| {
            let trimmed = line.trim_start();
            !trimmed.is_empty() && !trimmed.starts_with('#')
        })
        .take(MAX_LINES)
        .map(normalize)
        .collect()
}

fn normalize(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line.trim_end();
    while let Some(at) = rest.find(" [") {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let Some(close) = tail.find(']') else {
            rest = tail;
            break;
        };
        let attr = &tail[2..close];
        if !(attr == "focused" || attr.starts_with("ref=")) {
            out.push_str(&tail[..=close]);
        }
        rest = &tail[close + 1..];
    }
    out.push_str(rest);
    out
}

/// What changed from `old` to `new` (both from [`tree_lines`]), as multisets of lines.
pub(crate) fn tree_diff(old: &[String], new: &[String]) -> TreeChange {
    let mut counts: HashMap<&str, i64> = HashMap::with_capacity(old.len().max(new.len()));
    for line in old {
        *counts.entry(line).or_default() -= 1;
    }
    for line in new {
        *counts.entry(line).or_default() += 1;
    }
    let mut change = TreeChange::default();
    // In document order, so the named lines read top to bottom.
    let mut named = |sign: &str, line: &str, change: &mut TreeChange| {
        if change.lines.len() < SAMPLE {
            change
                .lines
                .push(format!("{sign} {}", clip(line.trim_start().trim_start_matches("- "))));
        }
    };
    for line in new {
        if let Some(n) = counts.get_mut(line.as_str())
            && *n > 0
        {
            *n -= 1;
            change.added += 1;
            named("+", line, &mut change);
        }
    }
    for line in old {
        if let Some(n) = counts.get_mut(line.as_str())
            && *n < 0
        {
            *n += 1;
            change.removed += 1;
            named("-", line, &mut change);
        }
    }
    change
}

fn clip(line: &str) -> String {
    if line.chars().count() <= LINE_CHARS {
        return line.to_owned();
    }
    let mut out: String = line.chars().take(LINE_CHARS - 1).collect();
    out.push('…');
    out
}

/// A frame whose picture is within the dHash's "same" is kept anyway when the page's tree changed
/// and its pixels did too (`pixels_moved`: the thumbnail is not byte for byte the last kept one), so
/// a changed label shows, while a tree change off the picture (or a blinking caret, whose tree is
/// the same) still keeps nothing.
pub(crate) fn keeps_anyway(change: Option<&TreeChange>, pixels_moved: bool) -> bool {
    pixels_moved && change.is_some_and(|c| !c.is_empty())
}

/// A cheap signature of a picture's pixels, to tell "not byte for byte the same".
pub(crate) fn pixel_sig(pixels: &[u8]) -> u64 {
    use std::hash::{Hash as _, Hasher as _};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    pixels.hash(&mut hasher);
    hasher.finish()
}

/// Reads and removes a capture's tree file (`<picture>.tree`); none when the cell wrote none.
pub(crate) fn take_tree(path: &std::path::Path) -> Option<Vec<String>> {
    let small = std::fs::metadata(path).is_ok_and(|m| m.len() <= MAX_TREE_BYTES);
    let text = small.then(|| std::fs::read_to_string(path).ok()).flatten();
    let _ = crate::home_fs::remove_file(path);
    let lines = tree_lines(&text?);
    (!lines.is_empty()).then_some(lines)
}

#[cfg(test)]
#[path = "turn_tree_tests.rs"]
mod tests;
