//! A multi-line text editor for the composer, with the readline and emacs
//! motions people expect from opencode, Claude Code, and shells. Stores the
//! text as a Vec<char> so cursor math is by character, and renders into a
//! fixed-width box with soft wrapping and an internal scroll.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use unicode_width::UnicodeWidthChar;

#[derive(Debug, Clone, Default)]
pub struct Editor {
    chars: Vec<char>,
    cursor: usize,
    /// Undo stack of (chars, cursor). Bounded.
    undo: Vec<(Vec<char>, usize)>,
    /// Sent messages, newest last, for Up/Down recall.
    history: Vec<String>,
    /// Index into `history` while browsing, and the draft that was there before.
    browsing: Option<(usize, Vec<char>)>,
    /// Preferred column for vertical motion.
    sticky_col: Option<usize>,
    /// First visible wrapped row, kept so the cursor stays in view.
    pub scroll: usize,
}

fn is_word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

impl Editor {
    pub fn text(&self) -> String {
        self.chars.iter().collect()
    }
    pub fn is_empty(&self) -> bool {
        self.chars.is_empty()
    }
    pub fn cursor(&self) -> usize {
        self.cursor
    }
    pub fn set_text(&mut self, s: &str) {
        self.snapshot();
        self.chars = s.chars().collect();
        self.cursor = self.chars.len();
        self.sticky_col = None;
    }
    pub fn clear(&mut self) {
        if !self.chars.is_empty() {
            self.snapshot();
        }
        self.chars.clear();
        self.cursor = 0;
        self.sticky_col = None;
        self.browsing = None;
        self.scroll = 0;
    }
    /// Take the text for sending; records it in history and clears.
    pub fn take(&mut self) -> String {
        let s = self.text();
        if !s.trim().is_empty() && self.history.last().map(|h| h != &s).unwrap_or(true) {
            self.history.push(s.clone());
            if self.history.len() > 200 {
                self.history.remove(0);
            }
        }
        self.chars.clear();
        self.cursor = 0;
        self.undo.clear();
        self.browsing = None;
        self.sticky_col = None;
        self.scroll = 0;
        s
    }

    fn snapshot(&mut self) {
        self.undo.push((self.chars.clone(), self.cursor));
        if self.undo.len() > 100 {
            self.undo.remove(0);
        }
    }
    pub fn undo(&mut self) {
        if let Some((c, cur)) = self.undo.pop() {
            self.chars = c;
            self.cursor = cur.min(self.chars.len());
        }
    }

    // ------------------------------------------------------------ edits

    pub fn insert(&mut self, c: char) {
        self.snapshot_coalesced(c == '\n' || c == ' ');
        self.chars.insert(self.cursor, c);
        self.cursor += 1;
        self.sticky_col = None;
        self.browsing = None;
    }
    /// Snapshot only at word boundaries so undo removes a word, not a char.
    fn snapshot_coalesced(&mut self, boundary: bool) {
        let last_is_boundary =
            self.cursor > 0 && matches!(self.chars.get(self.cursor - 1), Some(' ') | Some('\n'));
        if boundary || last_is_boundary || self.undo.is_empty() {
            self.snapshot();
        }
    }
    pub fn insert_str(&mut self, s: &str) {
        self.snapshot();
        // One tail move for a paste, rather than one per pasted character.
        let chars: Vec<char> = s.chars().collect();
        let len = chars.len();
        self.chars.splice(self.cursor..self.cursor, chars);
        self.cursor += len;
        self.sticky_col = None;
        self.browsing = None;
    }
    pub fn backspace(&mut self) {
        if self.cursor > 0 {
            self.snapshot_coalesced(false);
            self.cursor -= 1;
            self.chars.remove(self.cursor);
        }
        self.sticky_col = None;
    }
    pub fn delete(&mut self) {
        if self.cursor < self.chars.len() {
            self.snapshot_coalesced(false);
            self.chars.remove(self.cursor);
        }
        self.sticky_col = None;
    }
    pub fn delete_word_back(&mut self) {
        let start = self.word_start_before(self.cursor);
        if start < self.cursor {
            self.snapshot();
            self.chars.drain(start..self.cursor);
            self.cursor = start;
        }
    }
    pub fn delete_word_forward(&mut self) {
        let end = self.word_end_after(self.cursor);
        if end > self.cursor {
            self.snapshot();
            self.chars.drain(self.cursor..end);
        }
    }
    pub fn kill_to_line_end(&mut self) {
        let end = self.line_end(self.cursor);
        if end == self.cursor && end < self.chars.len() {
            // At a line end: join with the next line, like readline.
            self.snapshot();
            self.chars.remove(self.cursor);
        } else if end > self.cursor {
            self.snapshot();
            self.chars.drain(self.cursor..end);
        }
    }
    pub fn kill_to_line_start(&mut self) {
        let start = self.line_start(self.cursor);
        if start < self.cursor {
            self.snapshot();
            self.chars.drain(start..self.cursor);
            self.cursor = start;
        }
    }

