use std::collections::VecDeque;
use std::marker::PhantomData;

pub(super) trait SuffixMetric {
    fn len(text: &str) -> usize;
    fn tail(text: &str, max: usize) -> &str;
}

pub(super) struct Chars;

impl SuffixMetric for Chars {
    fn len(text: &str) -> usize {
        text.chars().count()
    }

    fn tail(text: &str, max: usize) -> &str {
        let len = text.chars().count();
        if len <= max {
            return text;
        }
        let skip = len - max;
        let start = text.char_indices().nth(skip).map_or(text.len(), |(at, _)| at);
        &text[start..]
    }
}

/// A suffix with a fixed retained size and an unbounded logical length.
pub(super) struct BoundedSuffix<M> {
    parts: VecDeque<String>,
    retained: usize,
    total: usize,
    max: usize,
    metric: PhantomData<M>,
}

impl<M: SuffixMetric> BoundedSuffix<M> {
    pub(super) fn new(max: usize) -> Self {
        Self { parts: VecDeque::new(), retained: 0, total: 0, max, metric: PhantomData }
    }

    pub(super) fn push_str(&mut self, text: &str) {
        let len = M::len(text);
        self.total = self.total.saturating_add(len);
        if len == 0 || self.max == 0 {
            return;
        }
        if len > self.max {
            self.parts.clear();
            self.retained = 0;
            self.push_retained(M::tail(text, self.max));
            return;
        }
        self.push_retained(text);
        self.trim_front();
    }

    pub(super) fn push_retained(&mut self, text: &str) {
        let len = M::len(text);
        if len == 0 || self.max == 0 {
            return;
        }
        self.parts.push_back(text.to_owned());
        self.retained += len;
        self.trim_front();
    }

    pub(super) fn clear(&mut self) {
        self.parts.clear();
        self.retained = 0;
        self.total = 0;
    }

    pub(super) fn total(&self) -> usize {
        self.total
    }

    pub(super) fn add_total(&mut self, len: usize) {
        self.total = self.total.saturating_add(len);
    }

    pub(super) fn is_empty(&self) -> bool {
        self.total == 0
    }

    pub(super) fn tail_string(&self, max: usize) -> String {
        let mut text = String::new();
        for part in &self.parts {
            text.push_str(part);
        }
        M::tail(&text, max).to_owned()
    }

    pub(super) fn string(&self) -> String {
        self.tail_string(self.max)
    }

    fn trim_front(&mut self) {
        while self.retained > self.max {
            let excess = self.retained - self.max;
            let Some(part) = self.parts.pop_front() else {
                self.retained = 0;
                break;
            };
            let len = M::len(&part);
            if len <= excess {
                self.retained -= len;
            } else {
                let tail = M::tail(&part, len - excess).to_owned();
                self.retained -= excess;
                self.parts.push_front(tail);
            }
        }
    }
}

/// A bounded representation of `str::trim()` over streamed chunks.
pub(super) struct TrimmedText<M> {
    content: BoundedSuffix<M>,
    pending_whitespace: BoundedSuffix<M>,
    started: bool,
}

impl<M: SuffixMetric> TrimmedText<M> {
    pub(super) fn new(max: usize) -> Self {
        Self {
            content: BoundedSuffix::new(max),
            pending_whitespace: BoundedSuffix::new(max),
            started: false,
        }
    }

    pub(super) fn push_str(&mut self, text: &str) {
        let mut run = String::new();
        let mut whitespace = None;
        for ch in text.chars() {
            if !self.started && ch.is_whitespace() {
                continue;
            }
            if !self.started {
                self.started = true;
            }
            let is_whitespace = ch.is_whitespace();
            if whitespace != Some(is_whitespace) {
                self.flush_run(&mut run, whitespace);
                whitespace = Some(is_whitespace);
            }
            run.push(ch);
        }
        self.flush_run(&mut run, whitespace);
    }

    pub(super) fn finish(&mut self) {
        // Trailing whitespace is not part of `trim()`.
        self.pending_whitespace.clear();
    }

    pub(super) fn is_empty(&self) -> bool {
        !self.started
    }

    pub(super) fn total(&self) -> usize {
        self.content.total()
    }

    pub(super) fn string(&self) -> String {
        self.content.string()
    }

    fn flush_run(&mut self, run: &mut String, whitespace: Option<bool>) {
        if run.is_empty() {
            return;
        }
        if whitespace == Some(true) {
            self.pending_whitespace.push_str(run);
        } else {
            if !self.pending_whitespace.is_empty() {
                let pending = self.pending_whitespace.string();
                self.content.push_str(&pending);
                self.pending_whitespace.clear();
            }
            self.content.push_str(run);
        }
        run.clear();
    }
}
