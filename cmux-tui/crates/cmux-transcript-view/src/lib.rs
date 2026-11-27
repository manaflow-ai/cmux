//! The native read-only transcript (hq RFD 0121, "a native Rust transcript, first read-only behind a
//! flag"; built as one design with hq `docs/design/gui-chat-speed-ceiling.md`, whose verdict takes the
//! row heights from Rust).
//!
//! Leo: "Why should non visible thing even affect the renderer thread anyways?" The React transcript
//! shapes every turn (shapeTurn, foldTailTurns, isWorkNarration: 13.8% of the renderer main thread's
//! busy time in the replay under 4x load) on the same thread that produces the visible frames. This
//! crate does the visible viewport's part in Rust instead, where the page's main thread never runs it:
//! the page's experiment switch `nativeTranscript` starts a Worker that loads this crate as wasm
//! (`wasm.rs`), hands it the daemon's socket messages as they arrive, and paints the lines
//! [`Transcript::layout`] gives it onto an OffscreenCanvas on the Worker's own frame clock.
//!
//! - [`Transcript::message`]: one daemon socket message (JSON-RPC text): an `_acpmux/event`
//!   notification, or an attach answer with its `events`. Parsing is here too, not in the page.
//! - Rows: the person's messages, the agent's replies (a short progress note such as "Let me check
//!   the logs." is quiet, [`is_work_narration`], the port of turns.ts `isWorkNarration`), its
//!   thinking, and its tool calls (a call's later updates change its row in place). Only the newest
//!   [`KEEP`] rows are kept: the native view draws the visible tail, never the whole history.
//! - [`Transcript::layout`]: the viewport's lines, wrapped to its width with the page's measured
//!   glyph advances ([`Advance`]), bottom-anchored on the newest row. A row's wrap is kept until its
//!   text or the width changes, so a frame that brings one chunk re-wraps one row.
//!
//! Read-only: nothing here sends to the agent; the React transcript stays the chat's own view.

use std::collections::VecDeque;
use std::sync::LazyLock;

use regex_lite::Regex;
use serde_json::Value;

#[cfg(target_arch = "wasm32")]
mod wasm;

/// Rows kept: the visible tail and a few screens above it.
pub const KEEP: usize = 200;
/// A row's text past this many bytes is laid out from its tail only (a long thought or reply shows
/// its newest part at the bottom of the viewport).
pub const TAIL_BYTES: usize = 4000;

/// How a row draws: the page maps each to its color.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Style {
    /// The person's message.
    User = 0,
    /// An agent reply that is a takeaway.
    Reply = 1,
    /// An agent reply that is only progress narration ([`is_work_narration`]).
    Quiet = 2,
    /// The agent's thinking.
    Thought = 3,
    /// A tool call.
    Tool = 4,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    User,
    Reply,
    Thought,
    Tool,
}

#[derive(Debug)]
struct Row {
    kind: Kind,
    /// `messageId` of a reply, `toolCallId` of a tool call.
    key: Option<String>,
    text: String,
    /// The wrap for `width_bits` (the width's `f32` bits): byte ranges of `text`'s laid-out tail.
    wrap: Option<(u32, Vec<(usize, usize)>)>,
}

impl Row {
    fn new(kind: Kind, key: Option<String>, text: String) -> Self {
        Self { kind, key, text, wrap: None }
    }

    fn style(&self) -> Style {
        match self.kind {
            Kind::User => Style::User,
            Kind::Reply if is_work_narration(&self.text) => Style::Quiet,
            Kind::Reply => Style::Reply,
            Kind::Thought => Style::Thought,
            Kind::Tool => Style::Tool,
        }
    }
}

/// The page's glyph advances, in CSS px: printable ASCII measured once by the Worker's canvas, and one
/// width for every other character.
#[derive(Clone, Debug)]
pub struct Advance {
    ascii: [f32; 95],
    other: f32,
}

impl Advance {
    /// `ascii[i]` is the advance of the character `' ' + i`; a missing entry reads as `other`.
    pub fn new(ascii: &[f32], other: f32) -> Self {
        let mut table = [other; 95];
        for (slot, width) in table.iter_mut().zip(ascii) {
            *slot = *width;
        }
        Self { ascii: table, other }
    }

    /// A fixed-pitch advance: every character `width` wide (tests, and before the page measured).
    pub fn fixed(width: f32) -> Self {
        Self::new(&[], width)
    }

