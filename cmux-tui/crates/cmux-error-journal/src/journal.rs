//! The journal's decisions over its table of problems: folding events (redaction, templates,
//! fingerprints, the new-fingerprint storm cap, bounded context, eviction), when to flush, what to
//! write (an append to the current segment or a compaction into a new one), migrating lines a
//! different redaction wrote, clearing, and queries. The app does the file work: it reads the
//! segments, writes the bytes [`Journal`] hands it and reports back with [`Journal::written`].

use crate::entry::{Entry, Event, parse_stored_line, stored_lines};
use crate::fingerprint::fingerprint;
use crate::normalize::template;
use crate::query::Query;
use crate::redact::Redactor;
use crate::text::{rounded_ms, utf8_prefix};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap};

/// The journal's bounds.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Limits {
    /// A segment past this many bytes is compacted into a new one.
    pub segment_bytes: u64,
    /// The most problems kept; the least recent go first.
    pub max_entries: usize,
    /// Templates and samples are cut to this many bytes.
    pub max_message_bytes: usize,
    /// Context values are cut to this many bytes.
    pub max_context_value_bytes: usize,
    /// The most context keys kept (the first, sorted).
    pub max_context_keys: usize,
    /// New fingerprints one source may add per minute; the rest fold into one "too many" entry.
    pub new_fingerprints_per_minute: u64,
    /// Changed problems that flush at once.
    pub flush_batch: usize,
    /// How long a smaller batch waits before it flushes, in seconds.
    pub flush_delay_seconds: f64,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            segment_bytes: 4 << 20,
            max_entries: 1000,
            max_message_bytes: 1024,
            max_context_value_bytes: 256,
            max_context_keys: 8,
            new_fingerprints_per_minute: 120,
            flush_batch: 256,
            flush_delay_seconds: 2.0,
        }
    }
}

/// How a write goes to disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WriteMode {
    /// Append to the newest segment.
    Append,
    /// Write a new segment holding `data` alone, then remove every older one.
    Compact,
}

/// Bytes for the app to write.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Write {
    /// Append or compact.
    pub mode: WriteMode,
    /// The journal lines.
    pub data: String,
}

/// Why a write was made, which decides what its outcome changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Purpose {
    /// The migration [`Journal::open`] asked for.
    Open,
    /// A [`Journal::flush`] (or its [`Journal::compact_all`] fallback).
    Flush,
    /// A [`Journal::clear`].
    Clear,
    /// The rewrite of the table after a failed clear.
    Restore,
}

/// What a write did.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Written {
    /// Append or compact.
    pub mode: WriteMode,
    /// Why it was made.
    pub purpose: Purpose,
    /// Whether the bytes reached disk (for a compaction, the new segment).
    pub written: bool,
    /// The bytes written.
    #[serde(default)]
    pub bytes: u64,
    /// The first error: the write's, or (a compaction that was written) removing an old segment.
    #[serde(default)]
    pub error: Option<String>,
}

/// What the app does after a write.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AfterWrite {
    /// A clear's answer: how many problems it removed (0 when it failed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub removed: Option<usize>,
    /// A failed clear: compact these lines (purpose `restore`) so a relaunch sees the whole table.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restore: Option<String>,
}

/// When recorded events reach disk.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct FlushAdvice {
    /// A full batch: flush now.
    pub flush_now: bool,
    /// Some changes: flush after `flush_delay_seconds` unless a flush is already scheduled.
    pub schedule: bool,
}

#[derive(Debug, Default)]
struct StoreState {
    has_current: bool,
    current_bytes: u64,
    cleanup_pending: bool,
}

/// One journal's table and what its segments hold.
#[derive(Debug)]
pub struct Journal {
    limits: Limits,
    table: BTreeMap<String, Entry>,
    dirty: BTreeSet<String>,
    new_fingerprints: HashMap<String, (i64, u64)>,
    last_write_error: Option<String>,
    store: StoreState,
    pending_clear: Option<(BTreeMap<String, Entry>, usize)>,
}

fn by_last_seen<'a>(entries: impl IntoIterator<Item = &'a Entry>) -> Vec<&'a Entry> {
    let mut sorted: Vec<&Entry> = entries.into_iter().collect();
    sorted.sort_by_key(|entry| entry.last_ms);
    sorted
}

fn merge_loaded(existing: Option<Entry>, incoming: Entry) -> Entry {
    let Some(mut merged) = existing else { return incoming };
    merged.count = merged.count.wrapping_add(incoming.count);
    merged.level = merged.level.max(incoming.level);
    merged.first_ms = merged.first_ms.min(incoming.first_ms);
    if incoming.last_ms >= merged.last_ms {
        merged.last_ms = incoming.last_ms;
        merged.sample = incoming.sample;
        merged.context = incoming.context;
    }
    merged
}

