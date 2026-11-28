use crate::event::{KeyEventState, KeyModifiers, MouseButton, MouseEvent};

use super::*;

#[test]
fn test_esc_key() {
    assert_eq!(
        parse_event(b"\x1B", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyCode::Esc.into()))),
    );
}

#[test]
fn test_possible_esc_sequence() {
    assert_eq!(parse_event(b"\x1B", true).unwrap(), None,);
}

#[test]
fn test_keyboard_enhancement_query_parses_all_decimal_flag_bits() {
    let flags = KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ALTERNATE_KEYS
        | KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ASSOCIATED_TEXT;

    assert_eq!(
        parse_event(b"\x1B[?29u", false).unwrap(),
        Some(InternalEvent::KeyboardEnhancementFlags(flags)),
    );
}

#[test]
fn test_alt_key() {
    assert_eq!(
        parse_event(b"\x1Bc", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::ALT
        )))),
    );
}

#[test]
fn test_alt_shift() {
    assert_eq!(
        parse_event(b"\x1BH", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('H'),
            KeyModifiers::ALT | KeyModifiers::SHIFT
        )))),
    );
}

#[test]
fn test_alt_ctrl() {
    assert_eq!(
        parse_event(b"\x1B\x14", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('t'),
            KeyModifiers::ALT | KeyModifiers::CONTROL
        )))),
    );
}

#[test]
fn test_parse_event_subsequent_calls() {
    // The main purpose of this test is to check if we're passing
    // correct slice to other parse_ functions.

    // parse_csi_cursor_position
    assert_eq!(
        parse_event(b"\x1B[20;10R", false).unwrap(),
        Some(InternalEvent::CursorPosition(9, 19))
    );

    // parse_csi
    assert_eq!(
        parse_event(b"\x1B[D", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyCode::Left.into()))),
    );

    // parse_csi_modifier_key_code
    assert_eq!(
        parse_event(b"\x1B[2D", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT))))
    );

    // parse_csi_special_key_code
    assert_eq!(
        parse_event(b"\x1B[3~", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyCode::Delete.into()))),
    );

    // parse_csi_bracketed_paste
    #[cfg(feature = "bracketed-paste")]
    assert_eq!(
        parse_event(b"\x1B[200~on and on and on\x1B[201~", false).unwrap(),
        Some(InternalEvent::Event(Event::Paste("on and on and on".to_string()))),
    );

    // parse_csi_rxvt_mouse
    assert_eq!(
        parse_event(b"\x1B[32;30;40;M", false).unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 29,
            row: 39,
            modifiers: KeyModifiers::empty(),
        })))
    );

    // parse_csi_normal_mouse
    assert_eq!(
        parse_event(b"\x1B[M0\x60\x70", false).unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 63,
            row: 79,
            modifiers: KeyModifiers::CONTROL,
        })))
    );

    // parse_csi_sgr_mouse
    assert_eq!(
        parse_event(b"\x1B[<0;20;10;M", false).unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 19,
            row: 9,
            modifiers: KeyModifiers::empty(),
        })))
    );

    // parse_utf8_char
    assert_eq!(
        parse_event("Ž".as_bytes(), false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('Ž'),
            KeyModifiers::SHIFT
        )))),
    );
}

#[test]
fn test_parse_event() {
    assert_eq!(
        parse_event(b"\t", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyCode::Tab.into()))),
    );
}

#[test]
fn test_parse_csi_cursor_position() {
    assert_eq!(
        parse_csi_cursor_position(b"\x1B[20;10R").unwrap(),
        Some(InternalEvent::CursorPosition(9, 19))
    );
}

#[test]
fn test_parse_csi() {
    assert_eq!(
        parse_csi(b"\x1B[D").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyCode::Left.into()))),
    );
}

#[test]
fn test_parse_csi_modifier_key_code() {
    assert_eq!(
        parse_csi_modifier_key_code(b"\x1B[2D").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(KeyCode::Left, KeyModifiers::SHIFT)))),
    );
}

#[test]
fn test_parse_csi_special_key_code() {
    assert_eq!(
        parse_csi_special_key_code(b"\x1B[3~").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyCode::Delete.into()))),
    );
}

#[test]
fn test_parse_csi_special_key_code_multiple_values_not_supported() {
    assert_eq!(
        parse_csi_special_key_code(b"\x1B[3;2~").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(KeyCode::Delete, KeyModifiers::SHIFT)))),
    );
}

