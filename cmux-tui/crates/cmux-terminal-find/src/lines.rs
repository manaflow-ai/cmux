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
        let found: Vec<(usize, usize)> = matcher.ranges(line).collect();
        for &(start, end) in found.iter().rev() {
            if out.len() == max_matches {
                return (out, true);
            }
            let (snippet, snippet_start, snippet_len) = snippet(line, start, end);
            out.push(LineMatch {
                line: index,
                start: utf16_len(&line[..start]),
                len: utf16_len(&line[start..end]),
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
    let matched = &line[start..end];
    let room = SNIPPET_CHARS.saturating_sub(matched.chars().count());
    // A third of the room before the match, the rest after it: what follows a hit reads on.
    let before_room = room / 3;
    let before: Vec<char> = line[..start].chars().collect();
    let take_before = before.len().min(before_room);
    let after_room = room - take_before;
    let lead: String = before[before.len() - take_before..].iter().collect();
    let lead = lead.trim_start();
    let tail: String = line[end..].chars().take(after_room).collect();
    let tail = tail.trim_end();
    let text = format!("{lead}{matched}{tail}");
    (text, utf16_len(lead), utf16_len(matched))
}