    // ---------------------------------------------------------- motions

    fn line_start(&self, pos: usize) -> usize {
        let mut p = pos;
        while p > 0 && self.chars[p - 1] != '\n' {
            p -= 1;
        }
        p
    }
    fn line_end(&self, pos: usize) -> usize {
        let mut p = pos;
        while p < self.chars.len() && self.chars[p] != '\n' {
            p += 1;
        }
        p
    }
    fn word_start_before(&self, pos: usize) -> usize {
        let mut p = pos;
        while p > 0 && !is_word(self.chars[p - 1]) {
            p -= 1;
        }
        while p > 0 && is_word(self.chars[p - 1]) {
            p -= 1;
        }
        p
    }
    fn word_end_after(&self, pos: usize) -> usize {
        let mut p = pos;
        while p < self.chars.len() && !is_word(self.chars[p]) {
            p += 1;
        }
        while p < self.chars.len() && is_word(self.chars[p]) {
            p += 1;
        }
        p
    }
    pub fn left(&mut self) {
        self.cursor = self.cursor.saturating_sub(1);
        self.sticky_col = None;
    }
    pub fn right(&mut self) {
        self.cursor = (self.cursor + 1).min(self.chars.len());
        self.sticky_col = None;
    }
    pub fn word_left(&mut self) {
        self.cursor = self.word_start_before(self.cursor);
        self.sticky_col = None;
    }
    pub fn word_right(&mut self) {
        self.cursor = self.word_end_after(self.cursor);
        self.sticky_col = None;
    }
    pub fn home(&mut self) {
        self.cursor = self.line_start(self.cursor);
        self.sticky_col = None;
    }
    pub fn end(&mut self) {
        self.cursor = self.line_end(self.cursor);
        self.sticky_col = None;
    }
    pub fn to_start(&mut self) {
        self.cursor = 0;
        self.sticky_col = None;
    }
    pub fn to_end(&mut self) {
        self.cursor = self.chars.len();
        self.sticky_col = None;
    }

    fn col(&self, pos: usize) -> usize {
        pos - self.line_start(pos)
    }
    /// Up across logical lines; at the first line, recall older history.
    pub fn up(&mut self) {
        let ls = self.line_start(self.cursor);
        if ls == 0 {
            self.history_older();
            return;
        }
        let col = self.sticky_col.unwrap_or_else(|| self.col(self.cursor));
        let prev_end = ls - 1;
        let prev_start = self.line_start(prev_end);
        self.cursor = (prev_start + col).min(prev_end);
        self.sticky_col = Some(col);
    }
    /// Down across logical lines; at the last line, recall newer history.
    pub fn down(&mut self) {
        let le = self.line_end(self.cursor);
        if le >= self.chars.len() {
            self.history_newer();
            return;
        }
        let col = self.sticky_col.unwrap_or_else(|| self.col(self.cursor));
        let next_start = le + 1;
        let next_end = self.line_end(next_start);
        self.cursor = (next_start + col).min(next_end);
        self.sticky_col = Some(col);
    }

    fn history_older(&mut self) {
        if self.history.is_empty() {
            return;
        }
        let idx = match self.browsing {
            Some((i, _)) => i.saturating_sub(1),
            None => {
                self.browsing = Some((self.history.len(), self.chars.clone()));
                self.history.len() - 1
            }
        };
        if let Some((i, _)) = self.browsing.as_mut() {
            *i = idx;
        }
        self.chars = self.history[idx].chars().collect();
        self.cursor = self.chars.len();
    }
    fn history_newer(&mut self) {
        let Some((i, draft)) = self.browsing.clone() else { return };
        if i + 1 >= self.history.len() {
            self.chars = draft;
            self.cursor = self.chars.len();
            self.browsing = None;
        } else {
            self.browsing = Some((i + 1, draft));
            self.chars = self.history[i + 1].chars().collect();
            self.cursor = self.chars.len();
        }
    }

    /// Enter: a trailing backslash means "newline, not send", like opencode.
    pub fn enter_means_newline(&self) -> bool {
        self.cursor == self.chars.len() && self.chars.last() == Some(&'\\')
    }
    pub fn replace_trailing_backslash_with_newline(&mut self) {
        if self.chars.last() == Some(&'\\') {
            self.snapshot();
            self.chars.pop();
            self.chars.push('\n');
            self.cursor = self.chars.len();
        }
    }