#[test]
fn test_parse_csi_u_preserves_layout_and_associated_text() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[38:49:49;4;49u").unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('&'), KeyModifiers::SHIFT | KeyModifiers::ALT,),
            shifted_key: Some('1'),
            base_layout_key: Some('1'),
            text: "1".to_string(),
        }))),
    );
}

#[test]
fn test_parse_csi_u_accepts_empty_modifiers_before_associated_text() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;;97u").unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('a'), KeyModifiers::NONE),
            shifted_key: None,
            base_layout_key: None,
            text: "a".to_string(),
        }))),
    );
}

#[test]
fn test_parse_csi_u_preserves_empty_alt_character_provenance() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[110;3u").unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('n'), KeyModifiers::ALT),
            shifted_key: None,
            base_layout_key: None,
            text: String::new(),
        }))),
    );
}

#[cfg(feature = "bracketed-paste")]
#[test]
fn test_parse_csi_bracketed_paste() {
    //
    assert_eq!(
        parse_event(b"\x1B[200~o", false).unwrap(),
        None,
        "A partial bracketed paste isn't parsed"
    );
    assert_eq!(
        parse_event(b"\x1B[200~o\x1B[2D", false).unwrap(),
        None,
        "A partial bracketed paste containing another escape code isn't parsed"
    );
    assert_eq!(
        parse_event(b"\x1B[200~o\x1B[2D\x1B[201~", false).unwrap(),
        Some(InternalEvent::Event(Event::Paste("o\x1B[2D".to_string())))
    );
}

#[test]
fn test_parse_csi_focus() {
    assert_eq!(parse_csi(b"\x1B[O").unwrap(), Some(InternalEvent::Event(Event::FocusLost)));
}

#[test]
fn test_parse_csi_rxvt_mouse() {
    assert_eq!(
        parse_csi_rxvt_mouse(b"\x1B[32;30;40;M").unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 29,
            row: 39,
            modifiers: KeyModifiers::empty(),
        })))
    );
}

#[test]
fn test_parse_csi_normal_mouse() {
    assert_eq!(
        parse_csi_normal_mouse(b"\x1B[M0\x60\x70").unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 63,
            row: 79,
            modifiers: KeyModifiers::CONTROL,
        })))
    );
}

#[test]
fn test_parse_csi_sgr_mouse() {
    assert_eq!(
        parse_csi_sgr_mouse(b"\x1B[<0;20;10;M").unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 19,
            row: 9,
            modifiers: KeyModifiers::empty(),
        })))
    );
    assert_eq!(
        parse_csi_sgr_mouse(b"\x1B[<0;20;10M").unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 19,
            row: 9,
            modifiers: KeyModifiers::empty(),
        })))
    );
    assert_eq!(
        parse_csi_sgr_mouse(b"\x1B[<0;20;10;m").unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 19,
            row: 9,
            modifiers: KeyModifiers::empty(),
        })))
    );
    assert_eq!(
        parse_csi_sgr_mouse(b"\x1B[<0;20;10m").unwrap(),
        Some(InternalEvent::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 19,
            row: 9,
            modifiers: KeyModifiers::empty(),
        })))
    );
}

/// Positions are 1-based; a 0 from the host terminal is malformed input,
/// refused like any other, never an arithmetic underflow (found by the
/// cmux-tui/fuzz `tui_keys` target).
#[test]
fn zero_coordinates_are_refused_not_underflowed() {
    for buffer in [
        &b"\x1B[<0;10;0m"[..],
        b"\x1B[<0;0;10M",
        b"\x1B[32;0;5M",
        b"\x1B[32;10;0M",
        b"\x1B[0;5R",
        b"\x1B[5;0R",
    ] {
        assert!(parse_event(buffer, false).is_err(), "{buffer:?} was not refused");
    }
    assert!(parse_csi_normal_mouse(b"\x1B[M  !").is_err());
    assert!(parse_csi_normal_mouse(b"\x1B[M !\x1f").is_err());
}

