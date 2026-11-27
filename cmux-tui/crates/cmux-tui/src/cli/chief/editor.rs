//! The chat's input: a multiline buffer with shell-like editing keys and a
//! history of sent messages. Pure, so the keys are tested without a tty.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum EditorAction {
    None,
    /// Enter on a non-empty buffer: the text to send.
    Submit(String),
    /// Ctrl+C on an empty buffer: stop the Chief's turn.
    Interrupt,
    /// Ctrl+D on an empty buffer.
    Quit,
}

#[derive(Clone, Debug, Default)]
pub(super) struct Editor {
    /// The buffer as chars; `\n` separates lines.
    text: Vec<char>,
    /// The cursor, an index into `text`.
    pos: usize,
    history: Vec<String>,
    /// The history entry shown, `history.len()` for the draft.
    at: usize,
    draft: String,
}

impl Editor {
    pub(super) fn text(&self) -> String {
        self.text.iter().collect()
    }

    /// The cursor as (line, column in chars).
    pub(super) fn cursor(&self) -> (usize, usize) {
        let before = &self.text[..self.pos];
        let line = before.iter().filter(|c| **c == '\n').count();
        let column = before.iter().rev().take_while(|c| **c != '\n').count();
        (line, column)
    }

    pub(super) fn insert(&mut self, text: &str) {
        for c in text.chars().filter(|c| *c != '\r') {
            self.text.insert(self.pos, c);
            self.pos += 1;
        }
    }

    pub(super) fn key(&mut self, key: KeyEvent) -> EditorAction {
        if key.kind == KeyEventKind::Release {
            return EditorAction::None;
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::Enter if alt || shift => self.insert("\n"),
            KeyCode::Char('j') if ctrl => self.insert("\n"),
            KeyCode::Enter => return self.submit(),
            KeyCode::Char('c') if ctrl => {
                if self.text.is_empty() {
                    return EditorAction::Interrupt;
                }
                self.clear();
            }
            KeyCode::Char('d') if ctrl => {
                if self.text.is_empty() {
                    return EditorAction::Quit;
                }
                if self.pos < self.text.len() {
                    self.text.remove(self.pos);
                }
            }
            KeyCode::Char('a') if ctrl => self.pos = self.line_start(),
            KeyCode::Char('e') if ctrl => self.pos = self.line_end(),
            KeyCode::Char('u') if ctrl => {
                let start = self.line_start();
                self.text.drain(start..self.pos);
                self.pos = start;
            }
            KeyCode::Char('k') if ctrl => {
                let end = self.line_end();
                self.text.drain(self.pos..end);
            }
            KeyCode::Char('w') if ctrl => {
                let start = self.word_back();
                self.text.drain(start..self.pos);
                self.pos = start;
            }
            KeyCode::Char('b') if alt => self.pos = self.word_back(),
            KeyCode::Char('f') if alt => self.pos = self.word_forward(),
            KeyCode::Char(c) if !ctrl => self.insert(&c.to_string()),
            KeyCode::Backspace if self.pos > 0 => {
                self.pos -= 1;
                self.text.remove(self.pos);
            }
            KeyCode::Delete if self.pos < self.text.len() => {
                self.text.remove(self.pos);
            }
            KeyCode::Left if self.pos > 0 => self.pos -= 1,
            KeyCode::Right if self.pos < self.text.len() => self.pos += 1,
            KeyCode::Home => self.pos = self.line_start(),
            KeyCode::End => self.pos = self.line_end(),
            KeyCode::Up => self.vertical(-1),
            KeyCode::Down => self.vertical(1),
            _ => {}
        }
        EditorAction::None
    }

    fn submit(&mut self) -> EditorAction {
        let text = self.text();
        if text.trim().is_empty() {
            return EditorAction::None;
        }
        if self.history.last() != Some(&text) {
            self.history.push(text.clone());
        }
        self.clear();
        EditorAction::Submit(text)
    }

    fn clear(&mut self) {
        self.text.clear();
        self.pos = 0;
        self.at = self.history.len();
        self.draft.clear();
    }

    fn line_start(&self) -> usize {
        self.text[..self.pos].iter().rposition(|c| *c == '\n').map_or(0, |i| i + 1)
    }

    fn line_end(&self) -> usize {
        self.text[self.pos..]
            .iter()
            .position(|c| *c == '\n')
            .map_or(self.text.len(), |i| self.pos + i)
    }

    fn word_back(&self) -> usize {
        let mut i = self.pos;
        while i > 0 && !self.text[i - 1].is_alphanumeric() {
            i -= 1;
        }
        while i > 0 && self.text[i - 1].is_alphanumeric() {
            i -= 1;
        }
        i
    }

    fn word_forward(&self) -> usize {
        let mut i = self.pos;
        while i < self.text.len() && !self.text[i].is_alphanumeric() {
            i += 1;
        }
        while i < self.text.len() && self.text[i].is_alphanumeric() {
            i += 1;
        }
        i
    }

    /// Up and Down move between lines; past the first or last line they
    /// walk the history of sent messages.
    fn vertical(&mut self, step: isize) {
        let (line, column) = self.cursor();
        let lines = self.text.iter().filter(|c| **c == '\n').count() + 1;
        let target = line as isize + step;
        if target >= 0 && (target as usize) < lines {
            let starts: Vec<usize> = std::iter::once(0)
                .chain(
                    self.text.iter().enumerate().filter(|(_, c)| **c == '\n').map(|(i, _)| i + 1),
                )
                .collect();
            let start = starts[target as usize];
            let end = starts.get(target as usize + 1).map_or(self.text.len(), |next| next - 1);
            self.pos = (start + column).min(end);
            return;
        }
        let next = self.at as isize + step;
        if next < 0 || next as usize > self.history.len() {
            return;
        }
        if self.at == self.history.len() {
            self.draft = self.text();
        }
        self.at = next as usize;
        let shown = self.history.get(self.at).cloned().unwrap_or_else(|| self.draft.clone());
        self.text = shown.chars().collect();
        self.pos = self.text.len();
    }
}
