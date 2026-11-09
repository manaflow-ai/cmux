//! Behavior tests for the copy-mode state machine over a real terminal:
//! motions, visual selections and their yanked text (soft wraps, wide
//! characters, blocks), search (smart case, wrap-around, counts), and the
//! viewport moves of the page commands.

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ghostty_vt::{Callbacks, Terminal};

use super::engine::{CopyModeState, CopyOutcome, CopyView};
use super::grid::TerminalGrid;
use crate::config::CopyModeAction as A;

struct Fixture {
    term: Terminal,
    view: CopyView,
    state: CopyModeState,
}

impl Fixture {
    fn new(cols: u16, rows: u16, text: &str) -> Self {
        let mut term = Terminal::new(cols, rows, 1_000_000, Callbacks::default()).unwrap();
        term.vt_write(text.as_bytes());
        let scrollbar = term.scrollbar().unwrap();
        let view = CopyView { top: scrollbar.offset, height: rows };
        let state = CopyModeState::enter(&mut TerminalGrid::new(&mut term), view);
        Self { term, view, state }
    }

    fn run(&mut self, action: A) -> CopyOutcome {
        self.state.apply(&mut TerminalGrid::new(&mut self.term), &mut self.view, action)
    }

    fn runs(&mut self, actions: &[A]) {
        for &action in actions {
            assert_eq!(self.run(action), CopyOutcome::Stay, "{action:?} left copy mode");
        }
    }

    fn key(&mut self, code: KeyCode, text: Option<&str>) {
        let key = KeyEvent::new(code, KeyModifiers::NONE);
        assert!(self.state.input_key(
            &mut TerminalGrid::new(&mut self.term),
            &mut self.view,
            &key,
            text
        ));
    }

    fn search(&mut self, forward: bool, needle: &str) {
        self.run(if forward { A::SearchForward } else { A::SearchBackward });
        for c in needle.chars() {
            self.key(KeyCode::Char(c), Some(&c.to_string()));
        }
        self.key(KeyCode::Enter, None);
    }

    fn at(&self) -> (u64, u16) {
        (self.state.cursor.row, self.state.cursor.col)
    }

    fn count(&self) -> String {
        self.state.search.as_ref().unwrap().count_label()
    }

    fn yank(&mut self) -> String {
        match self.run(A::Yank) {
            CopyOutcome::Yank(text) => text,
            other => panic!("yank returned {other:?}"),
        }
    }
}

#[test]
fn copy_mode_starts_at_the_terminal_cursor() {
    let fixture = Fixture::new(40, 5, "one\r\ntwo three");
    assert_eq!(fixture.at(), (1, 9));
}

#[test]
fn copy_mode_cursor_and_word_motions_follow_vim() {
    let mut f = Fixture::new(40, 5, "foo bar_baz, qux\r\nsecond line");
    f.run(A::HistoryTop);
    assert_eq!(f.at(), (0, 0));
    f.run(A::WordNext);
    assert_eq!(f.at(), (0, 4), "w skips to bar_baz");
    f.run(A::WordNext);
    assert_eq!(f.at(), (0, 11), "punctuation is its own word");
    f.run(A::WordNext);
    assert_eq!(f.at(), (0, 13));
    f.run(A::WordNext);
    assert_eq!(f.at(), (1, 0), "w crosses a hard line end");
    f.run(A::WordPrev);
    assert_eq!(f.at(), (0, 13));
    f.run(A::WordEnd);
    assert_eq!(f.at(), (0, 15));
    f.run(A::BigWordPrev);
    assert_eq!(f.at(), (0, 13));
    f.run(A::BigWordPrev);
    assert_eq!(f.at(), (0, 4), "WORD motions treat bar_baz, as one word");
    f.run(A::LineEnd);
    assert_eq!(f.at(), (0, 15));
    f.run(A::LineStart);
    assert_eq!(f.at(), (0, 0));
    f.runs(&[A::CursorRight, A::CursorRight, A::CursorDown]);
    assert_eq!(f.at(), (1, 2));
    f.run(A::CursorLeft);
    assert_eq!(f.at(), (1, 1));
    f.run(A::CursorUp);
    assert_eq!(f.at(), (0, 1));
    f.run(A::HistoryBottom);
    assert_eq!(f.at(), (1, 0), "G goes to the last row with text");
    f.run(A::CursorUp);
    f.run(A::CursorUp);
    assert_eq!(f.at(), (0, 0), "k stops at the top of history");
}

