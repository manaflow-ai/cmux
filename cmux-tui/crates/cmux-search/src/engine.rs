//! The engine: appends, names, removal, and one ranked query over all of it.

use std::collections::HashMap;
use std::ops::Range;
use std::time::{Duration, Instant};

use memchr::memmem::Finder;

use crate::Kind;
use crate::fold::{ends_word, fold, fold_into, fold_with_map, starts_word};
use crate::frecency::Frecency;
use crate::names::{NameDoc, NameTable};
use crate::segment::{DocMeta, LiveScratch, NONE_I64, NONE_U32, Segment};
use crate::trigram;

/// Sizes the engine packs and seals at.
#[derive(Clone, Copy, Debug)]
pub struct EngineConfig {
    /// Text per block, the posting unit (16 KiB).
    pub block_bytes: usize,
    /// Text per segment before it is sealed (64 MiB).
    pub segment_bytes: usize,
    /// A longer doc is cut to this many bytes (1 MiB).
    pub max_doc_bytes: usize,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self { block_bytes: 16 * 1024, segment_bytes: 64 * 1024 * 1024, max_doc_bytes: 1 << 20 }
    }
}

/// One content doc to index.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Doc {
    pub kind: Kind,
    /// The unit [`SearchEngine::remove_source`] drops (`term:<id>`, `acp:<session>`).
    pub source: String,
    /// Where a hit jumps (a terminal, a chat session, a Chief, a path).
    pub target: String,
    /// The first line (scrollback), the turn (chat), the frame time (screen).
    pub position: Option<i64>,
    /// The row label (the terminal, chat or Chief name).
    pub title: String,
    /// The text; may hold several lines.
    pub text: String,
    pub at_ms: i64,
    /// Set for docs that can change (a Chief memory entry): appending a doc
    /// with a key already present replaces the old one.
    pub key: Option<String>,
}

/// A query.
#[derive(Clone, Debug)]
pub struct Query {
    /// Words (all must match); `"quoted words"` match as one phrase.
    pub text: String,
    /// The kinds to search; empty: every kind.
    pub kinds: Vec<Kind>,
    pub limit: usize,
    /// Now, for recency and frecency.
    pub now_ms: i64,
    /// Content scanning stops after this long and the result is `partial`.
    pub budget: Option<Duration>,
}

impl Query {
    /// A query over every kind, 50 hits, no time budget.
    pub fn new(text: impl Into<String>, now_ms: i64) -> Self {
        Self { text: text.into(), kinds: Vec::new(), limit: 50, now_ms, budget: None }
    }
}

/// One hit, names and content alike.
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub kind: Kind,
    /// The doc's source; the name's key for a name hit.
    pub source: String,
    pub target: String,
    pub position: Option<i64>,
    /// The hit line's offset from the doc's first line (0 for names).
    pub line: u32,
    pub title: String,
    /// A name hit's second line; empty for content.
    pub subtitle: String,
    /// The matched line (content) or the name.
    pub snippet: String,
    /// Byte ranges of the matched text in `snippet`.
    pub highlights: Vec<Range<usize>>,
    pub at_ms: i64,
    /// The match tier, 1 (letters somewhere) to 5 (exact): design 7.3.
    pub tier: u8,
    pub score: f64,
    /// Whether it is a name (true) or content (false).
    pub is_name: bool,
}

/// The ranked hits of one query.
#[derive(Clone, Debug, Default)]
pub struct SearchResult {
    pub hits: Vec<Hit>,
    /// The time budget ran out before every segment was scanned.
    pub partial: bool,
    pub took: Duration,
}

/// Index size and shape.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub docs: usize,
    pub blocks: usize,
    pub segments: usize,
    pub text_bytes: usize,
    /// Postings, doc and block tables (not the text).
    pub index_bytes: usize,
    pub names: usize,
}

/// The search-everything index. One owner writes it (the daemon's search
/// thread); queries take `&self`.
pub struct SearchEngine {
    pub(crate) config: EngineConfig,
    pub(crate) segments: Vec<Segment>,
    pub(crate) strings: Vec<String>,
    pub(crate) string_ids: HashMap<String, u32>,
    /// A flag per string id: the source with this id was removed.
    pub(crate) removed: Vec<bool>,
    pub(crate) keyed: HashMap<String, (u32, u32)>,
    pub(crate) names: NameTable,
    pub(crate) frecency: Frecency,
    scratch: LiveScratch,
}

