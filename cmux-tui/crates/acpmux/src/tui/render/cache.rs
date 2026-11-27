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
        let split = t.items[..first_queued]
            .iter()
            .rposition(|i| matches!(i, Item::User { queued: false, .. }))
            .unwrap_or(0);
        let rebuild_prefix = reset || dirty < self.prefix_items || split < self.prefix_items;
        let changed_row = if rebuild_prefix { 0 } else { self.prefix_rows };
        if rebuild_prefix {
            self.rows.clear();
            self.prefix_items = 0;
            self.prefix_rows = 0;
        } else {
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
        if let Some(first) = rows.first()
            && !self.rows.is_empty()
        {
            plain("", Style::default(), first.item, &mut self.rows);
        }
        self.rows.extend(rows);
    }
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
        let suffix = line.spans[0]
            .content
            .split_once(" · ")
            .map(|(_, rest)| format!(" · {rest}"))
            .unwrap_or_default();
        line.spans[0] = Span::styled(format!("{label}{suffix}"), c.muted());
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