    fn of(&self, c: char) -> f32 {
        let code = c as u32;
        if (32..127).contains(&code) { self.ascii[(code - 32) as usize] } else { self.other }
    }

    fn text(&self, text: &str) -> f32 {
        text.chars().map(|c| self.of(c)).sum()
    }
}

/// One laid-out line: its text, its style and its baseline in px from the viewport's top.
#[derive(Clone, Debug, PartialEq)]
pub struct Line<'a> {
    pub text: &'a str,
    pub style: Style,
    pub y: f32,
}

/// The chat's visible tail, shaped as rows.
#[derive(Debug, Default)]
pub struct Transcript {
    rows: VecDeque<Row>,
}

impl Transcript {
    pub fn new() -> Self {
        Self::default()
    }

    /// Rows kept now.
    pub fn len(&self) -> usize {
        self.rows.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rows.is_empty()
    }

    /// One socket message from the daemon. True when the rows changed.
    pub fn message(&mut self, text: &str) -> bool {
        let Ok(message) = serde_json::from_str::<Value>(text) else {
            return false;
        };
        if message.get("method").and_then(Value::as_str) == Some("_acpmux/event") {
            return message.get("params").is_some_and(|event| self.event(event));
        }
        // An attach answer: the events the session has so far.
        let Some(events) =
            message.get("result").and_then(|result| result.get("events")).and_then(Value::as_array)
        else {
            return false;
        };
        let mut changed = false;
        for event in events {
            changed |= self.event(event);
        }
        changed
    }

    /// One event record (`{kind, msg}`). True when the rows changed.
    pub fn event(&mut self, event: &Value) -> bool {
        let kind = event.get("kind").and_then(Value::as_str).unwrap_or("");
        let msg = event.get("msg").unwrap_or(&Value::Null);
        let update = msg.pointer("/params/update").unwrap_or(&Value::Null);
        let changed = match kind {
            "user_message" => {
                let text = msg.get("text").and_then(Value::as_str).unwrap_or("");
                self.push(Row::new(Kind::User, None, text.to_owned()));
                true
            }
            "agent_message_chunk" => {
                let key = update.get("messageId").and_then(Value::as_str);
                self.append(Kind::Reply, key, chunk_text(update))
            }
            "agent_thought_chunk" => self.append(Kind::Thought, None, chunk_text(update)),
            "tool_call" => {
                let key = update.get("toolCallId").and_then(Value::as_str).map(str::to_owned);
                self.push(Row::new(Kind::Tool, key, tool_line(update)));
                true
            }
            "tool_call_update" => self.tool_update(update),
            _ => false,
        };
        while self.rows.len() > KEEP {
            self.rows.pop_front();
        }
        changed
    }

    fn push(&mut self, row: Row) {
        self.rows.push_back(row);
    }

    /// A chunk joins the newest row when it is the same reply (or thought); otherwise it starts one.
    fn append(&mut self, kind: Kind, key: Option<&str>, chunk: &str) -> bool {
        if let Some(last) = self.rows.back_mut()
            && last.kind == kind
            && (key.is_none() || last.key.as_deref() == key)
        {
            if chunk.is_empty() {
                return false;
            }
            last.text.push_str(chunk);
            last.wrap = None;
            return true;
        }
        self.push(Row::new(kind, key.map(str::to_owned), chunk.to_owned()));
        true
    }

    fn tool_update(&mut self, update: &Value) -> bool {
        let Some(key) = update.get("toolCallId").and_then(Value::as_str) else {
            return false;
        };
        // A call's updates come while it runs: its row is near the tail.
        let Some(row) = self
            .rows
            .iter_mut()
            .rev()
            .take(64)
            .find(|row| row.kind == Kind::Tool && row.key.as_deref() == Some(key))
        else {
            return false;
        };
        let text = tool_line(update);
        if text.is_empty() || text == row.text {
            return false;
        }
        row.text = text;
        row.wrap = None;
        true
    }