impl Journal {
    /// A journal with nothing loaded.
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            table: BTreeMap::new(),
            dirty: BTreeSet::new(),
            new_fingerprints: HashMap::new(),
            last_write_error: None,
            store: StoreState::default(),
            pending_clear: None,
        }
    }

    /// The bounds it keeps.
    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    /// Loads the segments' text (oldest first) and the newest segment's size (None: no segment).
    /// The newest line per fingerprint wins. When a line was redacted by other rules, every such
    /// winner is redacted again and refingerprinted, and the table is to be compacted: the
    /// returned lines (write them with purpose `open`).
    pub fn open(&mut self, segments: &[&str], current_bytes: Option<u64>) -> Option<String> {
        self.store = StoreState {
            has_current: current_bytes.is_some(),
            current_bytes: current_bytes.unwrap_or(0),
            cleanup_pending: false,
        };
        self.dirty.clear();
        self.pending_clear = None;
        let digest = Redactor::shared().rules_digest().to_owned();
        let mut newest: BTreeMap<String, (Entry, Option<String>)> = BTreeMap::new();
        let mut stale = false;
        for segment in segments {
            for line in segment.split('\n').filter(|line| !line.is_empty()) {
                let Some((entry, redaction)) = parse_stored_line(line) else { continue };
                if redaction.as_deref() != Some(digest.as_str()) {
                    stale = true;
                }
                newest.insert(entry.fingerprint.clone(), (entry, redaction));
            }
        }
        if !stale {
            self.table =
                newest.into_iter().map(|(fingerprint, (entry, _))| (fingerprint, entry)).collect();
            return None;
        }
        let limits = &self.limits;
        let mut loaded: BTreeMap<String, Entry> = BTreeMap::new();
        // BTreeMap iterates in sorted original-fingerprint order, as the Swift merge did.
        for (_, (mut entry, redaction)) in newest {
            if redaction.as_deref() != Some(digest.as_str()) {
                entry.template = utf8_prefix(
                    &Redactor::shared().redact(&entry.template),
                    limits.max_message_bytes,
                );
                entry.sample = utf8_prefix(
                    &Redactor::shared().redact(&entry.sample),
                    limits.max_message_bytes,
                );
                entry.top_frame = entry
                    .top_frame
                    .map(|frame| utf8_prefix(&Redactor::shared().redact(&frame), 256));
                for value in entry.context.values_mut() {
                    *value = utf8_prefix(
                        &Redactor::shared().redact(value),
                        limits.max_context_value_bytes,
                    );
                }
                entry.fingerprint =
                    fingerprint(&entry.source, &entry.template, entry.top_frame.as_deref());
            }
            let merged = merge_loaded(loaded.remove(&entry.fingerprint), entry);
            loaded.insert(merged.fingerprint.clone(), merged);
        }
        self.table = loaded;
        Some(self.lines(by_last_seen(self.table.values())))
    }

    fn lines(&self, entries: Vec<&Entry>) -> String {
        stored_lines(&entries, Redactor::shared().rules_digest())
    }

    /// Folds `events` and says when to flush.
    pub fn record(&mut self, events: Vec<Event>) -> FlushAdvice {
        for event in events {
            self.fold(event);
        }
        if self.dirty.len() >= self.limits.flush_batch {
            return FlushAdvice { flush_now: true, schedule: false };
        }
        FlushAdvice { flush_now: false, schedule: !self.dirty.is_empty() }
    }

    fn fold(&mut self, event: Event) {
        let redacted = Redactor::shared().redact(&event.message);
        let template_text = template(&redacted, self.limits.max_message_bytes);
        let top_frame = event
            .top_frame
            .as_deref()
            .map(|frame| utf8_prefix(&Redactor::shared().redact(frame), 256));
        let mut key = fingerprint(&event.source, &template_text, top_frame.as_deref());
        let mut template_text = template_text;
        if !self.table.contains_key(&key) && !self.admit_new(&event.source, event.date) {
            template_text = format!("too many distinct errors from {}", event.source);
            key = fingerprint(&event.source, &template_text, None);
        }
        let ms = rounded_ms(event.date);
        let sample = utf8_prefix(&redacted, self.limits.max_message_bytes);
        let context = self.bounded_context(&event.context);
        if let Some(entry) = self.table.get_mut(&key) {
            entry.count = entry.count.wrapping_add(1);
            entry.level = entry.level.max(event.level);
            if ms >= entry.last_ms {
                entry.last_ms = ms;
                entry.sample = sample;
                entry.context = context;
            }
            entry.first_ms = entry.first_ms.min(ms);
        } else {
            // The capped entry keeps the frame of the event that opened it, as the Swift journal did.
            self.table.insert(
                key.clone(),
                Entry {
                    count: 1,
                    context,
                    first_ms: ms,
                    fingerprint: key.clone(),
                    top_frame,
                    last_ms: ms,
                    level: event.level,
                    sample,
                    source: event.source,
                    template: template_text,
                },
            );
            self.evict_if_needed();
        }
        self.dirty.insert(key);
    }

    fn admit_new(&mut self, source: &str, date: f64) -> bool {
        let minute = (date / 60.0) as i64;
        let window = self.new_fingerprints.entry(source.to_owned()).or_insert((minute, 0));
        if window.0 != minute {
            *window = (minute, 0);
        }
        window.1 += 1;
        window.1 <= self.limits.new_fingerprints_per_minute
    }

    fn bounded_context(&self, context: &BTreeMap<String, String>) -> BTreeMap<String, String> {
        context
            .iter()
            .take(self.limits.max_context_keys)
            .map(|(key, value)| {
                (
                    utf8_prefix(key, 64),
                    utf8_prefix(
                        &Redactor::shared().redact(value),
                        self.limits.max_context_value_bytes,
                    ),
                )
            })
            .collect()
    }

    fn evict_if_needed(&mut self) {
        let max = self.limits.max_entries;
        if self.table.len() <= max {
            return;
        }
        // A tenth at once, so a full table does not sort on every new fingerprint.
        let excess = self.table.len() - max + (max / 10).max(1);
        let oldest: Vec<String> = by_last_seen(self.table.values())
            .into_iter()
            .take(excess)
            .map(|entry| entry.fingerprint.clone())
            .collect();
        for key in oldest {
            self.table.remove(&key);
            self.dirty.remove(&key);
        }
    }

    /// What to write for the changes since the last flush: None when nothing changed. Report the
    /// outcome with purpose `flush`.
    pub fn flush(&mut self) -> Option<Write> {
        if self.dirty.is_empty() {
            return None;
        }
        let dirty = std::mem::take(&mut self.dirty);
        let changed = by_last_seen(dirty.iter().filter_map(|key| self.table.get(key)));
        if changed.is_empty() {
            self.last_write_error = None;
            return None;
        }
        let data = self.lines(changed);
        let fits = self.store.current_bytes + data.len() as u64 <= self.limits.segment_bytes;
        if self.store.cleanup_pending || !self.store.has_current || !fits {
            return Some(Write { mode: WriteMode::Compact, data: self.compact_all() });
        }
        Some(Write { mode: WriteMode::Append, data })
    }

    /// The whole table's lines, oldest first: what a compaction writes (also when the newest
    /// segment cannot be opened for an append).
    pub fn compact_all(&self) -> String {
        self.lines(by_last_seen(self.table.values()))
    }

    /// Removes the problems with these fingerprints (None: all) once the app has compacted the
    /// returned lines (purpose `clear`); returns how many it would remove and the lines.
    pub fn clear(&mut self, fingerprints: Option<&[String]>) -> (usize, String) {
        let mut candidate = self.table.clone();
        let removed = match fingerprints {
            Some(fingerprints) => {
                fingerprints.iter().filter(|key| candidate.remove(key.as_str()).is_some()).count()
            }
            None => {
                let count = candidate.len();
                candidate.clear();
                count
            }
        };
        let data = self.lines(by_last_seen(candidate.values()));
        self.pending_clear = Some((candidate, removed));
        (removed, data)
    }

    /// Takes a write's outcome.
    pub fn written(&mut self, outcome: &Written) -> AfterWrite {
        if outcome.written {
            match outcome.mode {
                WriteMode::Append => self.store.current_bytes += outcome.bytes,
                WriteMode::Compact => {
                    self.store.has_current = true;
                    self.store.current_bytes = outcome.bytes;
                    self.store.cleanup_pending = outcome.error.is_some();
                }
            }
        }
        match outcome.purpose {
            Purpose::Open => {
                if outcome.error.is_some() {
                    self.last_write_error.clone_from(&outcome.error);
                }
                AfterWrite::default()
            }
            Purpose::Flush => {
                self.last_write_error.clone_from(&outcome.error);
                AfterWrite::default()
            }
            Purpose::Restore => AfterWrite::default(),
            Purpose::Clear => {
                let Some((candidate, removed)) = self.pending_clear.take() else {
                    return AfterWrite::default();
                };
                if outcome.error.is_none() {
                    self.table = candidate;
                    self.dirty.clear();
                    self.last_write_error = None;
                    return AfterWrite { removed: Some(removed), restore: None };
                }
                // A failed compaction can already have removed old segments: rewrite the table
                // as it was, so a relaunch never sees a half-cleared history.
                self.last_write_error.clone_from(&outcome.error);
                AfterWrite { removed: Some(0), restore: Some(self.compact_all()) }
            }
        }
    }

    /// The problems `query` asks for.
    pub fn entries(&self, query: &Query) -> Vec<Entry> {
        query.select(self.table.values())
    }

    /// How many problems it holds.
    pub fn count(&self) -> usize {
        self.table.len()
    }

    /// The last write's error, if it failed.
    pub fn write_error(&self) -> Option<&str> {
        self.last_write_error.as_deref()
    }
}
