//! Names (workspaces, tabs, panes, file paths, pages, Chiefs) in memory, and
//! the fzf / VS Code style matcher that ranks them.

use std::collections::HashMap;
use std::ops::Range;

use crate::Kind;
use crate::fold::{fold, starts_word};

/// One name the window can find by fuzzy match.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct NameDoc {
    /// Unique; upserting a name with a key already present replaces it.
    pub key: String,
    pub kind: Kind,
    /// Where it jumps (a workspace, tab or pane id, a path, a URL).
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

    pub fn iter(&self) -> impl Iterator<Item = &NameEntry> {
        self.entries.iter().flatten()
    }

    /// Every live name matching `terms` (folded, non-empty) of `kinds`
    /// (every kind when empty).
    pub fn matches<'a>(
        &'a self,
        terms: &'a [Vec<u8>],
        kinds: &'a [Kind],
    ) -> impl Iterator<Item = (&'a NameEntry, NameMatch)> + 'a {
        let mask = terms.iter().fold(0u64, |mask, term| mask | letters(term));
        self.iter()
            .filter(move |entry| kinds.is_empty() || kinds.contains(&entry.doc.kind))
            .filter(move |entry| entry.mask & mask == mask)
            .filter_map(move |entry| entry.match_terms(terms).map(|found| (entry, found)))
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
        // Camel humps need the original case, which only maps byte for byte
        // when folding kept the length (ASCII titles).
        let title = doc.title.as_bytes();
        let same = doc.title.is_ascii();
        let starts = (0..folded.len())
            .map(|index| {
                starts_word(&folded, index)
                    || (same
                        && index > 0
                        && title[index].is_ascii_uppercase()
                        && title[index - 1].is_ascii_lowercase())
            })
            .collect();
        Self { doc, folded, base, mask, starts }
    }

    fn match_terms(&self, terms: &[Vec<u8>]) -> Option<NameMatch> {
        let mut tier = u8::MAX;
        let mut quality = 0u32;
        let mut ranges: Vec<Range<usize>> = Vec::new();
        for term in terms {
            let (term_tier, term_quality, positions) = self.match_term(term)?;
            tier = tier.min(term_tier);
            quality += term_quality;
            ranges.extend(positions);
        }
        quality /= terms.len().max(1) as u32;
        Some(NameMatch { tier, quality, highlights: self.original_ranges(ranges) })
    }

    /// (tier, quality 0..99, folded byte ranges) for one term.
    fn match_term(&self, term: &[u8]) -> Option<(u8, u32, Vec<Range<usize>>)> {
        let name = &self.folded[..];
        let base = &name[self.base..];
        let length_quality = 99u32.saturating_sub((name.len() / 4) as u32);
        if name == term || base == term || stem(base) == term {
            let start = if name == term { 0 } else { self.base };
            return Some((5, 99, vec![start..start + term.len()]));
        }
        if base.starts_with(term) {
            return Some((4, length_quality, vec![self.base..self.base + term.len()]));
        }
        if name.starts_with(term) {
            return Some((4, length_quality, vec![0..term.len()]));
        }
        let mut anywhere = None;
        for start in memchr::memmem::find_iter(name, term) {
            if self.starts[start] {
                let bonus = if start >= self.base { 0 } else { 10 };
                return Some((
                    3,
                    length_quality.saturating_sub(bonus),
                    vec![start..start + term.len()],
                ));
            }
            anywhere.get_or_insert(start);
        }
        if let Some(start) = anywhere {
            return Some((2, length_quality, vec![start..start + term.len()]));
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
            let mut ok = true;
            for &byte in &term[1..] {
                // Prefer the next word start holding the letter, else the next letter.
                let rest = &name[at..];
                let next = rest
                    .iter()
                    .enumerate()
                    .find(|&(offset, &candidate)| candidate == byte && self.starts[at + offset])
                    .map(|(offset, _)| offset)
                    .filter(|&offset| offset > 0 && rest[0] != byte)
                    .or_else(|| memchr::memchr(byte, rest));
                match next {
                    Some(offset) => {
                        positions.push(at + offset);
                        at += offset + 1;
                    }
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if !ok {
                break;
            }
            let score = self.fuzzy_score(&positions);
            if best.as_ref().is_none_or(|(best_score, _)| score > *best_score) {
                best = Some((score, positions));
            }
        }
        let (score, positions) = best?;
        let max = 16 * term.len() as i64 + 8 * term.len() as i64 + 10;
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
            if position >= self.base && self.base > 0 {
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
        ranges.sort_by_key(|range| range.start);
        let mut merged: Vec<Range<usize>> = Vec::new();
        for range in ranges {
            let start = map[range.start.min(map.len() - 1)];
            let mut end = map[range.end.min(map.len() - 1)];
            if end <= start {
                end = next_char_end(title, start);
            }
            match merged.last_mut() {
                Some(last) if start <= last.end => last.end = last.end.max(end),
                _ => merged.push(start..end),
            }
        }
        merged
    }
}

fn next_char_end(text: &str, start: usize) -> usize {
    text[start..].chars().next().map_or(start, |ch| start + ch.len_utf8())
}

/// `name` without its last extension (`main.rs` -> `main`).
fn stem(name: &[u8]) -> &[u8] {
    match name.iter().rposition(|&byte| byte == b'.') {
        Some(dot) if dot > 0 => &name[..dot],
        _ => name,
    }
}

/// A bit per letter or digit class present in `text`.
fn letters(text: &[u8]) -> u64 {
    let mut mask = 0u64;
    for &byte in text {
        let bit = match byte {
            b'a'..=b'z' => byte - b'a',
            b'0'..=b'9' => 26 + byte - b'0',
            b' ' => continue,
            0x80..=0xFF => 63,
            other => 36 + other % 26,
        };
        mask |= 1 << bit;
    }
    mask
}
