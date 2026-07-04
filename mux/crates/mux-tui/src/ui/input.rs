use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputEvent {
    None,
    Changed,
    Commit,
    Cancel,
}

#[derive(Debug, Clone)]
pub struct TextInput {
    pub buffer: String,
    pub cursor: usize,
    scroll: usize,
}

impl TextInput {
    pub fn new(buffer: String) -> Self {
        TextInput { cursor: buffer.len(), buffer, scroll: 0 }
    }

    pub fn as_str(&self) -> &str {
        &self.buffer
    }

    pub fn clear(&mut self) -> bool {
        if self.buffer.is_empty() && self.cursor == 0 {
            return false;
        }
        self.buffer.clear();
        self.cursor = 0;
        self.scroll = 0;
        true
    }

    pub fn insert_str(&mut self, text: &str) -> bool {
        if text.is_empty() {
            return false;
        }
        self.buffer.insert_str(self.cursor, text);
        self.cursor += text.len();
        true
    }

    pub fn handle_key(&mut self, key: &KeyEvent) -> InputEvent {
        match key.code {
            KeyCode::Enter => InputEvent::Commit,
            KeyCode::Esc => InputEvent::Cancel,
            KeyCode::Home => {
                self.move_start();
                InputEvent::None
            }
            KeyCode::End => {
                self.move_end();
                InputEvent::None
            }
            KeyCode::Left if key.modifiers.contains(KeyModifiers::ALT) => {
                self.move_word_left();
                InputEvent::None
            }
            KeyCode::Right if key.modifiers.contains(KeyModifiers::ALT) => {
                self.move_word_right();
                InputEvent::None
            }
            KeyCode::Left => {
                self.move_left();
                InputEvent::None
            }
            KeyCode::Right => {
                self.move_right();
                InputEvent::None
            }
            KeyCode::Backspace if key.modifiers.contains(KeyModifiers::ALT) => {
                self.delete_word_left();
                InputEvent::Changed
            }
            KeyCode::Backspace => {
                self.delete_left();
                InputEvent::Changed
            }
            KeyCode::Delete => {
                self.delete_right();
                InputEvent::Changed
            }
            KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.handle_control(c)
            }
            KeyCode::Char(c) if key.modifiers.contains(KeyModifiers::ALT) => self.handle_alt(c),
            KeyCode::Char(c)
                if !key.modifiers.intersects(
                    KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER,
                ) =>
            {
                self.insert_char(c);
                InputEvent::Changed
            }
            _ => InputEvent::None,
        }
    }

    pub fn visible_text_and_cursor(&mut self, width: usize) -> (String, usize) {
        if width == 0 {
            return (String::new(), 0);
        }
        self.ensure_cursor_visible(width);
        let scroll_col = self.char_col(self.scroll);
        let cursor_col = self.char_col(self.cursor);
        let text: String = self.buffer[self.scroll..].chars().take(width).collect();
        (text, cursor_col.saturating_sub(scroll_col).min(width))
    }

    pub fn set_cursor_from_visible_column(&mut self, column: usize, width: usize) {
        if width == 0 {
            return;
        }
        self.ensure_cursor_visible(width);
        let scroll_col = self.char_col(self.scroll);
        let target = scroll_col + column.min(width.saturating_sub(1));
        self.cursor = self.byte_for_char_col(target.min(self.char_len()));
    }

    fn handle_control(&mut self, c: char) -> InputEvent {
        match c.to_ascii_lowercase() {
            'a' => self.move_start(),
            'e' => self.move_end(),
            'd' => {
                self.delete_right();
                return InputEvent::Changed;
            }
            'w' => {
                self.delete_word_left();
                return InputEvent::Changed;
            }
            'k' => {
                self.kill_end();
                return InputEvent::Changed;
            }
            'u' => {
                self.kill_start();
                return InputEvent::Changed;
            }
            'c' => {
                self.clear();
                return InputEvent::Changed;
            }
            _ => {}
        }
        InputEvent::None
    }

    fn handle_alt(&mut self, c: char) -> InputEvent {
        match c.to_ascii_lowercase() {
            'b' => self.move_word_left(),
            'f' => self.move_word_right(),
            'd' => {
                self.delete_word_right();
                return InputEvent::Changed;
            }
            _ => {}
        }
        InputEvent::None
    }

    fn insert_char(&mut self, c: char) {
        self.buffer.insert(self.cursor, c);
        self.cursor += c.len_utf8();
    }

    fn move_start(&mut self) {
        self.cursor = 0;
    }

    fn move_end(&mut self) {
        self.cursor = self.buffer.len();
    }

    fn move_left(&mut self) {
        self.cursor = self.prev_boundary(self.cursor);
    }

    fn move_right(&mut self) {
        self.cursor = self.next_boundary(self.cursor);
    }

    fn move_word_left(&mut self) {
        self.cursor = self.word_left(self.cursor);
    }

    fn move_word_right(&mut self) {
        self.cursor = self.word_right(self.cursor);
    }

    fn delete_left(&mut self) {
        let start = self.prev_boundary(self.cursor);
        self.delete_range(start, self.cursor);
    }

    fn delete_right(&mut self) {
        let end = self.next_boundary(self.cursor);
        self.delete_range(self.cursor, end);
    }

    fn delete_word_left(&mut self) {
        let start = self.word_left(self.cursor);
        self.delete_range(start, self.cursor);
    }

    fn delete_word_right(&mut self) {
        let end = self.word_right(self.cursor);
        self.delete_range(self.cursor, end);
    }

    fn kill_end(&mut self) {
        self.delete_range(self.cursor, self.buffer.len());
    }

    fn kill_start(&mut self) {
        self.delete_range(0, self.cursor);
    }

    fn delete_range(&mut self, start: usize, end: usize) {
        if start >= end {
            return;
        }
        self.buffer.replace_range(start..end, "");
        self.cursor = start;
        self.scroll = self.scroll.min(self.cursor);
        if !self.buffer.is_char_boundary(self.scroll) {
            self.scroll = self.prev_boundary(self.scroll);
        }
    }

    fn word_left(&self, from: usize) -> usize {
        let mut idx = from;
        while let Some((prev, ch)) = self.prev_char(idx) {
            if ch.is_alphanumeric() {
                break;
            }
            idx = prev;
        }
        while let Some((prev, ch)) = self.prev_char(idx) {
            if !ch.is_alphanumeric() {
                break;
            }
            idx = prev;
        }
        idx
    }

    fn word_right(&self, from: usize) -> usize {
        let mut idx = from;
        while let Some((next, ch)) = self.char_at(idx) {
            if ch.is_alphanumeric() {
                break;
            }
            idx = next;
        }
        while let Some((next, ch)) = self.char_at(idx) {
            if !ch.is_alphanumeric() {
                break;
            }
            idx = next;
        }
        idx
    }

    fn prev_boundary(&self, from: usize) -> usize {
        if from == 0 {
            return 0;
        }
        self.buffer[..from].char_indices().last().map(|(idx, _)| idx).unwrap_or(0)
    }

    fn next_boundary(&self, from: usize) -> usize {
        if from >= self.buffer.len() {
            return self.buffer.len();
        }
        let mut chars = self.buffer[from..].char_indices();
        let _ = chars.next();
        chars.next().map(|(idx, _)| from + idx).unwrap_or(self.buffer.len())
    }

    fn prev_char(&self, from: usize) -> Option<(usize, char)> {
        self.buffer[..from].char_indices().last()
    }

    fn char_at(&self, from: usize) -> Option<(usize, char)> {
        let ch = self.buffer[from..].chars().next()?;
        Some((from + ch.len_utf8(), ch))
    }

    fn ensure_cursor_visible(&mut self, width: usize) {
        if width == 0 {
            return;
        }
        if self.cursor < self.scroll {
            self.scroll = self.cursor;
        }
        let cursor_col = self.char_col(self.cursor);
        let scroll_col = self.char_col(self.scroll);
        if cursor_col < scroll_col {
            self.scroll = self.cursor;
        } else if cursor_col > scroll_col + width {
            let target_col = cursor_col.saturating_sub(width);
            self.scroll = self.byte_for_char_col(target_col);
        }
    }

    fn char_len(&self) -> usize {
        self.buffer.chars().count()
    }

    fn char_col(&self, byte: usize) -> usize {
        self.buffer[..byte].chars().count()
    }

    fn byte_for_char_col(&self, col: usize) -> usize {
        self.buffer.char_indices().nth(col).map(|(idx, _)| idx).unwrap_or(self.buffer.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, mods)
    }

    fn text_input(s: &str) -> TextInput {
        TextInput::new(s.to_string())
    }

    #[test]
    fn cursor_movement_and_words() {
        let mut input = text_input("foo  bar-baz qux");
        input.cursor = 0;
        input.handle_key(&key(KeyCode::Char('f'), KeyModifiers::ALT));
        assert_eq!(input.cursor, 3);
        input.handle_key(&key(KeyCode::Char('f'), KeyModifiers::ALT));
        assert_eq!(input.cursor, 8);
        input.handle_key(&key(KeyCode::Right, KeyModifiers::ALT));
        assert_eq!(input.cursor, 12);
        input.handle_key(&key(KeyCode::Char('b'), KeyModifiers::ALT));
        assert_eq!(input.cursor, 9);
        input.handle_key(&key(KeyCode::Left, KeyModifiers::ALT));
        assert_eq!(input.cursor, 5);
    }

    #[test]
    fn line_start_and_end() {
        let mut input = text_input("abc");
        input.handle_key(&key(KeyCode::Char('a'), KeyModifiers::CONTROL));
        assert_eq!(input.cursor, 0);
        input.handle_key(&key(KeyCode::Char('e'), KeyModifiers::CONTROL));
        assert_eq!(input.cursor, 3);
        input.handle_key(&key(KeyCode::Home, KeyModifiers::NONE));
        assert_eq!(input.cursor, 0);
        input.handle_key(&key(KeyCode::End, KeyModifiers::NONE));
        assert_eq!(input.cursor, 3);
    }

    #[test]
    fn delete_word_left_from_various_positions() {
        let mut input = text_input("foo  bar-baz qux");
        input.cursor = 12;
        input.handle_key(&key(KeyCode::Char('w'), KeyModifiers::CONTROL));
        assert_eq!(input.as_str(), "foo  bar- qux");
        assert_eq!(input.cursor, 9);

        input.cursor = 8;
        input.handle_key(&key(KeyCode::Backspace, KeyModifiers::ALT));
        assert_eq!(input.as_str(), "foo  - qux");
        assert_eq!(input.cursor, 5);
    }

    #[test]
    fn kill_and_clear() {
        let mut input = text_input("abcdef");
        input.cursor = 3;
        input.handle_key(&key(KeyCode::Char('k'), KeyModifiers::CONTROL));
        assert_eq!(input.as_str(), "abc");
        assert_eq!(input.cursor, 3);
        input.handle_key(&key(KeyCode::Char('u'), KeyModifiers::CONTROL));
        assert_eq!(input.as_str(), "");
        assert_eq!(input.cursor, 0);

        let mut input = text_input("abcdef");
        input.handle_key(&key(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert_eq!(input.as_str(), "");
        assert_eq!(input.cursor, 0);
    }

    #[test]
    fn insert_at_cursor() {
        let mut input = text_input("tab");
        input.handle_key(&key(KeyCode::Char('a'), KeyModifiers::CONTROL));
        input.handle_key(&key(KeyCode::Char('m'), KeyModifiers::NONE));
        input.handle_key(&key(KeyCode::Char('y'), KeyModifiers::NONE));
        input.handle_key(&key(KeyCode::Char('-'), KeyModifiers::NONE));
        assert_eq!(input.as_str(), "my-tab");
        assert_eq!(input.cursor, 3);
    }

    #[test]
    fn utf8_safe_movement_and_deletion() {
        let mut input = text_input("héllo wörld");
        input.handle_key(&key(KeyCode::Char('a'), KeyModifiers::CONTROL));
        input.handle_key(&key(KeyCode::Right, KeyModifiers::NONE));
        input.handle_key(&key(KeyCode::Right, KeyModifiers::NONE));
        assert!(input.as_str().is_char_boundary(input.cursor));
        input.handle_key(&key(KeyCode::Backspace, KeyModifiers::NONE));
        assert_eq!(input.as_str(), "hllo wörld");
        assert!(input.as_str().is_char_boundary(input.cursor));
        input.handle_key(&key(KeyCode::Char('f'), KeyModifiers::ALT));
        assert_eq!(&input.as_str()[..input.cursor], "hllo");
        assert!(input.as_str().is_char_boundary(input.cursor));
    }

    #[test]
    fn visible_text_keeps_cursor_visible() {
        let mut input = text_input("abcdef");
        let (shown, cursor) = input.visible_text_and_cursor(3);
        assert_eq!(shown, "def");
        assert_eq!(cursor, 3);
        input.handle_key(&key(KeyCode::Char('a'), KeyModifiers::CONTROL));
        let (shown, cursor) = input.visible_text_and_cursor(3);
        assert_eq!(shown, "abc");
        assert_eq!(cursor, 0);
    }
}
