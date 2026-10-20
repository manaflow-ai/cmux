//! Names (workspaces, tabs, panes, file paths, pages, Chiefs) in memory, and
//! the fzf / VS Code style matcher that ranks them.

use std::collections::HashMap;
use std::ops::Range;

use crate::Kind;
use crate::context::Contexts;
use crate::fold::{fold, starts_word};

/// One name the window can find by fuzzy match.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct NameDoc {
    /// Unique; upserting a name with a key already present replaces it.
    pub key: String,
    pub kind: Kind,
    /// Where it jumps (a workspace, tab or pane id, a path, a URL). Its
    /// [`crate::TargetContext`], when set, also matches query words.
    pub target: String,
    /// The name shown and matched (a path for files).
    pub title: String,
    /// A second line (a workspace for a tab, a folder for a file, a URL).
    pub subtitle: String,
    /// Last use (or mtime for a file), for recency.
    pub at_ms: i64,
}

pub(crate) struct NameEntry {
    pub doc: NameDoc,
    folded: Vec<u8>,
    /// Where the basename starts in `folded` (after the last `/`).
    base: usize,
    mask: u64,
    /// Word starts in `folded`, camelCase humps included.
    starts: Vec<bool>,
}

/// How well a name matched one query.
pub(crate) struct NameMatch {
    pub tier: u8,
    pub quality: u32,
    /// Query words found in the target's context.
    pub context_words: u32,
    /// Byte ranges in the original title.
    pub highlights: Vec<Range<usize>>,
}

#[derive(Default)]
pub(crate) struct NameTable {
    entries: Vec<Option<NameEntry>>,
    by_key: HashMap<String, usize>,
    free: Vec<usize>,
}

impl NameTable {
    pub fn upsert(&mut self, doc: NameDoc) {
        let entry = NameEntry::new(doc);
        if let Some(&index) = self.by_key.get(&entry.doc.key) {
            self.entries[index] = Some(entry);
            return;
        }
        let key = entry.doc.key.clone();
        let index = match self.free.pop() {
            Some(index) => {
                self.entries[index] = Some(entry);
                index
            }
            None => {
                self.entries.push(Some(entry));
                self.entries.len() - 1
            }
        };
        self.by_key.insert(key, index);
    }

    pub fn remove(&mut self, key: &str) {
        if let Some(index) = self.by_key.remove(key) {
            self.entries[index] = None;
            self.free.push(index);
        }
    }

    pub fn len(&self) -> usize {
        self.by_key.len()
    }

    pub fn resident_bytes(&self) -> usize {
        self.iter()
            .map(|entry| {
                entry.doc.key.capacity() * 2
                    + entry.doc.target.capacity()
                    + entry.doc.title.capacity()
                    + entry.doc.subtitle.capacity()
                    + entry.folded.capacity()
                    + entry.starts.capacity()
                    + size_of::<NameEntry>()
                    + 48
            })
            .sum()
    }

    pub fn iter(&self) -> impl Iterator<Item = &NameEntry> {
        self.entries.iter().flatten()
    }

    /// Every live name of `kinds` (every kind when empty) whose title, or
    /// title and context together, match every one of `terms` (folded).
    pub fn matches<'a>(
        &'a self,
        terms: &'a [Vec<u8>],
        kinds: &'a [Kind],
        contexts: &'a Contexts,
    ) -> impl Iterator<Item = (&'a NameEntry, NameMatch)> + 'a {
        let mask = terms.iter().fold(0u64, |mask, term| mask | letters(term));
        self.iter()
            .filter(move |entry| kinds.is_empty() || kinds.contains(&entry.doc.kind))
            .filter_map(move |entry| {
                let context = contexts.get(&entry.doc.target);
                let present = entry.mask | context.map_or(0, |context| context.mask);
                if present & mask != mask {
                    return None;
                }
                entry
                    .match_terms(terms, context.map(|context| &context.folded[..]))
                    .map(|found| (entry, found))
            })
    }
}

impl NameEntry {
    fn new(doc: NameDoc) -> Self {
        let folded = fold(&doc.title).into_bytes();
        let base = if doc.kind == Kind::File {
            folded.iter().rposition(|&byte| byte == b'/').map_or(0, |slash| slash + 1)
        } else {
            0
        };
        let mask = letters(&folded);
        // Camel humps need the original case, which maps byte for byte only
        // for ASCII titles.
        let title = doc.title.as_bytes();
        let ascii = doc.title.is_ascii();
        let starts = (0..folded.len())
            .map(|index| {
                starts_word(&folded, index)
                    || (ascii
                        && index > 0
                        && title[index].is_ascii_uppercase()
                        && title[index - 1].is_ascii_lowercase())
            })
            .collect();
        Self { doc, folded, base, mask, starts }
    }

    /// Each term matches the title; a term that does not may match the
    /// context instead (then the tier is at most 3), but one term at least
    /// must match the title.
    fn match_terms(&self, terms: &[Vec<u8>], context: Option<&[u8]>) -> Option<NameMatch> {
        let mut tier = u8::MAX;
        let mut quality = 0u32;
        let mut in_title = 0u32;
        let mut context_words = 0u32;
        let mut ranges: Vec<Range<usize>> = Vec::new();
        for term in terms {
            let in_context =
                context.is_some_and(|context| memchr::memmem::find(context, term).is_some());
            match self.match_term(term) {
                Some((term_tier, term_quality, positions)) => {
                    tier = tier.min(term_tier);
                    quality += term_quality;
                    in_title += 1;
                    ranges.extend(positions);
                }
                None if in_context => tier = tier.min(3),
                None => return None,
            }
            context_words += u32::from(in_context);
        }
        if in_title == 0 {
            return None;
        }
        quality /= in_title;
        Some(NameMatch { tier, quality, context_words, highlights: self.original_ranges(ranges) })
    }