#[test]
fn test_utf8() {
    // https://www.php.net/manual/en/reference.pcre.pattern.modifiers.php#54805

    // 'Valid ASCII' => "a",
    assert_eq!(parse_utf8_char(b"a").unwrap(), Some('a'),);

    // 'Valid 2 Octet Sequence' => "\xc3\xb1",
    assert_eq!(parse_utf8_char(&[0xC3, 0xB1]).unwrap(), Some('ñ'),);

    // 'Invalid 2 Octet Sequence' => "\xc3\x28",
    assert!(parse_utf8_char(&[0xC3, 0x28]).is_err());

    // 'Invalid Sequence Identifier' => "\xa0\xa1",
    assert!(parse_utf8_char(&[0xA0, 0xA1]).is_err());

    // 'Valid 3 Octet Sequence' => "\xe2\x82\xa1",
    assert_eq!(parse_utf8_char(&[0xE2, 0x81, 0xA1]).unwrap(), Some('\u{2061}'),);

    // 'Invalid 3 Octet Sequence (in 2nd Octet)' => "\xe2\x28\xa1",
    assert!(parse_utf8_char(&[0xE2, 0x28, 0xA1]).is_err());

    // 'Invalid 3 Octet Sequence (in 3rd Octet)' => "\xe2\x82\x28",
    assert!(parse_utf8_char(&[0xE2, 0x82, 0x28]).is_err());

    // 'Valid 4 Octet Sequence' => "\xf0\x90\x8c\xbc",
    assert_eq!(parse_utf8_char(&[0xF0, 0x90, 0x8C, 0xBC]).unwrap(), Some('𐌼'),);

    // 'Invalid 4 Octet Sequence (in 2nd Octet)' => "\xf0\x28\x8c\xbc",
    assert!(parse_utf8_char(&[0xF0, 0x28, 0x8C, 0xBC]).is_err());

    // 'Invalid 4 Octet Sequence (in 3rd Octet)' => "\xf0\x90\x28\xbc",
    assert!(parse_utf8_char(&[0xF0, 0x90, 0x28, 0xBC]).is_err());

    // 'Invalid 4 Octet Sequence (in 4th Octet)' => "\xf0\x28\x8c\x28",
    assert!(parse_utf8_char(&[0xF0, 0x28, 0x8C, 0x28]).is_err());
}

#[test]
fn test_parse_char_event_lowercase() {
    assert_eq!(
        parse_event(b"c", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::empty()
        )))),
    );
}

#[test]
fn test_parse_char_event_uppercase() {
    assert_eq!(
        parse_event(b"C", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('C'),
            KeyModifiers::SHIFT
        )))),
    );
}

#[test]
fn test_parse_basic_csi_u_encoded_key_code() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::empty()
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;2u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('A'),
            KeyModifiers::SHIFT
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;7u").unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('a'), KeyModifiers::ALT | KeyModifiers::CONTROL,),
            shifted_key: None,
            base_layout_key: None,
            text: String::new(),
        }))),
    );
}

#[test]
fn test_parse_basic_csi_u_preserves_shifted_character_value() {
    let Some(InternalEvent::Event(Event::Key(event))) =
        parse_csi_u_encoded_key_code(b"\x1B[97;2u").unwrap()
    else {
        panic!("expected a basic CSI-u key event");
    };

    assert_eq!(event.code, KeyCode::Char('A'));
    assert_eq!(event.modifiers, KeyModifiers::SHIFT);
}

#[test]
fn test_parse_basic_csi_u_encoded_key_code_special_keys() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[13u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Enter,
            KeyModifiers::empty()
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[27u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(KeyCode::Esc, KeyModifiers::empty())))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57358u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::CapsLock,
            KeyModifiers::empty()
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57376u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::F(13),
            KeyModifiers::empty()
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57428u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Media(MediaKeyCode::Play),
            KeyModifiers::empty()
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57441u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Modifier(ModifierKeyCode::LeftShift),
            KeyModifiers::SHIFT,
        )))),
    );
}

#[test]
fn test_parse_csi_u_encoded_keypad_code() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57399u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind_and_state(
            KeyCode::Char('0'),
            KeyModifiers::empty(),
            KeyEventKind::Press,
            KeyEventState::KEYPAD,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57419u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind_and_state(
            KeyCode::Up,
            KeyModifiers::empty(),
            KeyEventKind::Press,
            KeyEventState::KEYPAD,
        )))),
    );
}

