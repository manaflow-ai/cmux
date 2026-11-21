//! Retain document layout independently of terminal frames. Typing, hover,
//! scrolling and animation only paint visible rows. A stream rebuilds the
//! current turn; completed turns stay allocated and syntax-highlighted.
//!
//! Finished turns are laid out lazily, one turn (a chunk) at a time, and
//! only when they come within a viewport of the screen (`prepare`). A turn
//! not laid out at the current width counts its last known height, or an
//! estimate, so offsets and the scrollbar stay usable; a width change only
//! marks every turn stale (one generation bump) and the frame wraps what it
//! shows. A turn that is laid out and changes height logs a [`Moved`], which
//! row-indexed state (scroll offset, selection, fold anchor) follows, so the
//! rows on screen keep their place.

use super::*;
use std::collections::{HashMap, HashSet};

/// One finished turn: items `start..end`, from a sent prompt to the next.
struct Chunk {
    start: usize,
    end: usize,
    /// The rows, leading spacer included, laid out at generation `generation`.
    rows: Vec<Row>,
    /// Equal to the cache's generation when `rows` is current; 0 when stale.
    generation: u64,
    /// `rows.len()` when current; otherwise the last known height or an estimate.
    height: usize,
}

/// A laid-out turn's height changed from `old` to `new` rows at row `start`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Moved {
    start: usize,
    old: usize,
    new: usize,
}

impl Moved {
    /// Where row `row` is after the change: rows below the turn move by the
    /// difference, rows inside it keep their place within it.
    pub(crate) fn apply(&self, row: usize) -> usize {
        if row >= self.start + self.old {
            row + self.new - self.old
        } else if row >= self.start {
            self.start + (row - self.start).min(self.new.saturating_sub(1))
        } else {
            row
        }
    }
}

/// Prefix sums of chunk heights: O(log n) to change a height, sum a prefix,
/// or find the chunk holding a row.
#[derive(Default)]
struct Heights(Vec<usize>);

impl Heights {
    fn low(i: usize) -> usize {
        i & i.wrapping_neg()
    }
    /// Sum of the first `n` heights.
    fn prefix(&self, mut n: usize) -> usize {
        let mut sum = 0;
        while n > 0 {
            sum += self.0[n - 1];
            n -= Self::low(n);
        }
        sum
    }
    fn total(&self) -> usize {
        self.prefix(self.0.len())
    }
    fn push(&mut self, h: usize) {
        let i = self.0.len() + 1;
        let node = h + self.prefix(i - 1) - self.prefix(i - Self::low(i));
        self.0.push(node);
    }
    fn truncate(&mut self, n: usize) {
        self.0.truncate(n);
    }
    fn change(&mut self, k: usize, old: usize, new: usize) {
        let mut i = k + 1;
        while i <= self.0.len() {
            self.0[i - 1] = self.0[i - 1] + new - old;
            i += Self::low(i);
        }
    }
    /// The chunk holding `row` and the row it starts at: the most chunks whose
    /// heights sum to at most `row`. `len` when `row` is past them all.
    fn find(&self, row: usize) -> (usize, usize) {
        let (mut pos, mut rest) = (0, row);
        let mut step = self.0.len().next_power_of_two();
        while step > 0 {
            if pos + step <= self.0.len() && self.0[pos + step - 1] <= rest {
                pos += step;
                rest -= self.0[pos - 1];
            }
            step /= 2;
        }
        (pos, row - rest)
    }
}

pub(crate) struct TranscriptCache {
    session: String,
    width: usize,
    thoughts: bool,
    system: bool,
    chrome: Option<Chrome>,
    toggled: HashSet<Toggle>,
    items: usize,
    status: String,
    /// Bumped when every chunk goes stale (width, theme, a filter, a page in front).
    generation: u64,
    chunks: Vec<Chunk>,
    heights: Heights,
    /// Items the chunks cover (`0..prefix_items`); the live turn starts here.
    prefix_items: usize,
    /// The live turn and anything queued, laid out with every change.
    tail: Vec<Row>,
    /// Parsed markdown within the mutable turn. Older replies in a long
    /// tool loop do not need highlighting again when a new chunk arrives.
    markdown: HashMap<usize, Vec<Row>>,
    moved: Vec<Moved>,
    /// Transcript items laid out (wrapped) so far, every frame together.
    pub(crate) items_wrapped: usize,
}