/// A content candidate: segment and doc.
#[derive(Clone, Copy)]
struct Found {
    segment: u32,
    doc: u32,
}

const DAY_MS: f64 = 86_400_000.0;

impl SearchEngine {
    pub fn new(config: EngineConfig) -> Self {
        Self {
            config,
            segments: vec![Segment::new_live()],
            strings: Vec::new(),
            string_ids: HashMap::new(),
            removed: Vec::new(),
            keyed: HashMap::new(),
            names: NameTable::default(),
            frecency: Frecency::default(),
            scratch: LiveScratch::new(),
        }
    }

    pub(crate) fn intern(&mut self, value: &str) -> u32 {
        if let Some(&id) = self.string_ids.get(value) {
            return id;
        }
        let id = self.strings.len() as u32;
        self.strings.push(value.to_owned());
        self.removed.push(false);
        self.string_ids.insert(value.to_owned(), id);
        id
    }

    /// Indexes `doc`. A keyed doc replaces the doc with its key.
    pub fn append(&mut self, doc: Doc) {
        let mut text = doc.text.as_str();
        if text.len() > self.config.max_doc_bytes {
            let mut end = self.config.max_doc_bytes;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            text = &text[..end];
        }
        if let Some(key) = &doc.key {
            self.remove_key(key);
        }
        let meta = DocMeta {
            kind: doc.kind.code(),
            source: self.intern(&doc.source),
            target: self.intern(&doc.target),
            title: self.intern(&doc.title),
            key: doc.key.as_deref().map_or(NONE_U32, |key| self.intern(key)),
            position: doc.position.unwrap_or(NONE_I64),
            at_ms: doc.at_ms,
            start: 0,
            len: 0,
        };
        let segment = self.segments.len() - 1;
        let live = &mut self.segments[segment];
        let index = live.append(meta, text, self.config.block_bytes, &mut self.scratch);
        if let (Some(key), Some(index)) = (doc.key, index) {
            self.keyed.insert(key, (segment as u32, index));
        }
        if self.segments[segment].text_len() >= self.config.segment_bytes {
            self.seal();
        }
    }

    /// Seals the live segment (when it holds docs) and opens a new one.
    pub fn seal(&mut self) {
        let last = self.segments.len() - 1;
        if self.segments[last].docs.is_empty() {
            return;
        }
        self.segments[last].seal(&mut self.scratch);
        self.segments.push(Segment::new_live());
    }

    /// Drops the doc appended with `key`.
    pub fn remove_key(&mut self, key: &str) {
        if let Some((segment, doc)) = self.keyed.remove(key) {
            self.segments[segment as usize].delete(doc);
        }
    }

    /// Drops every doc of `source` appended so far (a purged chat, a cleared
    /// terminal). Docs appended later with the same source are kept.
    pub fn remove_source(&mut self, source: &str) {
        if let Some(id) = self.string_ids.remove(source) {
            self.removed[id as usize] = true;
        }
    }

    /// Adds or replaces a name.
    pub fn upsert_name(&mut self, name: NameDoc) {
        self.names.upsert(name);
    }

    /// Drops the name with `key`.
    pub fn remove_name(&mut self, key: &str) {
        self.names.remove(key);
    }

    /// Records that the user opened a hit jumping to `target`.
    pub fn record_open(&mut self, target: &str, now_ms: i64) {
        self.frecency.record(target, now_ms);
    }

    pub fn stats(&self) -> Stats {
        let mut stats = Stats {
            segments: self.segments.iter().filter(|segment| !segment.docs.is_empty()).count(),
            names: self.names.len(),
            ..Stats::default()
        };
        for segment in &self.segments {
            stats.docs += segment.docs.len();
            stats.blocks += segment.blocks.len();
            stats.text_bytes += segment.text_len();
            stats.index_bytes += segment.index_bytes();
        }
        stats
    }

    /// The best `query.limit` hits over names and content, best first.
    pub fn search(&self, query: &Query) -> SearchResult {
        // Red: the query path is not written yet.
        let _ = (query, parse_words, Self::search_names, Self::search_content);
        SearchResult::default()
    }

