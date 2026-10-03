//! The Chief's memory views: one append-only log of short lines plus a cache
//! of one-line summaries over aligned ranges (`#lo-hi`). The log is the
//! truth; summaries can always be rebuilt. Port of
//! `mux/packages/brain/src/memory.ts` (same ranges, same text). Storage is the
//! host's: the core reads through [`MemoryStore`], which has no errors here
//! because the host loads what a view needs before it calls the core.

use std::collections::BTreeMap;

/// Longest log line, in UTF-8 bytes.
pub const MAX_LINE_BYTES: usize = 280;
/// Lines of memory shown at session start (the wake budget).
pub const DEFAULT_WAKE_BUDGET: usize = 96;

/// Inclusive range of log indices covered by a summary. Aligned: its size is
/// a power of two and `lo` is a multiple of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Range {
    pub lo: u64,
    pub hi: u64,
}

impl Range {
    pub const fn new(lo: u64, hi: u64) -> Self {
        Self { lo, hi }
    }

    pub fn size(self) -> u64 {
        self.hi - self.lo + 1
    }

    /// `lo-hi`, the summary's file and view name.
    pub fn key(self) -> String {
        format!("{}-{}", self.lo, self.hi)
    }

    fn is_aligned(self) -> bool {
        let size = self.size();
        size.is_power_of_two() && self.lo.is_multiple_of(size)
    }

    fn children(self) -> (Range, Range) {
        let half = self.size() / 2;
        (Range::new(self.lo, self.lo + half - 1), Range::new(self.lo + half, self.hi))
    }

    /// Parses `lo-hi`.
    pub fn parse(text: &str) -> Option<Range> {
        let (lo, hi) = text.split_once('-')?;
        let (lo, hi) = (lo.trim().parse().ok()?, hi.trim().parse().ok()?);
        (lo <= hi).then_some(Range::new(lo, hi))
    }
}

/// Read access to a memory: log lines and summaries.
pub trait MemoryStore {
    fn length(&self) -> u64;
    /// Lines `[start, end)`.
    fn read(&self, start: u64, end: u64) -> Vec<String>;
    fn node(&self, range: Range) -> Option<String>;
}

/// An in-memory store for tests and the corpus.
#[derive(Debug, Clone, Default)]
pub struct ArrayMemoryStore {
    pub lines: Vec<String>,
    pub nodes: BTreeMap<Range, String>,
}

impl MemoryStore for ArrayMemoryStore {
    fn length(&self) -> u64 {
        self.lines.len() as u64
    }

    fn read(&self, start: u64, end: u64) -> Vec<String> {
        let end = (end as usize).min(self.lines.len());
        let start = (start as usize).min(end);
        self.lines[start..end].to_vec()
    }

    fn node(&self, range: Range) -> Option<String> {
        self.nodes.get(&range).cloned()
    }
}

/// Splits text into log lines of at most [`MAX_LINE_BYTES`], on word
/// boundaries where possible; a cut line ends with `…`.
pub fn to_lines(text: &str) -> Vec<String> {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.is_empty() {
        return Vec::new();
    }
    let mut lines = Vec::new();
    // Work in UTF-16 units like the TypeScript, so the cut points agree.
    let mut rest: Vec<u16> = flat.encode_utf16().collect();
    while utf8_len(&rest) > MAX_LINE_BYTES {
        let mut cut = rest.len().min(MAX_LINE_BYTES);
        // Leave room for the 3-byte "…" continuation mark.
        while utf8_len(&rest[..cut]) > MAX_LINE_BYTES - 3 {
            cut -= 1;
        }
        if let Some(space) = last_space_at_or_before(&rest, cut)
            && space * 2 > cut
        {
            cut = space;
        }
        let head = String::from_utf16_lossy(&rest[..cut]);
        lines.push(format!("{}…", head.trim_end()));
        let tail = String::from_utf16_lossy(&rest[cut..]);
        rest = tail.trim_start().encode_utf16().collect();
    }
    if !rest.is_empty() {
        lines.push(String::from_utf16_lossy(&rest));
    }
    lines
}

/// `String.prototype.lastIndexOf(" ", from)`: the last space at or before `from`.
fn last_space_at_or_before(units: &[u16], from: usize) -> Option<usize> {
    let end = from.min(units.len().saturating_sub(1));
    (0..=end).rev().find(|&index| units[index] == u16::from(b' '))
}

