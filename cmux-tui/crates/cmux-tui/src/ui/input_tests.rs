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
fn paste_strips_control_characters() {
    let mut input = text_input("ab");
    input.cursor = 1;
    assert!(input.insert_str("x\n\r\ty\u{0007}"));
    assert_eq!(input.as_str(), "axyb");
    assert_eq!(input.cursor, 3);
}

#[test]
fn deletion_reports_changed_only_when_text_was_removed() {
    let no_op_keys = [
        key(KeyCode::Backspace, KeyModifiers::NONE),
        key(KeyCode::Delete, KeyModifiers::NONE),
        key(KeyCode::Backspace, KeyModifiers::ALT),
        key(KeyCode::Char('d'), KeyModifiers::CONTROL),
        key(KeyCode::Char('w'), KeyModifiers::CONTROL),
        key(KeyCode::Char('d'), KeyModifiers::ALT),
        key(KeyCode::Char('k'), KeyModifiers::CONTROL),
        key(KeyCode::Char('u'), KeyModifiers::CONTROL),
        key(KeyCode::Char('c'), KeyModifiers::CONTROL),
    ];
    for key in no_op_keys {
        let mut input = text_input("");
        assert_eq!(input.handle_key(&key), InputEvent::None, "{key:?}");
    }

    let mut input = text_input("x");
    input.cursor = 1;
    assert_eq!(input.handle_key(&key(KeyCode::Backspace, KeyModifiers::NONE)), InputEvent::Changed);
    assert!(input.buffer.is_empty());

    let mut input = text_input("x");
    input.cursor = 0;
    assert_eq!(input.handle_key(&key(KeyCode::Delete, KeyModifiers::NONE)), InputEvent::Changed);
    assert!(input.buffer.is_empty());
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
fn movement_and_backspace_treat_extended_graphemes_as_one_character() {
    let family = "👨‍👩‍👧‍👦";
    let mut input = text_input(&format!("á{family}"));

    input.handle_key(&key(KeyCode::Left, KeyModifiers::NONE));
    assert_eq!(&input.as_str()[..input.cursor], "á");
    input.handle_key(&key(KeyCode::Backspace, KeyModifiers::NONE));

    assert_eq!(input.as_str(), family);
    assert_eq!(input.cursor, 0);
}

#[test]
fn visible_cursor_uses_terminal_cell_width() {
    let input = text_input("界a");

    let (shown, cursor) = input.visible_text_and_cursor(4);

    assert_eq!(shown, "界a");
    assert_eq!(cursor, 3);
}

#[test]
fn visible_text_keeps_cursor_visible() {
    let mut input = text_input("abcdef");
    let (shown, cursor) = input.visible_text_and_cursor(3);
    assert_eq!(shown, "ef");
    assert_eq!(cursor, 2);
    input.handle_key(&key(KeyCode::Char('a'), KeyModifiers::CONTROL));
    let (shown, cursor) = input.visible_text_and_cursor(3);
    assert_eq!(shown, "abc");
    assert_eq!(cursor, 0);
}

#[test]
fn viewport_scan_keeps_wide_graphemes_in_order() {
    let input = text_input("界界界界");

    let (shown, cursor) = input.visible_text_and_cursor(4);

    assert_eq!(shown, "界");
    assert_eq!(cursor, 2);
}

#[test]
fn visible_cursor_counts_halfwidth_sound_marks_as_terminal_cells() {
    let input = text_input("ｶﾞa");

    let (shown, cursor) = input.visible_text_and_cursor(4);

    assert_eq!(shown, "ｶﾞa");
    assert_eq!(cursor, 3);
}