    fn search_names(&self, words: &[Vec<u8>], query: &Query) -> Vec<Hit> {
        let mut hits: Vec<Hit> = self
            .names
            .matches(words, &query.kinds)
            .map(|(entry, found)| {
                let doc = &entry.doc;
                let score = score(
                    found.tier,
                    doc.kind,
                    doc.at_ms,
                    query.now_ms,
                    self.frecency.bonus(&doc.target, query.now_ms),
                ) + f64::from(found.quality) / 3.0;
                Hit {
                    kind: doc.kind,
                    source: doc.key.clone(),
                    target: doc.target.clone(),
                    position: None,
                    line: 0,
                    title: doc.title.clone(),
                    subtitle: doc.subtitle.clone(),
                    snippet: doc.title.clone(),
                    highlights: found.highlights,
                    at_ms: doc.at_ms,
                    tier: found.tier,
                    score,
                    is_name: true,
                }
            })
            .collect();
        hits.sort_by(|a, b| b.score.total_cmp(&a.score));
        hits.truncate(query.limit);
        hits
    }

    /// Content hits (newest first, up to 4x the limit, then ranked), and
    /// whether the budget cut the scan.
    fn search_content(
        &self,
        words: &[Vec<u8>],
        query: &Query,
        started: Instant,
    ) -> (Vec<Hit>, bool) {
        if !words.iter().any(|word| word.len() >= 3) {
            return (Vec::new(), false);
        }
        let mut kind_mask: u16 = 0;
        for kind in &query.kinds {
            kind_mask |= 1 << kind.code();
        }
        if query.kinds.is_empty() {
            kind_mask = u16::MAX;
        }
        let mut keys: Vec<u32> = words
            .iter()
            .filter(|word| word.len() >= 3)
            .flat_map(|word| trigram::distinct(word))
            .collect();
        keys.sort_unstable();
        keys.dedup();
        let finders: Vec<Finder<'_>> = words.iter().map(Finder::new).collect();
        let want = query.limit.saturating_mul(4).max(query.limit);
        let mut found: Vec<Found> = Vec::new();
        let mut folded = Vec::new();
        let mut buffer = Vec::new();
        let mut partial = false;
        'segments: for (segment_index, segment) in self.segments.iter().enumerate().rev() {
            let candidates = match segment.candidates(&keys, &mut buffer) {
                Some(candidates) => candidates,
                None => (0..segment.blocks.len() as u32).collect(),
            };
            for &block_id in candidates.iter().rev() {
                if let Some(budget) = query.budget
                    && started.elapsed() > budget
                {
                    partial = true;
                    break 'segments;
                }
                let block = segment.blocks[block_id as usize];
                if block.kinds & kind_mask == 0 {
                    continue;
                }
                for doc_index in (block.first_doc..block.end_doc).rev() {
                    let doc = &segment.docs[doc_index as usize];
                    if kind_mask & (1 << doc.kind) == 0
                        || segment.is_deleted(doc_index)
                        || self.removed[doc.source as usize]
                    {
                        continue;
                    }
                    fold_into(segment.doc_text(doc), &mut folded);
                    if finders.iter().all(|finder| finder.find(&folded).is_some()) {
                        found.push(Found { segment: segment_index as u32, doc: doc_index });
                        if found.len() >= want {
                            break 'segments;
                        }
                    }
                }
            }
        }
        let mut hits: Vec<Hit> =
            found.into_iter().filter_map(|found| self.content_hit(found, words, query)).collect();
        hits.sort_by(|a, b| b.score.total_cmp(&a.score));
        hits.truncate(query.limit);
        (hits, partial)
    }

    fn content_hit(&self, found: Found, words: &[Vec<u8>], query: &Query) -> Option<Hit> {
        let segment = &self.segments[found.segment as usize];
        let doc = &segment.docs[found.doc as usize];
        let kind = Kind::from_code(doc.kind)?;
        let text = segment.doc_text(doc);
        let (folded, map) = fold_with_map(text);
        let phrase = join_words(words);
        let (tier, at) = content_tier(&folded, words, &phrase);
        let line = folded[..at].iter().filter(|&&byte| byte == b'\n').count() as u32;
        let (snippet, highlights) = snippet(text, &map, at, words);
        let target = self.strings[doc.target as usize].clone();
        let bonus = self.frecency.bonus(&target, query.now_ms);
        Some(Hit {
            kind,
            source: self.strings[doc.source as usize].clone(),
            target,
            position: (doc.position != NONE_I64).then_some(doc.position),
            line,
            title: self.strings[doc.title as usize].clone(),
            subtitle: String::new(),
            snippet,
            highlights,
            at_ms: doc.at_ms,
            tier,
            score: score(tier, kind, doc.at_ms, query.now_ms, bonus),
            is_name: false,
        })
    }
}

