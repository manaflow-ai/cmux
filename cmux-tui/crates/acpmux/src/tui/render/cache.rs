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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn history(turns: usize) -> Transcript {
        let mut t = Transcript::default();
        for n in 0..turns {
            t.apply_event(
                &json!({"dir":"mux", "kind":"user_message", "msg":{"text":format!("turn {n}")}}),
            );
            t.apply_session_update(&json!({"sessionUpdate":"agent_message_chunk", "content":{"text":"# Reply\n\nSee src/main.rs and https://example.com.\n\n```rust\nfn main() {\n    println!(\"hello\");\n}\n```"}}));
            t.apply_event(
                &json!({"dir":"mux", "kind":"turn_end", "msg":{"stopReason":"end_turn"}}),
            );
        }
        t.status = "ready".into();
        t
    }

    fn update(
        cache: &mut TranscriptCache,
        t: &mut Transcript,
        width: usize,
        toggled: &HashSet<Toggle>,
    ) -> Option<usize> {
        cache.update("test", t, width, false, false, toggled, &Chrome::detect())
    }

    fn assert_equivalent(
        cache: &TranscriptCache,
        t: &Transcript,
        width: usize,
        toggled: &HashSet<Toggle>,
    ) {
        let expected = transcript_rows(t, width, false, false, toggled, &Chrome::detect());
        let rows = |rows: &[Row]| {
            rows.iter().map(|r| (r.text.clone(), r.item, r.toggle)).collect::<Vec<_>>()
        };
        assert_eq!(rows(&cache.rows), rows(&expected));
        if t.status != "running" {
            assert_eq!(
                cache.rows.iter().map(|r| &r.line).collect::<Vec<_>>(),
                expected.iter().map(|r| &r.line).collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn retained_layout_matches_full_layout_and_skips_unchanged_frames() {
        let mut t = history(4);
        let mut cache = TranscriptCache::default();
        let toggled = HashSet::new();
        assert_eq!(update(&mut cache, &mut t, 80, &toggled), Some(0));
        assert_equivalent(&cache, &t, 80, &toggled);
        let allocation = cache.rows.as_ptr();
        for _ in 0..100 {
            assert_eq!(update(&mut cache, &mut t, 80, &toggled), None);
        }
        assert_eq!(cache.rows.as_ptr(), allocation);
        update(&mut cache, &mut t, 42, &toggled);
        assert_equivalent(&cache, &t, 42, &toggled);
    }

    #[test]
    fn streaming_reuses_completed_turns_and_new_turns_extend_prefix() {
        let mut t = history(3);
        let mut cache = TranscriptCache::default();
        let toggled = HashSet::new();
        update(&mut cache, &mut t, 80, &toggled);
        let first_text = cache.rows[1].text.as_ptr();
        t.apply_session_update(
            &json!({"sessionUpdate":"agent_message_chunk", "content":{"text":"streaming"}}),
        );
        let changed = update(&mut cache, &mut t, 80, &toggled).unwrap();
        assert!(changed > 0);
        assert_eq!(cache.rows[1].text.as_ptr(), first_text);
        assert_equivalent(&cache, &t, 80, &toggled);
        // The local echo is an append before the daemon acknowledges it.
        t.items.push(Item::User { text: "next".into(), steer: false, queued: false });
        update(&mut cache, &mut t, 80, &toggled);
        assert_equivalent(&cache, &t, 80, &toggled);
        assert_eq!(cache.rows[1].text.as_ptr(), first_text);
    }

    #[test]
    fn historical_edits_queued_promotion_and_collapses_invalidate_correctly() {
        let mut t = history(1);
        t.apply_session_update(&json!({"sessionUpdate":"tool_call", "toolCallId":"old", "title":"Read file", "status":"pending"}));
        t.apply_event(&json!({"dir":"mux","kind":"user_message","msg":{"text":"next"}}));
        let mut cache = TranscriptCache::default();
        let mut toggled = HashSet::new();
        update(&mut cache, &mut t, 80, &toggled);
        t.apply_session_update(&json!({"sessionUpdate":"tool_call_update", "toolCallId":"old", "status":"completed", "rawOutput":"contents"}));
        assert_eq!(update(&mut cache, &mut t, 80, &toggled), Some(0));
        assert_equivalent(&cache, &t, 80, &toggled);
        for (kind, msg) in
            [("queued", json!({"text":"later"})), ("user_message", json!({"text":"later"}))]
        {
            t.apply_event(&json!({"dir":"mux", "kind":kind, "msg":msg}));
            update(&mut cache, &mut t, 80, &toggled);
            assert_equivalent(&cache, &t, 80, &toggled);
        }
        toggled.insert(Toggle::Item(3));
        update(&mut cache, &mut t, 80, &toggled);
        assert_equivalent(&cache, &t, 80, &toggled);
    }

    #[test]
    fn streaming_keeps_earlier_markdown_in_the_active_turn() {
        let mut t = history(2);
        let mut cache = TranscriptCache::default();
        let toggled = HashSet::new();
        update(&mut cache, &mut t, 80, &toggled);
        let earlier = t.items.len() - 2;
        let parsed = cache.markdown[&earlier].as_ptr();
        t.apply_session_update(&json!({"sessionUpdate":"tool_call", "toolCallId":"t", "title":"ls", "status":"pending"}));
        t.apply_session_update(
            &json!({"sessionUpdate":"agent_message_chunk", "content":{"text":"answer"}}),
        );
        update(&mut cache, &mut t, 80, &toggled);
        assert_eq!(cache.markdown[&earlier].as_ptr(), parsed);
        t.apply_session_update(
            &json!({"sessionUpdate":"agent_message_chunk", "content":{"text":" with more"}}),
        );
        update(&mut cache, &mut t, 80, &toggled);
        assert_eq!(cache.markdown[&earlier].as_ptr(), parsed);
        assert_equivalent(&cache, &t, 80, &toggled);
        // Animation does not invalidate the parsed document.
        t.status = "running".into();
        update(&mut cache, &mut t, 80, &toggled);
        assert_equivalent(&cache, &t, 80, &toggled);
        assert_eq!(update(&mut cache, &mut t, 80, &toggled), None);
        t.apply_event(&json!({"dir":"mux", "kind":"status", "msg":{"status":"ready"}}));
        update(&mut cache, &mut t, 80, &toggled);
        assert_equivalent(&cache, &t, 80, &toggled);
    }

    #[test]
    #[ignore = "manual release-mode performance measurement"]
    fn benchmark_retained_transcript() {
        use std::{hint::black_box, time::Instant};
        let mut t = history(500);
        let mut cache = TranscriptCache::default();
        let toggled = HashSet::new();
        update(&mut cache, &mut t, 100, &toggled);
        let count = 20;
        let start = Instant::now();
        for _ in 0..count {
            black_box(transcript_rows(&t, 100, false, false, &toggled, &Chrome::detect()));
        }
        let full = start.elapsed() / count;
        let start = Instant::now();
        for _ in 0..10_000 {
            black_box(update(&mut cache, &mut t, 100, &toggled));
        }
        let retained = start.elapsed() / 10_000;
        let start = Instant::now();
        for _ in 0..count {
            t.apply_session_update(
                &json!({"sessionUpdate":"agent_message_chunk", "content":{"text":" more"}}),
            );
            black_box(update(&mut cache, &mut t, 100, &toggled));
        }
        let streaming = start.elapsed() / count;
        eprintln!(
            "{} rows / 500 turns: full layout {full:?}; unchanged frame {retained:?}; streaming update {streaming:?}",
            cache.rows.len()
        );
    }
}
