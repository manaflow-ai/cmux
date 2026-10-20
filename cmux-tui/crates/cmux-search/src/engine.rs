//! The engine: appends, names, contexts, removal, and one ranked query over
//! all of it.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use memchr::memmem::Finder;

use crate::Kind;
use crate::context::{ContextEntry, Contexts, TargetContext};
use crate::fold::{ends_word, fold, fold_into, fold_with_map, starts_word};
use crate::frecency::{FOCUS, Frecency, OPENS};
use crate::names::{NameDoc, NameTable};
use crate::segment::{BlockData, DocMeta, Live, LiveScratch, NONE_I64, NONE_U32, Segment};
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
    /// Where a hit jumps (a terminal, a chat session, a Chief, a path). Its
    /// [`TargetContext`] (set with [`SearchEngine::set_context`]) also
    /// matches query words and ranks the hit.
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
    /// Now, for recency, frecency and focus.
    pub now_ms: i64,
    /// Content scanning stops after this long and the result is `partial`.
    pub budget: Option<Duration>,
    /// The workspace the user is in: its hits rank higher.
    pub workspace_id: Option<String>,
}

impl Query {
    /// A query over every kind, 50 hits, no time budget.
    pub fn new(text: impl Into<String>, now_ms: i64) -> Self {
        Self {
            text: text.into(),
            kinds: Vec::new(),
            limit: 50,
            now_ms,
            budget: None,
            workspace_id: None,
        }
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
    /// Postings, doc and block tables (not the text), memory and disk.
    pub index_bytes: usize,
    /// Bytes the engine holds in process memory (the page cache aside).
    pub resident_bytes: usize,
    pub names: usize,
    pub contexts: usize,
    /// Reads of sealed segments that failed (a damaged file); the blocks
    /// they cover are skipped.
    pub read_errors: usize,
}

/// The search-everything index. One owner writes it (the daemon's search
/// thread); queries take `&self`.
pub struct SearchEngine {
    pub(crate) config: EngineConfig,
    /// Sealed segment files go here; `None`: they stay in memory.
    pub(crate) dir: Option<PathBuf>,
    pub(crate) segments: Vec<Segment>,
    pub(crate) next_segment: u64,
    pub(crate) strings: Vec<String>,
    pub(crate) string_ids: HashMap<String, u32>,
    /// A flag per string id: the source with this id was removed.
    pub(crate) removed: Vec<bool>,
    /// Key -> (segment id, doc).
    pub(crate) keyed: HashMap<String, (u64, u32)>,
    pub(crate) names: NameTable,
    pub(crate) contexts: Contexts,
    pub(crate) opens: Frecency,
    pub(crate) focus: Frecency,
    pub(crate) read_errors: std::sync::atomic::AtomicUsize,
    scratch: LiveScratch,
}

/// A content candidate, copied out of its block.
struct Found {
    meta: DocMeta,
    text: String,
}

const DAY_MS: f64 = 86_400_000.0;

impl SearchEngine {
    /// An engine that keeps everything in memory (tests, benches).
    pub fn new(config: EngineConfig) -> Self {
        Self {
            config,
            dir: None,
            segments: vec![Segment::Live(Live::new(0))],
            next_segment: 1,
            strings: Vec::new(),
            string_ids: HashMap::new(),
            removed: Vec::new(),
            keyed: HashMap::new(),
            names: NameTable::default(),
            contexts: Contexts::default(),
            opens: Frecency::default(),
            focus: Frecency::default(),
            read_errors: std::sync::atomic::AtomicUsize::new(0),
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

    /// Indexes `doc`. A keyed doc replaces the doc with its key. Cost: the
    /// doc's own text (fold + trigrams); never a rescan.
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
        let block_bytes = self.config.block_bytes;
        let segment_bytes = self.config.segment_bytes;
        let scratch = &mut self.scratch;
        let appended = match self.segments.last_mut() {
            Some(Segment::Live(live)) => {
                let index = live.append(meta, text, block_bytes, scratch);
                Some((live.id, index, live.text_len() >= segment_bytes))
            }
            _ => None,
        };
        if let Some((segment, index, full)) = appended {
            if let Some(key) = doc.key {
                self.keyed.insert(key, (segment, index));
            }
            if full {
                self.seal();
            }
        }
    }

    /// Seals the live segment (when it holds docs) and opens a new one. With
    /// an index directory the sealed image goes to a file and leaves memory.
    pub fn seal(&mut self) {
        let Some(Segment::Live(live)) = self.segments.last() else { return };
        if live.doc_count() == 0 {
            return;
        }
        let image = live.encode(&mut self.scratch);
        let deleted = live.deleted().to_vec();
        let id = live.id;
        let store = crate::persist::store_image(self.dir.as_deref(), id, image);
        match crate::segment::Sealed::open(id, store, deleted) {
            Ok(sealed) => {
                if let Some(last) = self.segments.last_mut() {
                    *last = Segment::Sealed(sealed);
                }
                self.segments.push(Segment::Live(Live::new(self.next_segment)));
                self.next_segment += 1;
            }
            // The image could not be read back: keep the live segment.
            Err(_) => {
                self.read_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            }
        }
    }

    /// Drops the doc appended with `key`.
    pub fn remove_key(&mut self, key: &str) {
        if let Some((segment_id, doc)) = self.keyed.remove(key)
            && let Some(segment) =
                self.segments.iter_mut().find(|segment| segment.id() == segment_id)
        {
            segment.delete(doc);
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

    /// Sets what surrounds `target` (workspace, group, title, folder,
    /// branch, agent).
    pub fn set_context(&mut self, target: &str, context: TargetContext) {
        self.contexts.entries.insert(target.to_owned(), ContextEntry::new(context));
    }

    pub fn remove_context(&mut self, target: &str) {
        self.contexts.entries.remove(target);
    }

    /// Records that the user opened a hit jumping to `target`.
    pub fn record_open(&mut self, target: &str, now_ms: i64) {
        self.opens.record(target, now_ms, OPENS);
    }

    /// Records that the user focused `target` (a tab, pane, terminal or
    /// chat), the focus history signal.
    pub fn record_focus(&mut self, target: &str, now_ms: i64) {
        self.focus.record(target, now_ms, FOCUS);
    }

    pub fn stats(&self) -> Stats {
        let mut stats = Stats {
            segments: self.segments.iter().filter(|segment| segment.doc_count() > 0).count(),
            names: self.names.len(),
            contexts: self.contexts.entries.len(),
            read_errors: self.read_errors.load(std::sync::atomic::Ordering::Relaxed),
            ..Stats::default()
        };
        for segment in &self.segments {
            stats.docs += segment.doc_count();
            stats.blocks += segment.blocks().len();
            stats.text_bytes += segment.text_len();
            stats.index_bytes += segment.index_bytes();
            stats.resident_bytes += segment.resident_bytes();
        }
        stats.resident_bytes += self.names.resident_bytes()
            + self.strings.iter().map(|value| value.capacity() * 2 + 48).sum::<usize>()
            + self
                .contexts
                .entries
                .values()
                .map(|entry| entry.folded.capacity() * 2 + 96)
                .sum::<usize>()
            + self.scratch.resident_bytes();
        stats
    }

    /// The best `query.limit` hits over names and content, best first.
    pub fn search(&self, query: &Query) -> SearchResult {
        let started = Instant::now();
        let words = parse_words(&query.text);
        if words.is_empty() || query.limit == 0 {
            return SearchResult { took: started.elapsed(), ..SearchResult::default() };
        }
        let mut hits = self.search_names(&words, query);
        let (content, partial) = self.search_content(&words, query, started);
        hits.extend(content);
        hits.sort_by(|a, b| b.score.total_cmp(&a.score).then(b.at_ms.cmp(&a.at_ms)));
        hits.truncate(query.limit);
        SearchResult { hits, partial, took: started.elapsed() }
    }

    fn signals(&self, target: &str, query: &Query) -> f64 {
        // Red: opens, focus and the current workspace are not ranked yet.
        let _ = (target, query, &self.opens, &self.focus, OPENS, FOCUS);
        0.0
    }

    fn search_names(&self, words: &[Vec<u8>], query: &Query) -> Vec<Hit> {
        let mut hits: Vec<Hit> = self
            .names
            .matches(words, &query.kinds, &Contexts::default())
            .map(|(entry, found)| {
                let doc = &entry.doc;
                let score = score(found.tier, doc.kind, doc.at_ms, query.now_ms)
                    + self.signals(&doc.target, query)
                    + context_bonus(found.context_words)
                    + f64::from(found.quality) / 3.0;
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
    ///
    /// A word found in a target's context need not be in that target's
    /// text, but at least one word (the anchor) must be in the text: every
    /// word no context holds, or else the longest word.
    fn search_content(
        &self,
        words: &[Vec<u8>],
        query: &Query,
        started: Instant,
    ) -> (Vec<Hit>, bool) {
        // Per word, the target ids whose context holds it.
        let context_targets: Vec<HashSet<u32>> = words
            .iter()
            .map(|word| {
                // Red: contexts do not match query words yet.
                self.contexts
                    .entries
                    .iter()
                    .filter(|(_, entry)| entry.contains(word) && word.is_empty())
                    .filter_map(|(target, _)| self.string_ids.get(target).copied())
                    .collect()
            })
            .collect();
        let mut anchors: Vec<bool> = context_targets.iter().map(HashSet::is_empty).collect();
        if !words.iter().zip(&anchors).any(|(word, &anchor)| anchor && word.len() >= 3) {
            let Some(longest) = (0..words.len())
                .filter(|&index| words[index].len() >= 3)
                .max_by_key(|&index| words[index].len())
            else {
                return (Vec::new(), false);
            };
            anchors[longest] = true;
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
            .zip(&anchors)
            .filter(|(word, anchor)| **anchor && word.len() >= 3)
            .flat_map(|(word, _)| trigram::distinct(word))
            .collect();
        keys.sort_unstable();
        keys.dedup();
        let finders: Vec<Finder<'_>> = words.iter().map(Finder::new).collect();
        let want = query.limit.saturating_mul(4).max(query.limit);
        let mut found: Vec<Found> = Vec::new();
        let mut folded = Vec::new();
        let mut buffer = Vec::new();
        let mut block = BlockData::default();
        let mut partial = false;
        'segments: for segment in self.segments.iter().rev() {
            let candidates = match segment.candidates(&keys, &mut buffer) {
                Ok(Some(candidates)) => candidates,
                Ok(None) => (0..segment.blocks().len() as u32).collect(),
                Err(_) => {
                    self.read_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    continue;
                }
            };
            for &block_id in candidates.iter().rev() {
                if let Some(budget) = query.budget
                    && started.elapsed() > budget
                {
                    partial = true;
                    break 'segments;
                }
                let Some(meta) = segment.blocks().get(block_id as usize) else { continue };
                if meta.kinds & kind_mask == 0 {
                    continue;
                }
                if segment.load_block(block_id, &mut block).is_err() {
                    self.read_errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    continue;
                }
                for (offset, doc) in block.docs.iter().enumerate().rev() {
                    let doc_index = meta.first_doc + offset as u32;
                    if kind_mask & (1 << doc.kind) == 0
                        || segment.is_deleted(doc_index)
                        || self.removed.get(doc.source as usize).copied().unwrap_or(true)
                    {
                        continue;
                    }
                    let text = block.doc_text(doc);
                    fold_into(text, &mut folded);
                    let matched = finders.iter().enumerate().all(|(index, finder)| {
                        finder.find(&folded).is_some()
                            || (!anchors[index] && context_targets[index].contains(&doc.target))
                    });
                    if matched {
                        found.push(Found { meta: *doc, text: text.to_owned() });
                        if found.len() >= want {
                            break 'segments;
                        }
                    }
                }
            }
        }
        let mut hits: Vec<Hit> =
            found.iter().filter_map(|found| self.content_hit(found, words, query)).collect();
        hits.sort_by(|a, b| b.score.total_cmp(&a.score));
        hits.truncate(query.limit);
        (hits, partial)
    }

    fn content_hit(&self, found: &Found, words: &[Vec<u8>], query: &Query) -> Option<Hit> {
        let doc = &found.meta;
        let kind = Kind::from_code(doc.kind)?;
        let target = self.strings.get(doc.target as usize)?.clone();
        let title = self.strings.get(doc.title as usize)?.clone();
        let (folded, map) = fold_with_map(&found.text);
        let in_text: Vec<Vec<u8>> = words
            .iter()
            .filter(|word| memchr::memmem::find(&folded, word).is_some())
            .cloned()
            .collect();
        if in_text.is_empty() {
            return None;
        }
        let (mut tier, at) = content_tier(&folded, &in_text, &join_words(&in_text));
        if in_text.len() < words.len() {
            tier = tier.min(3);
        }
        let context = self.contexts.get(&target);
        let folded_title = fold(&title).into_bytes();
        let context_words = words
            .iter()
            .filter(|word| {
                context.is_some_and(|context| context.contains(word))
                    || memchr::memmem::find(&folded_title, word).is_some()
            })
            .count() as u32;
        let line = folded[..at].iter().filter(|&&byte| byte == b'\n').count() as u32;
        let (snippet, highlights) = snippet(&found.text, &map, at, &in_text);
        Some(Hit {
            kind,
            source: self.strings.get(doc.source as usize)?.clone(),
            position: (doc.position != NONE_I64).then_some(doc.position),
            line,
            title,
            subtitle: context.map_or(String::new(), |context| context.context.workspace.clone()),
            snippet,
            highlights,
            at_ms: doc.at_ms,
            tier,
            score: score(tier, kind, doc.at_ms, query.now_ms)
                + self.signals(&target, query)
                + context_bonus(context_words),
            is_name: false,
            target,
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
    let at = words.first().and_then(|word| memchr::memmem::find(folded, word)).unwrap_or(0);
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

/// Design 7.3: tier x 1000 + (weight - 1) x 500 + 250 x recency. The other
/// signals (opens <= 200, focus <= 150, same workspace 100, context <= 150,
/// name quality <= 33) are added by the caller; together they stay under
/// 1000, so a better tier always wins.
fn score(tier: u8, kind: Kind, at_ms: i64, now_ms: i64) -> f64 {
    let age_days = (now_ms - at_ms).max(0) as f64 / DAY_MS;
    let recency = (-age_days / 7.0).exp();
    f64::from(tier) * 1000.0 + (kind.weight() - 1.0) * 500.0 + 250.0 * recency
}

/// Query words that name the hit's place (workspace, group, title, folder,
/// branch, agent): 60 points each, at most 150.
fn context_bonus(words: u32) -> f64 {
    // Red: context words are not ranked yet.
    let _ = words;
    0.0
}