#[test]
fn copy_mode_char_selection_joins_soft_wrapped_rows() {
    let mut f = Fixture::new(10, 5, "abcdefghijklmno\r\nxyz");
    f.runs(&[A::HistoryTop, A::SelectChar, A::CursorDown, A::LineEnd]);
    assert_eq!(f.at(), (1, 4));
    assert_eq!(f.yank(), "abcdefghijklmno");
}

#[test]
fn copy_mode_line_selection_takes_the_whole_logical_line() {
    let mut f = Fixture::new(10, 5, "abcdefghijklmno\r\nxyz");
    f.runs(&[A::HistoryTop, A::CursorDown, A::SelectLine]);
    assert_eq!(f.yank(), "abcdefghijklmno");

    let mut f = Fixture::new(10, 5, "abcdefghijklmno\r\nxyz");
    f.runs(&[A::HistoryTop, A::CursorDown, A::CursorDown, A::SelectLine, A::CursorUp]);
    assert_eq!(f.yank(), "abcdefghijklmno\nxyz");

    let mut f = Fixture::new(10, 5, "abcdefghijklmno\r\nxyz");
    f.runs(&[A::HistoryTop]);
    match f.run(A::YankLine) {
        CopyOutcome::Yank(text) => assert_eq!(text, "abcdefghijklmno"),
        other => panic!("Y returned {other:?}"),
    }
}

#[test]
fn copy_mode_moves_over_wide_characters_as_one_cell() {
    let mut f = Fixture::new(20, 4, "ab橋cd");
    f.runs(&[A::HistoryTop, A::CursorRight, A::CursorRight]);
    assert_eq!(f.at(), (0, 2), "the cursor lands on the wide lead");
    f.run(A::CursorRight);
    assert_eq!(f.at(), (0, 4), "l skips the wide spacer");
    f.run(A::CursorLeft);
    assert_eq!(f.at(), (0, 2));
    f.run(A::SelectChar);
    assert_eq!(f.yank(), "橋");
}

#[test]
fn copy_mode_selection_joins_a_wide_character_that_soft_wrapped() {
    let mut f = Fixture::new(4, 3, "ABC橋D");
    f.runs(&[A::HistoryTop, A::LineEnd]);
    assert_eq!(f.at(), (0, 2), "$ ignores the wrap spacer");
    f.run(A::CursorRight);
    assert_eq!(f.at(), (0, 2), "l does not stop on the wrap spacer");
    f.runs(&[A::LineStart, A::SelectChar, A::CursorDown]);
    assert_eq!(f.at(), (1, 0));
    assert_eq!(f.yank(), "ABC橋");
}

#[test]
fn copy_mode_block_selection_cuts_columns() {
    let mut f = Fixture::new(10, 4, "abcdef\r\nghijkl\r\nmnopqr");
    f.runs(&[A::HistoryTop, A::CursorRight, A::SelectBlock, A::CursorDown]);
    f.runs(&[A::CursorRight, A::CursorRight]);
    assert_eq!(f.yank(), "bcd\nhij");
}

#[test]
fn copy_mode_selection_toggles_swaps_and_cancels_before_exit() {
    let mut f = Fixture::new(20, 4, "hello world");
    f.runs(&[A::HistoryTop, A::SelectChar, A::WordNext]);
    assert_eq!(f.at(), (0, 6));
    f.run(A::SwapSelectionEnd);
    assert_eq!(f.at(), (0, 0), "o moves the cursor to the other end");
    f.run(A::LineEnd);
    assert_eq!(f.yank(), "world", "the swapped anchor stays at the old cursor");

    let mut f = Fixture::new(20, 4, "hello");
    f.runs(&[A::HistoryTop, A::SelectChar]);
    assert!(f.state.selection.is_some());
    assert_eq!(f.run(A::Cancel), CopyOutcome::Stay, "Esc first clears the selection");
    assert!(f.state.selection.is_none());
    assert_eq!(f.run(A::Cancel), CopyOutcome::Exit);
    assert_eq!(f.run(A::Exit), CopyOutcome::Exit);
}

#[test]
fn copy_mode_yank_without_a_selection_stays_and_says_so() {
    let mut f = Fixture::new(20, 4, "hello");
    assert_eq!(f.run(A::Yank), CopyOutcome::Stay);
    assert_eq!(f.state.notice, Some(crate::localization::catalog().copy_mode.nothing_selected));
}

