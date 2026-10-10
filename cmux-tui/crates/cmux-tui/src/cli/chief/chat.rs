//! The chat view's state, pure: finished messages become scrollback lines,
//! and the footer (the Chief's live reply, a status line, the input and a
//! hint) is drawn again on every change.

use serde_json::Value;

use super::adapter::{AGENT_MUX, DraftKind, Drafts, UiEvent};
use super::editor::Editor;
use super::messages::messages;
use super::render::{author_name, clock, message_text, wrap};

/// Left margin of message bodies.
const INDENT: &str = "  ";
const PROMPT: &str = "› ";

/// Text styles a line can ask for; the terminal layer maps them to SGR.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Style {
    Plain,
    Header,
    Dim,
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
        let mut lines = vec![(Style::Plain, String::new())];
        let name = author_name(message, &self.participants);
        let time = clock(message);
        let header = if time.is_empty() { name } else { format!("{name}  {time}") };
        lines.push((Style::Header, header));
        lines.extend(self.body(&message_text(message), Style::Plain));
        lines
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
            UiEvent::Summary(summary) => {
                self.participants = participants(summary);
                (Vec::new(), None)
            }
            UiEvent::Typing { participant, on } if participant == AGENT_MUX => {
                self.busy = *on;
                if !on {
                    self.drafts.on_typing_off(participant);
                }
                (Vec::new(), None)
            }
            UiEvent::Draft(draft) if draft.participant == AGENT_MUX => {
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