    /// (tier, quality 0..99, folded byte ranges) for one term. Quality falls
    /// with the name's length and with how far into it the match starts.
    fn match_term(&self, term: &[u8]) -> Option<(u8, u32, Vec<Range<usize>>)> {
        let name = &self.folded[..];
        let base = &name[self.base..];
        let length_quality = 99u32.saturating_sub((name.len() / 4) as u32);
        let at = |start: usize| length_quality.saturating_sub((start.min(60) / 3) as u32);
        if name == term || base == term || stem(base) == term {
            let start = if name == term { 0 } else { self.base };
            return Some((5, 99, one(start..start + term.len())));
        }
        if base.starts_with(term) {
            return Some((4, length_quality, one(self.base..self.base + term.len())));
        }
        if name.starts_with(term) {
            return Some((4, length_quality, one(0..term.len())));
        }
        let mut anywhere = None;
        for start in memchr::memmem::find_iter(name, term) {
            if self.starts[start] {
                let outside_base = if start >= self.base { 0 } else { 10 };
                return Some((
                    3,
                    at(start.saturating_sub(self.base)).saturating_sub(outside_base),
                    one(start..start + term.len()),
                ));
            }
            anywhere.get_or_insert(start);
        }
        if let Some(start) = anywhere {
            return Some((2, at(start), one(start..start + term.len())));
        }
        self.fuzzy(term).map(|(quality, ranges)| (1, quality, ranges))
    }

    /// Letters of `term` in order: the best of a greedy match from each of
    /// the first 16 places the first letter occurs.
    fn fuzzy(&self, term: &[u8]) -> Option<(u32, Vec<Range<usize>>)> {
        let name = &self.folded[..];
        let first = *term.first()?;
        let mut best: Option<(i64, Vec<usize>)> = None;
        for start in memchr::memchr_iter(first, name).take(16) {
            let mut positions = Vec::with_capacity(term.len());
            positions.push(start);
            let mut at = start + 1;
            let mut complete = true;
            for &byte in &term[1..] {
                let rest = &name[at..];
                // The next letter, unless a later word start holds it.
                let next_word_start = rest
                    .iter()
                    .enumerate()
                    .find(|&(offset, &candidate)| candidate == byte && self.starts[at + offset])
                    .map(|(offset, _)| offset)
                    .filter(|&offset| offset > 0 && rest.first() != Some(&byte));
                match next_word_start.or_else(|| memchr::memchr(byte, rest)) {
                    Some(offset) => {
                        positions.push(at + offset);
                        at += offset + 1;
                    }
                    None => {
                        complete = false;
                        break;
                    }
                }
            }
            if !complete {
                break;
            }
            let score = self.fuzzy_score(&positions);
            if best.as_ref().is_none_or(|(best_score, _)| score > *best_score) {
                best = Some((score, positions));
            }
        }
        let (score, positions) = best?;
        let max = 24 * term.len() as i64 + 10;
        let quality = ((score.max(0) * 99) / max.max(1)).clamp(0, 99) as u32;
        let ranges = positions.into_iter().map(|position| position..position + 1).collect();
        Some((quality, ranges))
    }

    fn fuzzy_score(&self, positions: &[usize]) -> i64 {
        let mut score = 0i64;
        let mut previous: Option<usize> = None;
        for &position in positions {
            if self.starts[position] {
                score += 16;
            }
            if self.base > 0 && position >= self.base {
                score += 2;
            }
            match previous {
                Some(previous) if position == previous + 1 => score += 8,
                Some(previous) => score -= ((position - previous - 1) as i64).min(8),
                None => score -= (position as i64 / 8).min(8),
            }
            previous = Some(position);
        }
        score
    }

    /// Folded byte ranges mapped to the original title, merged.
    fn original_ranges(&self, mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
        let title = &self.doc.title;
        let map: Vec<usize> = if title.is_ascii() {
            (0..=title.len()).collect()
        } else {
            crate::fold::fold_with_map(title).1
        };
        let last = map.len().saturating_sub(1);
        ranges.sort_by_key(|range| range.start);
        let mut merged: Vec<Range<usize>> = Vec::new();
        for range in ranges {
            let start = map[range.start.min(last)];
            let mut end = map[range.end.min(last)];
            if end <= start {
                end = next_char_end(title, start);
            }
            match merged.last_mut() {
                Some(previous) if start <= previous.end => previous.end = previous.end.max(end),
                _ => merged.push(start..end),
            }
        }
        merged
    }
}

/// One range as a list (the shape every match returns).
fn one(range: Range<usize>) -> Vec<Range<usize>> {
    std::iter::once(range).collect()
}

fn next_char_end(text: &str, start: usize) -> usize {
    text.get(start..).and_then(|rest| rest.chars().next()).map_or(start, |ch| start + ch.len_utf8())
}

/// `name` without its last extension (`main.rs` -> `main`).
fn stem(name: &[u8]) -> &[u8] {
    match name.iter().rposition(|&byte| byte == b'.') {
        Some(dot) if dot > 0 => &name[..dot],
        _ => name,
    }
}

/// A bit per letter or digit class present in `text`.
pub(crate) fn letters(text: &[u8]) -> u64 {
    let mut mask = 0u64;
    for &byte in text {
        let bit = match byte {
            b'a'..=b'z' => byte - b'a',
            b'0'..=b'9' => 26 + byte - b'0',
            b' ' | b'\n' => continue,
            0x80..=0xFF => 63,
            other => 36 + other % 26,
        };
        mask |= 1 << bit;
    }
    mask
}