/// UTF-8 length of a UTF-16 slice (a lone surrogate counts as U+FFFD, 3 bytes,
/// as TextEncoder does).
fn utf8_len(units: &[u16]) -> usize {
    char::decode_utf16(units.iter().copied()).map(|unit| unit.map_or(3, char::len_utf8)).sum()
}

/// Older blocks first: the binary decomposition of `[0, length)`.
pub fn decompose(length: u64) -> Vec<Range> {
    let mut blocks = Vec::new();
    if length == 0 {
        return blocks;
    }
    let mut lo = 0;
    let mut bit = 1u64 << (63 - length.leading_zeros());
    while bit >= 1 {
        if length - lo >= bit {
            blocks.push(Range::new(lo, lo + bit - 1));
            lo += bit;
        }
        bit /= 2;
    }
    blocks
}

/// The ranges wake shows: the decomposition, then the newest multi-line block
/// split while the view stays within `budget` entries.
pub fn wake_cover(length: u64, budget: usize) -> Vec<Range> {
    let mut cover = decompose(length);
    loop {
        let Some(index) = cover.iter().rposition(|range| range.size() > 1) else {
            return cover;
        };
        if cover.len() + 1 > budget {
            return cover;
        }
        let (left, right) = cover[index].children();
        cover.splice(index..=index, [left, right]);
    }
}

/// What wake shows, and the multi-line ranges in its cover with no summary
/// yet (compaction work).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WakeView {
    pub text: String,
    pub missing: Vec<Range>,
}

/// Renders what the Chief remembers within `budget` lines. A range without a
/// summary is shown through its children, down to raw lines.
pub fn wake(store: &impl MemoryStore, budget: usize) -> WakeView {
    let length = store.length();
    if length == 0 {
        return WakeView { text: String::new(), missing: Vec::new() };
    }
    let cover = wake_cover(length, budget);
    let missing =
        cover.iter().copied().filter(|r| r.size() > 1 && store.node(*r).is_none()).collect();
    let mut out = Vec::new();
    for range in cover {
        render(store, range, &mut out);
    }
    WakeView { text: out.join("\n"), missing }
}

fn render(store: &impl MemoryStore, range: Range, out: &mut Vec<String>) {
    if range.size() == 1 {
        let line = store.read(range.lo, range.lo + 1).into_iter().next().unwrap_or_default();
        out.push(format!("#{} {line}", range.lo));
        return;
    }
    if let Some(summary) = store.node(range) {
        out.push(format!("#{} {summary}", range.key()));
        return;
    }
    let (left, right) = range.children();
    render(store, left, out);
    render(store, right, out);
}

/// What a summary is made of: its two child summaries, or the raw lines at
/// the bottom. A range that is not aligned (or covers at most two lines)
/// returns its raw lines, unnumbered, as the TypeScript does.
pub fn zoom(store: &impl MemoryStore, range: Range) -> Vec<String> {
    if range.size() <= 2 || !range.is_aligned() {
        return store.read(range.lo, range.hi + 1);
    }
    let (left, right) = range.children();
    let mut out = Vec::new();
    for part in [left, right] {
        match store.node(part) {
            Some(summary) => out.push(format!("#{} {summary}", part.key())),
            None => out.extend(
                store
                    .read(part.lo, part.hi + 1)
                    .into_iter()
                    .enumerate()
                    .map(|(i, line)| format!("#{} {line}", part.lo + i as u64)),
            ),
        }
    }
    out
}

/// The next summary compaction should write for `targets`, children first:
/// the smallest missing range whose two children are known (a child is
/// known when it is one line or has a summary). `None` when every target
/// has a summary. The host asks the summarizer and stores the result, then
/// calls this again (the TypeScript `compact` loop, one step at a time).
pub fn next_compaction(store: &impl MemoryStore, targets: &[Range]) -> Option<CompactionStep> {
    fn visit(store: &impl MemoryStore, range: Range) -> Option<CompactionStep> {
        if range.size() == 1 || store.node(range).is_some() {
            return None;
        }
        let (left, right) = range.children();
        if let Some(step) = visit(store, left) {
            return Some(step);
        }
        if let Some(step) = visit(store, right) {
            return Some(step);
        }
        let text = |part: Range| {
            if part.size() == 1 {
                store.read(part.lo, part.lo + 1).into_iter().next().unwrap_or_default()
            } else {
                store.node(part).unwrap_or_default()
            }
        };
        Some(CompactionStep {
            range,
            left: text(left),
            right: text(right),
            level: range.size().trailing_zeros(),
        })
    }
    targets.iter().find_map(|range| visit(store, *range))
}

