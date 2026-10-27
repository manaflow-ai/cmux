//! Retain document layout independently of terminal frames. Typing, hover,
//! scrolling and animation only paint visible rows. A stream rebuilds the
//! current turn; completed turns stay allocated and syntax-highlighted.

use super::*;
use std::collections::HashSet;

#[derive(Default)]
pub(crate) struct TranscriptCache {
    session: String,
    width: usize,
    thoughts: bool,
    system: bool,
    chrome: Option<Chrome>,
    toggled: HashSet<Toggle>,
    items: usize,
    status: String,
    prefix_items: usize,
    prefix_rows: usize,
    /// Parsed markdown within the mutable turn. Older replies in a long
    /// tool loop do not need highlighting again when a new chunk arrives.
    markdown: std::collections::HashMap<usize, Vec<Row>>,
    pub rows: Vec<Row>,
    /// The heap bytes of `rows`' text and spans, kept as rows come and go so
    /// [`Self::approx_bytes`] never walks the document.
    row_heap_bytes: u64,
}

impl TranscriptCache {
    /// Returns the first changed row, so copy/hit-test indexes can retain
    /// their unchanged prefix as well. None means no document work at all.
    pub fn update(
        &mut self,
        session: &str,
        t: &mut Transcript,
        width: usize,
        thoughts: bool,
        system: bool,
        toggled: &HashSet<Toggle>,
        c: &Chrome,
    ) -> Option<usize> {
        let reset = self.session != session
            || self.width != width
            || self.thoughts != thoughts
            || self.system != system
            || self.chrome.as_ref() != Some(c)
            || self.toggled != *toggled;
        let dirty = std::mem::replace(&mut t.layout_dirty_from, usize::MAX);
        if !reset && dirty == usize::MAX && self.items == t.items.len() && self.status == t.status {
            return None;
        }
        if reset {
            self.markdown.clear();
        } else {
            self.markdown.retain(|&item, _| item < dirty);
        }
        // Keep queued messages in the tail: promotion can move their item
        // indices, and they are displayed after the live turn.
        let first_queued = t
            .items
            .iter()
            .position(|i| matches!(i, Item::User { queued: true, .. }))
            .unwrap_or(t.items.len());
        let split = t
            .items
            .iter()
            .take(first_queued)
            .rposition(|i| matches!(i, Item::User { queued: false, .. }))
            .unwrap_or(0);
        let rebuild_prefix = reset || dirty < self.prefix_items || split < self.prefix_items;
        let changed_row = if rebuild_prefix { 0 } else { self.prefix_rows };
        if rebuild_prefix {
            self.rows.clear();
            self.row_heap_bytes = 0;
            self.prefix_items = 0;
            self.prefix_rows = 0;
        } else {
            let removed: u64 = self.rows.iter().skip(self.prefix_rows).map(row_heap_bytes).sum();
            self.row_heap_bytes = self.row_heap_bytes.saturating_sub(removed);
            self.rows.truncate(self.prefix_rows);
        }
        if split > self.prefix_items {
            let rows = transcript_rows_range(
                t,
                width,
                thoughts,
                system,
                toggled,
                c,
                self.prefix_items..split,
                false,
                Some(&mut self.markdown),
            );
            self.append(rows);
            self.prefix_items = split;
            self.prefix_rows = self.rows.len();
        }
        self.markdown.retain(|&item, _| item >= split);
        let rows = transcript_rows_range(
            t,
            width,
            thoughts,
            system,
            toggled,
            c,
            split..t.items.len(),
            true,
            Some(&mut self.markdown),
        );
        self.append(rows);
        self.session = session.to_owned();
        self.width = width;
        self.thoughts = thoughts;
        self.system = system;
        self.chrome = Some(*c);
        self.toggled.clone_from(toggled);
        self.items = t.items.len();
        self.status.clone_from(&t.status);
        Some(changed_row)
    }

    fn append(&mut self, rows: Vec<Row>) {
        let from = self.rows.len();
        if let Some(first) = rows.first()
            && !self.rows.is_empty()
        {
            plain("", Style::default(), first.item, &mut self.rows);
        }
        self.rows.extend(rows);
        self.row_heap_bytes += self.rows.iter().skip(from).map(row_heap_bytes).sum::<u64>();
    }

    /// What the cache keeps, estimated in O(parsed items): the rows and their
    /// text, and the parsed markdown of the turn that is still changing.
    pub fn approx_bytes(&self) -> u64 {
        use crate::memory::inline_bytes;
        let markdown: u64 = self
            .markdown
            .values()
            .map(|rows| {
                inline_bytes::<Row>(rows.capacity()) + rows.iter().map(row_heap_bytes).sum::<u64>()
            })
            .sum();
        inline_bytes::<Row>(self.rows.capacity()) + self.row_heap_bytes + markdown
    }

    /// Empties the cache (memory pressure). Lossless: the next draw lays the
    /// document out again from the transcript.
    pub fn release(&mut self) {
        let dropped = std::mem::take(self);
        drop(dropped);
    }
}

/// The heap bytes of one row: its copy text and its styled spans.
fn row_heap_bytes(row: &Row) -> u64 {
    let spans: u64 = row.line.spans.iter().map(|span| span.content.len() as u64).sum();
    row.text.capacity() as u64
        + crate::memory::inline_bytes::<Span<'static>>(row.line.spans.capacity())
        + spans
}

/// Animation changes paint, never document layout or scroll geometry.
pub(super) fn animated_line(t: &Transcript, row: &Row, c: &Chrome) -> Option<Line<'static>> {
    if t.status != "running" {
        return None;
    }
    if row.item == usize::MAX && !row.text.is_empty() {
        return Some(working_row(t, c).line);
    }
    if let Some(Toggle::Turn(i)) = row
        .toggle
        .filter(|tg| matches!(tg, Toggle::Turn(i) if t.turn_times.last().map(|x| x.0) == Some(*i)))
        && let Some((start, None)) = t.turn_span(i)
    {
        let label = format!("Working for {}", duration_label(now_ms().saturating_sub(start)));
        let mut line = row.line.clone();
        // A turn header's first span is its label; the rest of it follows " · ".
        if let Some(first) = line.spans.first_mut() {
            let suffix = first
                .content
                .split_once(" · ")
                .map(|(_, rest)| format!(" · {rest}"))
                .unwrap_or_default();
            *first = Span::styled(format!("{label}{suffix}"), c.muted());
        }
        return Some(line);
    }
    if row.item == t.items.len().saturating_sub(1)
        && matches!(row.toggle, Some(Toggle::Item(_)))
        && matches!(t.items.get(row.item), Some(Item::Thought { .. }))
    {
        let mut line = row.line.clone();
        for (old, new) in line.spans.iter_mut().skip(1).zip(super::super::shimmer::spans(
            "Thinking",
            c.shimmer_base,
            c.shimmer_bright,
        )) {
            *old = new;
        }
        return Some(line);
    }
    None
}