    /// The lines the viewport shows, top to bottom: the newest row's last line sits `pad` above the
    /// bottom, each row `gap` below the one before it.
    pub fn layout(&mut self, view: &View, advance: &Advance) -> Vec<Line<'_>> {
        let width = (view.width - 2.0 * view.pad).max(view.line_height);
        let bits = width.to_bits();
        let mut out = Vec::new();
        let mut bottom = view.height - view.pad;
        for (index, row) in self.rows.iter_mut().enumerate().rev() {
            if bottom <= 0.0 {
                break;
            }
            let style = row.style();
            let base = row.text.len() - tail(&row.text).len();
            if !matches!(&row.wrap, Some((at, _)) if *at == bits) {
                row.wrap = Some((bits, wrap(tail(&row.text), width, advance)));
            }
            let wrapped = row.wrap.as_ref().map(|(_, lines)| lines.as_slice()).unwrap_or(&[]);
            for &(start, end) in wrapped.iter().rev() {
                if bottom <= 0.0 {
                    break;
                }
                out.push((index, base + start, base + end, style, bottom));
                bottom -= view.line_height;
            }
            bottom -= view.gap;
        }
        // Collected newest-first; the page draws top to bottom.
        out.reverse();
        out.into_iter()
            .map(|(index, start, end, style, y)| Line {
                text: &self.rows[index].text[start..end],
                style,
                y,
            })
            .collect()
    }
}

/// The viewport, in CSS px.
#[derive(Clone, Copy, Debug)]
pub struct View {
    pub width: f32,
    pub height: f32,
    pub line_height: f32,
    /// Space between rows.
    pub gap: f32,
    /// Inset on every side.
    pub pad: f32,
}

fn chunk_text(update: &Value) -> &str {
    update.pointer("/content/text").and_then(Value::as_str).unwrap_or("")
}

/// A tool call's one line: its title, and its status once it is not running.
fn tool_line(update: &Value) -> String {
    let title = update.get("title").and_then(Value::as_str).unwrap_or("");
    let tool = update.pointer("/_meta/claude/tool").and_then(Value::as_str).unwrap_or("");
    let head = match (tool.is_empty(), title.is_empty()) {
        (true, true) => return String::new(),
        (false, true) => tool.to_owned(),
        (true, false) => title.to_owned(),
        (false, false) => format!("{tool} {title}"),
    };
    match update.get("status").and_then(Value::as_str) {
        Some(status @ ("failed" | "completed")) => format!("{head} ({status})"),
        _ => head,
    }
}

/// The text's last [`TAIL_BYTES`], cut at a character boundary.
fn tail(text: &str) -> &str {
    if text.len() <= TAIL_BYTES {
        return text;
    }
    let mut at = text.len() - TAIL_BYTES;
    while !text.is_char_boundary(at) {
        at += 1;
    }
    &text[at..]
}

/// Greedy word wrap to `width`: byte ranges of `text`, one per line. A hard line break ends a line;
/// a word wider than the line is broken between characters.
pub fn wrap(text: &str, width: f32, advance: &Advance) -> Vec<(usize, usize)> {
    let space = advance.of(' ');
    let mut lines = Vec::new();
    let mut offset = 0;
    for para in text.split('\n') {
        let mut start: Option<usize> = None;
        let mut end = 0;
        let mut used = 0.0f32;
        let mut words = para.split(' ').peekable();
        let mut at = offset;
        while let Some(word) = words.next() {
            let word_at = at;
            at += word.len() + 1;
            if word.is_empty() {
                continue;
            }
            let wide = advance.text(word);
            match start {
                Some(_) if used + space + wide <= width => {
                    used += space + wide;
                    end = word_at + word.len();
                }
                _ => {
                    if let Some(begin) = start.take() {
                        lines.push((begin, end));
                    }
                    if wide <= width {
                        start = Some(word_at);
                        end = word_at + word.len();
                        used = wide;
                        continue;
                    }
                    // Break the word between characters.
                    let mut begin = word_at;
                    let mut run = 0.0f32;
                    for (i, c) in word.char_indices() {
                        let w = advance.of(c);
                        if run + w > width && word_at + i > begin {
                            lines.push((begin, word_at + i));
                            begin = word_at + i;
                            run = 0.0;
                        }
                        run += w;
                    }
                    start = Some(begin);
                    end = word_at + word.len();
                    used = run;
                }
            }
        }
        if let Some(begin) = start {
            lines.push((begin, end));
        }
        offset += para.len() + 1;
    }
    lines
}