/// One summary to write: merge `left` and `right` into one line for `range`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactionStep {
    pub range: Range,
    pub left: String,
    pub right: String,
    pub level: u32,
}

/// A summarizer reply cut to one log line.
pub fn clip_summary(text: &str) -> String {
    to_lines(text).into_iter().next().unwrap_or_default()
}

/// The summarizer's instructions (same text as the TypeScript brain).
pub const SUMMARY_INSTRUCTIONS: &str = "You compress an agent's memory. Merge the two entries into ONE line of at most 280 characters. Keep names, numbers, dates, paths, decisions, preferences, open tasks and outcomes; drop chatter. Write it as a dense note, no preamble.";

#[cfg(test)]
mod tests {
    use super::*;

    fn store(n: usize) -> ArrayMemoryStore {
        ArrayMemoryStore {
            lines: (0..n).map(|i| format!("line {i}")).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn decompose_is_the_binary_expansion() {
        assert_eq!(decompose(0), vec![]);
        assert_eq!(decompose(1), vec![Range::new(0, 0)]);
        assert_eq!(decompose(11), vec![Range::new(0, 7), Range::new(8, 9), Range::new(10, 10)]);
    }

    #[test]
    fn wake_cover_splits_the_newest_block_within_budget() {
        assert_eq!(wake_cover(8, 1), vec![Range::new(0, 7)]);
        assert_eq!(wake_cover(8, 2), vec![Range::new(0, 3), Range::new(4, 7)]);
        assert_eq!(
            wake_cover(8, 4),
            vec![Range::new(0, 3), Range::new(4, 5), Range::new(6, 6), Range::new(7, 7)]
        );
        assert_eq!(wake_cover(3, 96).len(), 3);
    }

    #[test]
    fn wake_shows_children_of_missing_summaries() {
        let mut memory = store(4);
        let view = wake(&memory, 1);
        assert_eq!(view.text, "#0 line 0\n#1 line 1\n#2 line 2\n#3 line 3");
        assert_eq!(view.missing, vec![Range::new(0, 3)]);
        memory.nodes.insert(Range::new(0, 3), "four lines".into());
        let view = wake(&memory, 1);
        assert_eq!(view.text, "#0-3 four lines");
        assert!(view.missing.is_empty());
    }

    #[test]
    fn zoom_shows_child_summaries_or_numbered_lines() {
        let mut memory = store(8);
        memory.nodes.insert(Range::new(0, 3), "left".into());
        assert_eq!(
            zoom(&memory, Range::new(0, 7)),
            vec!["#0-3 left", "#4 line 4", "#5 line 5", "#6 line 6", "#7 line 7"]
        );
        assert_eq!(zoom(&memory, Range::new(2, 3)), vec!["line 2", "line 3"]);
        assert_eq!(zoom(&memory, Range::new(1, 4)), vec!["line 1", "line 2", "line 3", "line 4"]);
    }

    #[test]
    fn compaction_goes_children_first() {
        let mut memory = store(4);
        let step = next_compaction(&memory, &[Range::new(0, 3)]).unwrap();
        assert_eq!((step.range, step.left.as_str(), step.level), (Range::new(0, 1), "line 0", 1));
        memory.nodes.insert(Range::new(0, 1), "a".into());
        memory.nodes.insert(Range::new(2, 3), "b".into());
        let step = next_compaction(&memory, &[Range::new(0, 3)]).unwrap();
        assert_eq!(
            (step.range, step.left.as_str(), step.right.as_str()),
            (Range::new(0, 3), "a", "b")
        );
        memory.nodes.insert(Range::new(0, 3), "ab".into());
        assert_eq!(next_compaction(&memory, &[Range::new(0, 3)]), None);
    }

    #[test]
    fn to_lines_cuts_on_words_and_marks_the_cut() {
        assert!(to_lines("  \n ").is_empty());
        assert_eq!(to_lines("a \n b"), vec!["a b"]);
        let long = "word ".repeat(100);
        let lines = to_lines(&long);
        assert!(lines.len() > 1);
        for line in &lines[..lines.len() - 1] {
            assert!(line.len() <= MAX_LINE_BYTES, "{line}");
            assert!(line.ends_with("word…"), "{line}");
        }
        let wide = "é".repeat(300);
        for line in to_lines(&wide) {
            assert!(line.len() <= MAX_LINE_BYTES);
        }
    }

    #[test]
    fn range_parse() {
        assert_eq!(Range::parse("4-7"), Some(Range::new(4, 7)));
        assert_eq!(Range::parse("7-4"), None);
        assert_eq!(Range::parse("x"), None);
    }
}
