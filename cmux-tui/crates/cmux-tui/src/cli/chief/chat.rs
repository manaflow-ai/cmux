//! The chat view's state, pure: finished messages become scrollback lines,
//! and the footer (the Chief's live reply, a status line, the input and a
//! hint) is drawn again on every change.

use serde_json::Value;

use super::adapter::{AGENT_MUX, DraftKind, Drafts, UiEvent};
use super::editor::Editor;
use super::messages::messages;
use super::render::{author_name, clock, message_text, reactions_line, wrap};

/// Left margin of message bodies.
const INDENT: &str = "  ";
const PROMPT: &str = "› ";

/// Text styles a line can ask for; the terminal layer maps them to SGR.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Style {
    Plain,
    Header,
    Dim,
    /// A body line wrapped to the width with its terminal hyperlinks written in
    /// (`hyperlink::mark`): printed as it is, since clipping would count the escapes.
    Linked,
}

pub(super) type Line = (Style, String);

#[derive(Debug)]
pub(super) struct Chat {
    /// The terminal's width in columns.
    pub width: usize,
    pub participants: Vec<Value>,
    /// The highest message seq shown.
    pub last_seq: u64,
    pub drafts: Drafts,
    /// The Chief is working (typing on).
    pub busy: bool,
    pub show_thoughts: bool,
    /// Links (subagent, Markdown web links, bare web URLs) show as their labels and print as
    /// terminal hyperlinks (`hyperlink`), each only in its own message's lines.
    pub hyperlinks: bool,
    /// The chat's Chief (`backend::chief_of`).
    pub chief: String,
    /// The seq of each message shown, by id (a reply names its parent's seq).
    pub seqs: std::collections::HashMap<String, u64>,
    /// The chat ids `/chats` listed, in its order (`/open N`).
    pub listed: Vec<String>,
}

impl Default for Chat {
    fn default() -> Self {
        Self {
            width: 80,
            participants: Vec::new(),
            last_seq: 0,
            drafts: Drafts::default(),
            busy: false,
            show_thoughts: false,
            hyperlinks: false,
            chief: AGENT_MUX.to_owned(),
            seqs: std::collections::HashMap::new(),
            listed: Vec::new(),
        }
    }
}

impl Chat {
    /// Lines for one finished message; empty when it was shown already.
    pub(super) fn message(&mut self, message: &Value) -> Vec<Line> {
        let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
        if seq != 0 && seq <= self.last_seq {
            return Vec::new();
        }
        self.last_seq = self.last_seq.max(seq);
        self.drafts.on_message(message);
        if let Some(id) = message.get("id").and_then(Value::as_str) {
            self.seqs.insert(id.to_owned(), seq);
        }
        let mut lines = vec![(Style::Plain, String::new())];
        let name = author_name(message, &self.participants);
        let time = clock(message);
        let mut header = if time.is_empty() { name } else { format!("{name}  {time}") };
        if seq != 0 {
            header.push_str(&format!("  #{seq}"));
        }
        lines.push((Style::Header, header));
        if let Some(parent) = message.pointer("/reply_to/message_id").and_then(Value::as_str) {
            let parent =
                self.seqs.get(parent).map_or_else(|| parent.to_owned(), |s| format!("#{s}"));
            lines.push((Style::Dim, format!("{INDENT}↳ {parent}")));
        }
        let text = message_text(message);
        let reactions = reactions_line(message).map(|line| (Style::Dim, format!("{INDENT}{line}")));
        if !self.hyperlinks {
            lines.extend(self.body(&text, Style::Plain));
            lines.extend(reactions);
            return lines;
        }
        let (shown, links) = super::hyperlink::split(&text);
        let body = self.body(&shown, Style::Plain);
        if links.is_empty() {
            lines.extend(body);
        } else {
            lines.extend(
                body.into_iter()
                    .map(|(_, line)| (Style::Linked, super::hyperlink::mark(&line, &links))),
            );
        }
        lines.extend(reactions);
        lines
    }

    /// The note line of an edited, retracted or reacted message shown
    /// earlier (scrollback is not redrawn): `#SEQ` and what it shows now.
    pub(super) fn updated(&self, message: &Value) -> Vec<Line> {
        let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
        if seq == 0 || seq > self.last_seq {
            return Vec::new();
        }
        let reactions = reactions_line(message).unwrap_or_default();
        let text = message_text(message);
        let first = text.lines().next().unwrap_or("");
        let mut line = format!("#{seq} ✎ {first}");
        if !reactions.is_empty() {
            line = format!("#{seq} {reactions}  {first}");
        }
        self.note(&super::tui::clip(&line, self.width.saturating_sub(INDENT.len() + 1)))
    }