impl Default for TranscriptCache {
    fn default() -> Self {
        Self {
            session: String::new(),
            width: 0,
            thoughts: false,
            system: false,
            chrome: None,
            toggled: HashSet::new(),
            items: 0,
            status: String::new(),
            generation: 1,
            chunks: Vec::new(),
            heights: Heights::default(),
            prefix_items: 0,
            tail: Vec::new(),
            markdown: HashMap::new(),
            moved: Vec::new(),
            items_wrapped: 0,
        }
    }
}

/// Rows a turn not laid out yet is counted as: its prompt's bubble and its
/// final reply at `width`, plus the folded work's handle. Reads lengths only.
fn estimate(t: &Transcript, range: std::ops::Range<usize>, width: usize) -> usize {
    let w = width.max(20);
    let (mut rows, mut reply, mut work) = (1, 0, false);
    for item in &t.items[range] {
        match item {
            Item::User { text, .. } => rows += 3 + text.len() / (w * 7 / 10),
            Item::Assistant { text } => {
                reply = 2 + text.len() / w;
                work = true;
            }
            _ => work = true,
        }
    }
    rows + reply + if work { 3 } else { 0 }
}

fn sent(item: &Item) -> bool {
    matches!(item, Item::User { queued: false, .. })
}

impl TranscriptCache {
    /// Forgets every row, keeping the counters.
    pub fn clear(&mut self) {
        *self = Self { items_wrapped: self.items_wrapped, ..Self::default() };
    }

