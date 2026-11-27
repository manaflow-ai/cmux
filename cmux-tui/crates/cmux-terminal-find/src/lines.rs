//! Matches in plain text lines (persisted output and transcript text past the scrollback), and
//! the snippet every match carries.

use serde::Serialize;

use crate::SNIPPET_CHARS;
use crate::matcher::Matcher;

/// One match in a list of lines.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LineMatch {
    /// The line's index in the list given.
    pub line: usize,
    /// The match's place in the line, in UTF-16 units.
    pub start: u32,
    pub len: u32,
    pub snippet: String,
    pub snippet_start: u32,
    pub snippet_len: u32,
}

/// Every match in `lines`, newest first: the last line first, right to left within a line, at
/// most `max_matches`. The second value is true when more matches were left out.
pub fn find_in_lines<S: AsRef<str>>(
    matcher: &Matcher,
    lines: &[S],
    max_matches: usize,
) -> (Vec<LineMatch>, bool) {
    let mut out = Vec::new();
    for (index, line) in lines.iter().enumerate().rev() {
        let line = line.as_ref();
        // Each match's UTF-16 offset, counted on from the previous match's end: one pass over
        // the line, not a count from the line's start per match (quadratic on a long line).
        let mut found: Vec<(usize, usize, u32)> = Vec::new();
        let (mut counted_to, mut offset) = (0usize, 0u32);
        for (start, end) in matcher.ranges(line) {
            offset =
                offset.saturating_add(utf16_len(line.get(counted_to..start).unwrap_or_default()));
            counted_to = start;
            found.push((start, end, offset));
        }
        for &(start, end, start16) in found.iter().rev() {
            if out.len() == max_matches {
                return (out, true);
            }
            let (snippet, snippet_start, snippet_len) = snippet(line, start, end);
            out.push(LineMatch {
                line: index,
                start: start16,
                len: utf16_len(line.get(start..end).unwrap_or_default()),
                snippet,
                snippet_start,
                snippet_len,
            });
        }
    }
    (out, false)
}

fn utf16_len(text: &str) -> u32 {
    u32::try_from(text.encode_utf16().count()).unwrap_or(u32::MAX)
}

/// The part of `line` around bytes `start..end`, at most [`SNIPPET_CHARS`] characters (more
/// only when the match itself is longer), trimmed of leading blanks, with the match's offset
/// and length in the snippet in UTF-16 units.
pub(crate) fn snippet(line: &str, start: usize, end: usize) -> (String, u32, u32) {
    // `start..end` come from the matcher's ranges, on char boundaries; an empty snippet is the
    // fallback, never a panic.
    let matched = line.get(start..end).unwrap_or_default();
    let room = SNIPPET_CHARS.saturating_sub(matched.chars().count());
    // A third of the room before the match, the rest after it: what follows a hit reads on.
    let before_room = room / 3;
    // Walk back from the match at most `before_room` characters: the snippet costs its own
    // length, never the line's (a find over a long soft-wrapped line reports many matches).
    let before = line.get(..start).unwrap_or_default();
    let lead_start =
        before.char_indices().rev().take(before_room).last().map_or(start, |(at, _)| at);
    let lead = before.get(lead_start..).unwrap_or_default();
    let take_before = lead.chars().count();
    let after_room = room.saturating_sub(take_before);
    let lead = lead.trim_start();
    let tail: String = line.get(end..).unwrap_or_default().chars().take(after_room).collect();
    let tail = tail.trim_end();
    let text = format!("{lead}{matched}{tail}");
    (text, utf16_len(lead), utf16_len(matched))
}