/// The narration patterns, compiled once. A pattern that fails to compile leaves this `None`, and
/// every reply then draws as a normal answer instead of crashing the viewport.
struct Narration {
    all_pending: Regex,
    action: Regex,
    clause: Regex,
    ed_adjective_after: Regex,
    finding_verbs: Regex,
    ellipsis: Regex,
    sentence_end: Regex,
    eed: Regex,
}

static NARRATION: LazyLock<Option<Narration>> = LazyLock::new(|| {
    Some(Narration {
        all_pending: Regex::new(
            r"(?i)^(?:both|the|all) [^,;:|]+\b(?:still running|still pending|are running|are pending)$",
        )
        .ok()?,
        action: Regex::new(
            r"(?i)^(?:(?:let me|i['’]ll|i will) (?:check|read|look|inspect|search|run|test|review|verify|wait)|(?:i['’]m |i am )?(?:checking|reading|looking|inspecting|searching|running|testing|reviewing|verifying|waiting))\b",
        )
        .ok()?,
        clause: Regex::new(
            r"(?i)[,;:|]|\b(?:am|is|are|was|were|has|have|had|can|could|should|would|will|because|but|however|therefore|means?|shows?|reveals?|than)\b",
        )
        .ok()?,
        ed_adjective_after: Regex::new(
            r"(?i)^(?:the|a|an|its|this|that|these|those|each|every|all|any|my|your|our|their|some|both|for|of|in|on|from|with|to|at|by|and|or|newly|recently)$",
        )
        .ok()?,
        finding_verbs: Regex::new(
            r"(?i)^(?:found|took|made|gave|got|came|went|ran|saw|left|broke|said|told|kept|held|brought|knew|lost|won|beat|fell|grew|stood|meant|cost|finds|takes|makes|gives|gets|works|fails|passes|helps|saves|costs|beats|wins|needs|breaks|returns|stays|matches|fixes|causes|leads|keeps|hides|drops|skips|hangs|crashes|seems|looks|turns|proves|confirms)$",
        )
        .ok()?,
        ellipsis: Regex::new(
            r"\.{3,}|…",
        )
        .ok()?,
        sentence_end: Regex::new(
            r"[.!?](?:\s+|$)",
        )
        .ok()?,
        eed: Regex::new(
            r"(?i)(?:eed|need)$",
        )
        .ok()?,
    })
});

/// Whether a reply is only short progress narration ("Let me check the logs."), which draws quiet.
/// The port of webviews turns.ts `isWorkNarration` (Leo, 2026-11-13: unknown prose can be a brief
/// answer, so every sentence must be a recognizable action with no finding in it).
pub fn is_work_narration(text: &str) -> bool {
    let text = text.trim();
    let Some(p) = NARRATION.as_ref() else {
        return false;
    };
    if text.is_empty() {
        return false;
    }
    let joined = p.ellipsis.replace_all(text, ".");
    let sentences: Vec<&str> =
        p.sentence_end.split(&joined).filter(|part| !part.trim().is_empty()).collect();
    !sentences.is_empty()
        && sentences.len() <= 2
        && sentences.iter().all(|part| {
            let note = part.trim();
            if p.all_pending.is_match(note) {
                return true;
            }
            let Some(action) = p.action.find(note) else {
                return false;
            };
            let rest = &note[action.end()..];
            !p.clause.is_match(rest) && !has_finite_verb(p, rest)
        })
}

/// Whether the words after a narration's action hold a finite verb ("Checking the cache found no
/// errors."): the first word is the action's object, never a verb.
fn has_finite_verb(p: &Narration, rest: &str) -> bool {
    let words: Vec<String> = rest
        .split_whitespace()
        .map(|word| {
            word.chars().filter(|c| c.is_alphabetic() || matches!(c, '\'' | '’' | '-')).collect()
        })
        .collect();
    words.iter().enumerate().any(|(at, word)| {
        at > 0
            && (p.finding_verbs.is_match(word)
                || (is_ed_word(word)
                    && !p.eed.is_match(word)
                    && !p.ed_adjective_after.is_match(&words[at - 1])))
    })
}

/// A word of two or more letters and then "ed" (turns.ts `/^[\p{L}]{2,}ed$/u`).
fn is_ed_word(word: &str) -> bool {
    word.strip_suffix("ed")
        .is_some_and(|stem| stem.chars().count() >= 2 && stem.chars().all(char::is_alphabetic))
}

#[cfg(test)]
mod tests;