#[test]
fn test_parse_csi_u_encoded_key_code_with_types() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;1u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Char('a'),
            KeyModifiers::empty(),
            KeyEventKind::Press,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;1:1u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Char('a'),
            KeyModifiers::empty(),
            KeyEventKind::Press,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;5:1u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Char('a'),
            KeyModifiers::CONTROL,
            KeyEventKind::Press,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;1:2u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Char('a'),
            KeyModifiers::empty(),
            KeyEventKind::Repeat,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;1:3u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Char('a'),
            KeyModifiers::empty(),
            KeyEventKind::Release,
        )))),
    );
}

#[test]
fn test_parse_csi_u_encoded_key_code_has_modifier_on_modifier_press() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57449u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Modifier(ModifierKeyCode::RightAlt),
            KeyModifiers::ALT,
            KeyEventKind::Press,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57449;3:3u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Modifier(ModifierKeyCode::RightAlt),
            KeyModifiers::ALT,
            KeyEventKind::Release,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57450u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Modifier(ModifierKeyCode::RightSuper),
            KeyModifiers::SUPER,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57451u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Modifier(ModifierKeyCode::RightHyper),
            KeyModifiers::HYPER,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[57452u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Modifier(ModifierKeyCode::RightMeta),
            KeyModifiers::META,
        )))),
    );
}

#[test]
fn test_parse_csi_u_encoded_key_code_with_extra_modifiers() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;9u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::SUPER
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;17u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::HYPER,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;33u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::META,
        )))),
    );
}

#[test]
fn test_parse_csi_u_encoded_key_code_with_extra_state() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;65u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind_and_state(
            KeyCode::Char('a'),
            KeyModifiers::empty(),
            KeyEventKind::Press,
            KeyEventState::CAPS_LOCK,
        )))),
    );
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[49;129u").unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind_and_state(
            KeyCode::Char('1'),
            KeyModifiers::empty(),
            KeyEventKind::Press,
            KeyEventState::NUM_LOCK,
        )))),
    );
}

#[test]
fn test_parse_csi_u_encoded_key_code_with_all_modifiers_and_lock_state() {
    assert_eq!(
        parse_csi_u_encoded_key_code(b"\x1B[97;256u").unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new_with_kind_and_state(
                KeyCode::Char('a'),
                KeyModifiers::SHIFT
                    | KeyModifiers::ALT
                    | KeyModifiers::CONTROL
                    | KeyModifiers::SUPER
                    | KeyModifiers::HYPER
                    | KeyModifiers::META,
                KeyEventKind::Press,
                KeyEventState::CAPS_LOCK | KeyEventState::NUM_LOCK,
            ),
            shifted_key: None,
            base_layout_key: None,
            text: String::new(),
        }))),
    );
    assert!(parse_csi_u_encoded_key_code(b"\x1B[97;0u").is_err());
    assert!(parse_csi_u_encoded_key_code(b"\x1B[97;257u").is_err());
}

#[test]
fn test_parse_csi_u_preserves_shifted_keycode() {
    assert_eq!(
        parse_event(b"\x1B[57:40;4u", false).unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('9'), KeyModifiers::ALT | KeyModifiers::SHIFT,),
            shifted_key: Some('('),
            base_layout_key: None,
            text: String::new(),
        }))),
    );
    assert_eq!(
        parse_event(b"\x1B[45:95;4u", false).unwrap(),
        Some(InternalEvent::Event(Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('-'), KeyModifiers::ALT | KeyModifiers::SHIFT,),
            shifted_key: Some('_'),
            base_layout_key: None,
            text: String::new(),
        }))),
    );
}

#[test]
fn test_parse_csi_special_key_code_with_types() {
    assert_eq!(
        parse_event(b"\x1B[;1:3B", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Down,
            KeyModifiers::empty(),
            KeyEventKind::Release,
        )))),
    );
    assert_eq!(
        parse_event(b"\x1B[1;1:3B", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::Down,
            KeyModifiers::empty(),
            KeyEventKind::Release,
        )))),
    );
}

#[test]
fn test_parse_csi_numbered_escape_code_with_types() {
    assert_eq!(
        parse_event(b"\x1B[5;1:3~", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::PageUp,
            KeyModifiers::empty(),
            KeyEventKind::Release,
        )))),
    );
    assert_eq!(
        parse_event(b"\x1B[6;5:3~", false).unwrap(),
        Some(InternalEvent::Event(Event::Key(KeyEvent::new_with_kind(
            KeyCode::PageDown,
            KeyModifiers::CONTROL,
            KeyEventKind::Release,
        )))),
    );
}