#[test]
fn copy_mode_search_wraps_counts_and_reverses() {
    let mut f = Fixture::new(30, 6, "alpha Foo\r\nbeta foo\r\ngamma FOO\r\n");
    assert_eq!(f.at(), (3, 0));
    f.search(true, "foo");
    assert_eq!(f.at(), (0, 6), "a forward search from the bottom wraps to the top");
    assert_eq!(f.count(), "1/3");
    f.run(A::SearchNext);
    assert_eq!((f.at(), f.count()), ((1, 5), "2/3".to_string()));
    f.run(A::SearchNext);
    assert_eq!((f.at(), f.count()), ((2, 6), "3/3".to_string()));
    f.run(A::SearchNext);
    assert_eq!((f.at(), f.count()), ((0, 6), "1/3".to_string()), "n wraps around");
    f.run(A::SearchPrev);
    assert_eq!((f.at(), f.count()), ((2, 6), "3/3".to_string()), "N wraps backward");

    f.search(false, "foo");
    assert_eq!(f.at(), (1, 5), "? searches toward older output");
    f.run(A::SearchNext);
    assert_eq!(f.at(), (0, 6), "n keeps the ? direction");
}

#[test]
fn copy_mode_search_is_smart_case() {
    let mut f = Fixture::new(30, 6, "alpha Foo\r\nbeta foo\r\ngamma FOO\r\n");
    f.search(true, "Foo");
    assert_eq!((f.at(), f.count()), ((0, 6), "1/1".to_string()), "an uppercase needle is exact");
    f.search(true, "FOO");
    assert_eq!((f.at(), f.count()), ((2, 6), "1/1".to_string()));
    f.search(true, "absent");
    assert_eq!(f.count(), "0/0");
    assert_eq!(f.state.notice, Some(crate::localization::catalog().copy_mode.no_match));
    assert_eq!(f.at(), (2, 6), "a failed search keeps the cursor");
}

#[test]
fn copy_mode_search_reaches_scrollback_and_scrolls_the_view() {
    let lines: String = (1..=200).map(|n| format!("{n}\r\n")).collect();
    let mut f = Fixture::new(20, 10, &lines);
    let bottom_top = f.view.top;
    assert!(bottom_top > 100, "the fixture must have scrollback");
    f.search(true, "137");
    assert_eq!(f.at(), (136, 0));
    assert!(f.view.contains_row(136), "the view follows the match");
    assert!(f.view.top < bottom_top);
    f.runs(&[A::SelectLine]);
    assert_eq!(f.yank(), "137");
}

#[test]
fn copy_mode_search_prompt_edits_and_cancels() {
    let mut f = Fixture::new(30, 6, "alpha beta\r\n");
    f.run(A::SearchForward);
    f.key(KeyCode::Char('x'), Some("x"));
    f.key(KeyCode::Backspace, None);
    assert_eq!(f.state.input.as_ref().map(|input| input.text.as_str()), Some(""));
    f.key(KeyCode::Backspace, None);
    assert!(f.state.input.is_none(), "backspace on an empty prompt closes it");
    f.run(A::SearchForward);
    f.key(KeyCode::Char('b'), Some("b"));
    f.key(KeyCode::Esc, None);
    assert!(f.state.input.is_none() && f.state.search.is_none());
    assert_eq!(f.run(A::SearchNext), CopyOutcome::Stay);
    assert_eq!(f.state.notice, Some(crate::localization::catalog().copy_mode.no_previous_search));
}

#[test]
fn copy_mode_page_commands_move_view_and_cursor_together() {
    let lines: String = (1..=100).map(|n| format!("{n}\r\n")).collect();
    let mut f = Fixture::new(20, 10, &lines);
    let (top, row) = (f.view.top, f.at().0);
    f.run(A::HalfPageUp);
    assert_eq!((f.view.top, f.at().0), (top - 5, row - 5));
    f.run(A::PageUp);
    assert_eq!((f.view.top, f.at().0), (top - 15, row - 15));
    f.run(A::PageDown);
    f.run(A::HalfPageDown);
    assert_eq!((f.view.top, f.at().0), (top, row));
    f.run(A::HalfPageDown);
    assert_eq!(f.view.top, top, "the view cannot pass the bottom");
    assert_eq!(f.at().0, row, "the cursor is already on the last row");

    f.run(A::ScrollLineUp);
    assert_eq!((f.view.top, f.at().0), (top - 1, row - 1), "the cursor stays in view");
    f.run(A::ViewTop);
    assert_eq!(f.at().0, top - 1);
    f.run(A::ViewBottom);
    assert_eq!(f.at().0, top + 8);
    f.run(A::HistoryTop);
    assert_eq!((f.view.top, f.at()), (0, (0, 0)));
}