    /// Takes in the transcript's changes since the last frame: chunks whose
    /// items changed go stale, the live turn is laid out again. Lays out no
    /// finished turn except, rarely, the first (see `earlier_rows`).
    /// Returns whether anything changed.
    #[allow(clippy::too_many_arguments)]
    pub fn update(
        &mut self,
        session: &str,
        t: &mut Transcript,
        width: usize,
        thoughts: bool,
        system: bool,
        toggled: &HashSet<Toggle>,
        c: &Chrome,
    ) -> bool {
        let shift = std::mem::take(&mut t.layout_shift);
        let dirty = std::mem::replace(&mut t.layout_dirty_from, usize::MAX);
        let dirty_items = std::mem::take(&mut t.layout_dirty_items);
        let new_session = self.session != session;
        if new_session {
            self.clear();
        }
        let relayout = new_session
            || self.width != width
            || self.thoughts != thoughts
            || self.system != system
            || self.chrome.as_ref() != Some(c);
        let refolded = self.toggled != *toggled;
        if !relayout
            && !refolded
            && shift == 0
            && dirty == usize::MAX
            && dirty_items.is_empty()
            && self.items == t.items.len()
            && self.status == t.status
        {
            return false;
        }
        let mut tail_dirty = relayout
            || shift > 0
            || dirty != usize::MAX
            || self.items != t.items.len()
            || self.status != t.status;
        let mut all_stale = relayout;
        if shift > 0 && !self.chunks.is_empty() {
            // An older page went in front: every kept item moved by `shift`.
            for ch in &mut self.chunks {
                ch.start += shift;
                ch.end += shift;
            }
            self.prefix_items += shift;
            all_stale = true;
        }
        if all_stale {
            self.generation += 1;
            self.markdown.clear();
        } else {
            self.markdown.retain(|&item, _| item < dirty);
        }
        // The live turn starts at the last sent prompt before any queued one;
        // queued prompts follow it (they are pushed while it runs).
        let mut split = 0;
        for (i, item) in t.items.iter().enumerate().rev() {
            if sent(item) {
                split = i;
                break;
            }
        }
        // Chunks from the first changed item on are cut and re-made, keeping
        // the heights of those whose items are where they were.
        let cut = if dirty < self.prefix_items { dirty } else { usize::MAX }
            .min(if split < self.prefix_items { split } else { usize::MAX });
        let mut kept: Vec<(usize, usize, usize)> = Vec::new();
        if cut != usize::MAX {
            let k = self.chunks.partition_point(|ch| ch.end <= cut);
            kept = self.chunks[k..].iter().map(|ch| (ch.start, ch.end, ch.height)).collect();
            self.chunks.truncate(k);
            self.heights.truncate(k);
            self.prefix_items = self.chunks.last().map_or(0, |ch| ch.end);
        }
        if split > self.prefix_items {
            let mut start = self.prefix_items;
            for end in (start + 1..=split).filter(|&i| i == split || sent(&t.items[i])) {
                let height = kept
                    .binary_search_by_key(&start, |k| k.0)
                    .ok()
                    .filter(|&n| kept[n].1 == end)
                    .map_or_else(|| estimate(t, start..end, width), |n| kept[n].2);
                self.chunks.push(Chunk { start, end, rows: Vec::new(), generation: 0, height });
                self.heights.push(height);
                start = end;
            }
            self.prefix_items = split;
        }
        if !all_stale {
            let changed = dirty_items.into_iter().chain(
                if refolded {
                    self.toggled.symmetric_difference(toggled).copied().collect()
                } else {
                    Vec::new()
                }
                .into_iter()
                .map(|tg| match tg {
                    Toggle::Turn(i) | Toggle::Group(i) | Toggle::Item(i) => i,
                }),
            );
            for i in changed {
                if i < self.prefix_items {
                    let k = self.chunks.partition_point(|ch| ch.start <= i) - 1;
                    self.chunks[k].generation = 0;
                } else {
                    tail_dirty = true;
                }
            }
        }
        self.session = session.to_owned();
        self.width = width;
        self.thoughts = thoughts;
        self.system = system;
        self.chrome = Some(*c);
        self.toggled.clone_from(toggled);
        self.items = t.items.len();
        self.status.clone_from(&t.status);
        if tail_dirty {
            self.markdown.retain(|&item, _| item >= split);
            self.items_wrapped += t.items.len() - split;
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
            self.tail.clear();
            if !rows.is_empty() && self.earlier_rows(t, self.chunks.len()) {
                plain("", Style::default(), rows[0].item, &mut self.tail);
            }
            self.tail.extend(rows);
        }
        true
    }

    /// Whether rows come before chunk `k` (the live turn when `k` is the
    /// chunk count): a spacer row separates it from them. Every chunk after
    /// the first starts at a prompt, so it has rows; the first may not.
    fn earlier_rows(&mut self, t: &Transcript, k: usize) -> bool {
        match k {
            0 => false,
            1 => {
                if sent(&t.items[self.chunks[0].start]) {
                    return true;
                }
                self.wrap(t, 0);
                !self.chunks[0].rows.is_empty()
            }
            _ => true,
        }
    }

    /// Lays out chunk `k` if it is stale.
    fn wrap(&mut self, t: &Transcript, k: usize) {
        // Chunks are made by `update`, which sets the chrome first.
        let Some(c) = self.chrome else { return };
        if self.chunks[k].generation == self.generation {
            return;
        }
        let earlier = self.earlier_rows(t, k);
        let (start, end) = (self.chunks[k].start, self.chunks[k].end);
        let rows = transcript_rows_range(
            t,
            self.width,
            self.thoughts,
            self.system,
            &self.toggled,
            &c,
            start..end,
            false,
            None,
        );
        self.items_wrapped += end - start;
        let mut out = Vec::with_capacity(rows.len() + 1);
        if earlier && let Some(first) = rows.first() {
            plain("", Style::default(), first.item, &mut out);
        }
        out.extend(rows);
        let (old, new) = (self.chunks[k].height, out.len());
        if old != new {
            self.moved.push(Moved { start: self.heights.prefix(k), old, new });
            self.heights.change(k, old, new);
        }
        let ch = &mut self.chunks[k];
        ch.rows = out;
        ch.generation = self.generation;
        ch.height = new;
    }