    // --------------------------------------------------------- layout

    /// Wrap into rows of at most `width` cells. Returns rows as
    /// (start_char, end_char) and the (row, col) of the cursor.
    pub fn layout(&self, width: usize) -> (Vec<(usize, usize)>, (usize, usize)) {
        let width = width.max(1);
        let mut rows: Vec<(usize, usize)> = Vec::new();
        let mut cursor_rc = (0, 0);
        let mut row_start = 0;
        let mut col = 0;
        for (i, &c) in self.chars.iter().enumerate() {
            if i == self.cursor {
                cursor_rc = (rows.len(), col);
            }
            if c == '\n' {
                rows.push((row_start, i));
                row_start = i + 1;
                col = 0;
                continue;
            }
            let w = c.width().unwrap_or(0);
            if col + w > width {
                rows.push((row_start, i));
                row_start = i;
                col = 0;
                if i == self.cursor {
                    cursor_rc = (rows.len(), 0);
                }
            }
            col += w;
        }
        if self.cursor == self.chars.len() {
            cursor_rc = (rows.len(), col);
        }
        rows.push((row_start, self.chars.len()));
        // At an exact soft-wrap boundary the insertion cursor owns the
        // first cell of the next row, never the box border / scrollbar.
        if col == width {
            rows.push((self.chars.len(), self.chars.len()));
            if self.cursor == self.chars.len() {
                cursor_rc = (rows.len() - 1, 0);
            }
        }
        cursor_rc.1 = cursor_rc.1.min(width - 1);
        (rows, cursor_rc)
    }

    pub fn row_text(&self, row: (usize, usize)) -> String {
        self.chars[row.0..row.1].iter().collect()
    }

    /// Number of wrapped rows at `width`, for sizing the composer.
    pub fn rows_at(&self, width: usize) -> usize {
        self.layout(width).0.len()
    }

    /// Move the cursor to the character nearest a (row, col) in the layout.
    pub fn click(&mut self, width: usize, row: usize, col: usize) {
        let (rows, _) = self.layout(width);
        let Some(&(s, e)) = rows.get(row) else {
            self.cursor = self.chars.len();
            return;
        };
        let mut pos = s;
        let mut c = 0;
        while pos < e {
            let w = self.chars[pos].width().unwrap_or(0);
            if c + w > col {
                break;
            }
            c += w;
            pos += 1;
        }
        self.cursor = pos;
        self.sticky_col = None;
    }
}

/// The editing keys every text input shares: the composer, the command
/// line, picker filters, form fields and dialogs. Enter, Esc and Tab are
/// left to the caller. Returns true when the key was consumed.
pub fn handle_key(ed: &mut Editor, key: KeyEvent) -> bool {
    let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
    let alt = key.modifiers.contains(KeyModifiers::ALT);
    let sup = key.modifiers.contains(KeyModifiers::SUPER);
    match key.code {
        KeyCode::Backspace if alt || sup => ed.delete_word_back(),
        KeyCode::Backspace => ed.backspace(),
        KeyCode::Delete if alt => ed.delete_word_forward(),
        KeyCode::Delete => ed.delete(),
        KeyCode::Left if alt => ed.word_left(),
        KeyCode::Right if alt => ed.word_right(),
        KeyCode::Left if sup => ed.home(),
        KeyCode::Right if sup => ed.end(),
        KeyCode::Left => ed.left(),
        KeyCode::Right => ed.right(),
        KeyCode::Up => ed.up(),
        KeyCode::Down => ed.down(),
        KeyCode::Home => ed.home(),
        KeyCode::End => ed.end(),
        KeyCode::Char('a') if ctrl => ed.home(),
        KeyCode::Char('e') if ctrl => ed.end(),
        KeyCode::Char('b') if ctrl => ed.left(),
        KeyCode::Char('f') if ctrl => ed.right(),
        KeyCode::Char('b') if alt => ed.word_left(),
        KeyCode::Char('f') if alt => ed.word_right(),
        KeyCode::Char('d') if alt => ed.delete_word_forward(),
        KeyCode::Char('d') if ctrl => ed.delete(),
        KeyCode::Char('w') if ctrl => ed.delete_word_back(),
        KeyCode::Char('k') if ctrl => ed.kill_to_line_end(),
        KeyCode::Char('u') if ctrl => ed.kill_to_line_start(),
        KeyCode::Char('h') if ctrl => ed.backspace(),
        KeyCode::Char('z') if ctrl => ed.undo(),
        KeyCode::Char(c) if !ctrl && !alt && !sup => ed.insert(c),
        _ => return false,
    }
    true
}