    fn body(&self, text: &str, style: Style) -> Vec<Line> {
        let width = self.width.saturating_sub(INDENT.len() + 1);
        wrap(text, width).into_iter().map(|l| (style, format!("{INDENT}{l}"))).collect()
    }

    /// Applies one event; returns the scrollback lines it finished, and
    /// whether a message newer than `last_seq + 1` means some were missed.
    pub(super) fn apply(&mut self, event: &UiEvent) -> (Vec<Line>, Option<u64>) {
        match event {
            UiEvent::Message(message) => {
                let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
                if self.last_seq != 0 && seq > self.last_seq + 1 {
                    return (Vec::new(), Some(seq));
                }
                (self.message(message), None)
            }
            UiEvent::Snapshot { summary, messages, .. } => {
                self.participants = participants(summary);
                let lines = messages.iter().flat_map(|m| self.message(m)).collect();
                (lines, None)
            }
            UiEvent::Updated(message) => (self.updated(message), None),
            UiEvent::Summary(summary) => {
                self.participants = participants(summary);
                (Vec::new(), None)
            }
            UiEvent::Typing { participant, on } if *participant == self.chief => {
                self.busy = *on;
                if !on {
                    self.drafts.on_typing_off(participant);
                }
                (Vec::new(), None)
            }
            UiEvent::Draft(draft) if draft.participant == self.chief => {
                self.drafts.apply(draft);
                (Vec::new(), None)
            }
            _ => (Vec::new(), None),
        }
    }

    /// A note line in scrollback (command answers, errors).
    pub(super) fn note(&self, text: &str) -> Vec<Line> {
        text.split('\n').map(|l| (Style::Dim, format!("{INDENT}{l}"))).collect()
    }

    /// The footer for `width` columns and at most `height` rows, and the
    /// cursor (row in the footer, column).
    pub(super) fn footer(
        &self,
        editor: &Editor,
        width: usize,
        height: usize,
    ) -> (Vec<Line>, (usize, usize)) {
        let m = messages();
        let inner = width.saturating_sub(INDENT.len() + 1).max(8);
        let mut live: Vec<Line> = Vec::new();
        for turn in &self.drafts.turns {
            for (kind, text) in turn.segments.values() {
                if *kind == DraftKind::Thought && !self.show_thoughts {
                    continue;
                }
                let style = if *kind == DraftKind::Thought { Style::Dim } else { Style::Plain };
                live.extend(wrap(text, inner).into_iter().map(|l| (style, format!("{INDENT}{l}"))));
            }
        }
        let status = if self.busy { m.typing } else { "" };
        let mut input: Vec<Line> = Vec::new();
        let text = editor.text();
        let (cursor_line, cursor_column) = editor.cursor();
        let input_width = width.saturating_sub(PROMPT.chars().count() + 1).max(8);
        let mut cursor = (0, PROMPT.chars().count());
        for (index, line) in text.split('\n').enumerate() {
            let pieces = wrap(line, input_width);
            for (piece_index, piece) in pieces.iter().enumerate() {
                if index == cursor_line {
                    let start: usize =
                        pieces[..piece_index].iter().map(|p| p.chars().count()).sum();
                    let len = piece.chars().count();
                    let last = piece_index + 1 == pieces.len();
                    if cursor_column >= start && (cursor_column < start + len || last) {
                        let column: usize = piece
                            .chars()
                            .take(cursor_column - start)
                            .map(|c| unicode_width::UnicodeWidthChar::width(c).unwrap_or(0))
                            .sum();
                        cursor = (input.len(), PROMPT.chars().count() + column);
                    }
                }
                let lead = if input.is_empty() { PROMPT } else { "  " };
                input.push((Style::Plain, format!("{lead}{piece}")));
            }
        }
        let fixed = 3 + input.len();
        let room = height.saturating_sub(fixed);
        let mut lines: Vec<Line> = live.split_off(live.len().saturating_sub(room));
        lines.push((Style::Dim, format!("{INDENT}{status}")));
        lines.push((Style::Dim, "─".repeat(width.saturating_sub(1))));
        let input_top = lines.len();
        lines.extend(input);
        lines.push((Style::Dim, m.hint.to_owned()));
        (lines, (input_top + cursor.0, cursor.1))
    }
}

fn participants(summary: &Value) -> Vec<Value> {
    summary.get("participants").and_then(Value::as_array).cloned().unwrap_or_default()
}