    /// The chunk holding `row` and the row it starts at; the chunk count for
    /// a row of the live turn.
    fn locate(&self, row: usize) -> (usize, usize) {
        self.heights.find(row)
    }

    /// Lays out the turns a frame of `visible` rows shows, plus one viewport
    /// above and below: from row `top`, or from the end when `top` is None
    /// (pinned to the bottom). Heights that change are logged (`take_moved`).
    pub fn prepare(&mut self, t: &Transcript, top: Option<usize>, visible: usize) {
        let over = visible;
        let Some(top) = top else {
            let (mut covered, mut k) = (self.tail.len(), self.chunks.len());
            while covered < visible + over && k > 0 {
                k -= 1;
                self.wrap(t, k);
                covered += self.chunks[k].height;
            }
            return;
        };
        let (k, start) = self.locate(top);
        let intra = top - start;
        let below = if k < self.chunks.len() {
            self.wrap(t, k);
            self.chunks[k].height.saturating_sub(intra)
        } else {
            self.tail.len().saturating_sub(intra)
        };
        let (mut covered, mut j) = (intra, k);
        while covered < over && j > 0 {
            j -= 1;
            self.wrap(t, j);
            covered += self.chunks[j].height;
        }
        let (mut covered, mut j) = (below, k + 1);
        while covered < visible + over && j < self.chunks.len() {
            self.wrap(t, j);
            covered += self.chunks[j].height;
            j += 1;
        }
    }

    /// Lays out every turn holding a row in `first..=last`, for a copy.
    pub fn ensure(&mut self, t: &Transcript, first: usize, mut last: usize) {
        let mut k = self.locate(first).0;
        while k < self.chunks.len() && self.heights.prefix(k) <= last {
            let logged = self.moved.len();
            self.wrap(t, k);
            last = self.moved[logged..].iter().fold(last, |r, m| m.apply(r));
            k += 1;
        }
    }

    /// Height changes since the last call, in order; apply each to a row
    /// index (`Moved::apply`) to keep it on the same text.
    pub fn take_moved(&mut self) -> Vec<Moved> {
        std::mem::take(&mut self.moved)
    }

    /// Rows in the transcript, those not laid out counted by estimate.
    pub fn total(&self) -> usize {
        self.heights.total() + self.tail.len()
    }

    /// Row `i` when it is laid out.
    pub fn row(&self, i: usize) -> Option<&Row> {
        let prefix = self.heights.total();
        if i >= prefix {
            return self.tail.get(i - prefix);
        }
        let (k, start) = self.locate(i);
        let ch = &self.chunks[k];
        (ch.generation == self.generation).then(|| ch.rows.get(i - start)).flatten()
    }

    /// Row `i`'s plain text: empty when it is not laid out, None past the end.
    pub fn line(&self, i: usize) -> Option<&str> {
        (i < self.total()).then(|| self.row(i).map_or("", |r| r.text.as_str()))
    }

    /// Row `i`'s plain text, for copy and hit tests; empty when not laid out.
    pub fn text(&self, i: usize) -> &str {
        self.row(i).map_or("", |r| r.text.as_str())
    }

    /// Row `i`'s item index and collapsible.
    pub fn meta(&self, i: usize) -> Option<(usize, Option<Toggle>)> {
        self.row(i).map(|r| (r.item, r.toggle))
    }

    /// Every row, laying out every turn: the whole document, for tests.
    #[cfg(test)]
    pub fn all_rows(&mut self, t: &Transcript) -> Vec<Row> {
        for k in 0..self.chunks.len() {
            self.wrap(t, k);
        }
        (0..self.total()).filter_map(|i| self.row(i).cloned()).collect()
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