/// Folded words of `text`: whitespace splits, `"..."` keeps a phrase.
pub(crate) fn parse_words(text: &str) -> Vec<Vec<u8>> {
    let mut words = Vec::new();
    for (index, part) in text.split('"').enumerate() {
        if index % 2 == 1 {
            let phrase = fold(part.trim());
            if !phrase.is_empty() {
                words.push(phrase.into_bytes());
            }
        } else {
            words.extend(part.split_whitespace().map(|word| fold(word).into_bytes()));
        }
    }
    words.retain(|word| !word.is_empty());
    words
}

fn join_words(words: &[Vec<u8>]) -> Vec<u8> {
    let mut phrase = Vec::new();
    for (index, word) in words.iter().enumerate() {
        if index > 0 {
            phrase.push(b' ');
        }
        phrase.extend_from_slice(word);
    }
    phrase
}

/// The tier of a content match (design 7.3) and the folded offset to show.
fn content_tier(folded: &[u8], words: &[Vec<u8>], phrase: &[u8]) -> (u8, usize) {
    let mut line_start = 0;
    for line in folded.split(|&byte| byte == b'\n') {
        if line.trim_ascii() == phrase {
            let lead = line.len() - line.trim_ascii_start().len();
            return (5, line_start + lead);
        }
        line_start += line.len() + 1;
    }
    let mut phrase_at = None;
    for at in memchr::memmem::find_iter(folded, phrase) {
        if starts_word(folded, at) && ends_word(folded, at + phrase.len()) {
            return (4, at);
        }
        phrase_at.get_or_insert(at);
    }
    let mut first_word_at = None;
    let all_start = words.iter().all(|word| {
        let mut any = None;
        for at in memchr::memmem::find_iter(folded, word) {
            any.get_or_insert(at);
            if starts_word(folded, at) {
                first_word_at.get_or_insert(at);
                return true;
            }
        }
        first_word_at.get_or_insert(any.unwrap_or(0));
        false
    });
    if all_start {
        return (3, phrase_at.or(first_word_at).unwrap_or(0));
    }
    if let Some(at) = phrase_at {
        return (2, at);
    }
    let at = memchr::memmem::find(folded, &words[0]).unwrap_or(0);
    (1, at)
}

/// The original line around folded offset `at`, cut to about 240 bytes,
/// and the byte ranges of every word in it.
fn snippet(text: &str, map: &[usize], at: usize, words: &[Vec<u8>]) -> (String, Vec<Range<usize>>) {
    let at = map[at.min(map.len() - 1)];
    let line_start = text[..at].rfind('\n').map_or(0, |newline| newline + 1);
    let line_end = text[at..].find('\n').map_or(text.len(), |newline| at + newline);
    let mut start = line_start;
    let mut end = line_end;
    if end - start > 240 {
        start = at.saturating_sub(80).max(line_start);
        while !text.is_char_boundary(start) {
            start += 1;
        }
        end = (start + 240).min(line_end);
        while !text.is_char_boundary(end) {
            end -= 1;
        }
    }
    let core = text[start..end].trim_end_matches('\r');
    let prefix = if start > line_start { "…" } else { "" };
    let suffix = if end < line_end { "…" } else { "" };
    let (folded, core_map) = fold_with_map(core);
    let mut ranges: Vec<Range<usize>> = Vec::new();
    for word in words {
        for found in memchr::memmem::find_iter(&folded, word) {
            let from = core_map[found] + prefix.len();
            let to = core_map[(found + word.len()).min(core_map.len() - 1)] + prefix.len();
            if to > from {
                ranges.push(from..to);
            }
        }
    }
    ranges.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    (format!("{prefix}{core}{suffix}"), merged)
}

/// Design 7.3: tier x 1000 + (weight - 1) x 500 + 400 x recency + frecency.
fn score(tier: u8, kind: Kind, at_ms: i64, now_ms: i64, frecency: f64) -> f64 {
    let age_days = (now_ms - at_ms).max(0) as f64 / DAY_MS;
    let recency = (-age_days / 7.0).exp();
    f64::from(tier) * 1000.0 + (kind.weight() - 1.0) * 500.0 + 400.0 * recency + frecency
}
