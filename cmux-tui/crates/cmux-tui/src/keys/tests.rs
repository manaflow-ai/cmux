use super::*;
use ghostty_vt::{Callbacks, KeyEncoder, Terminal};

#[test]
fn ctrl_d_encodes_the_posix_eof_byte() {
    let event = KeyEvent::new(KeyCode::Char('d'), KeyModifiers::CONTROL);
    let input = key_input_from(&event).unwrap();
    let terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();

    encoder.encode(&input, &mut encoded).unwrap();

    assert_eq!(encoded, b"\x04");
}

#[test]
fn ctrl_shift_letter_keeps_shift_in_kitty_forwarding() {
    let event = KeyEvent::new(KeyCode::Char('c'), KeyModifiers::CONTROL | KeyModifiers::SHIFT);
    let input = key_input_from(&event).unwrap();
    assert!(input.mods.contains(Mods::CTRL));
    assert!(input.mods.contains(Mods::SHIFT));

    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[>1u");
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();
    encoder.encode(&input, &mut encoded).unwrap();

    assert_eq!(encoded, b"\x1b[99;6u");
}

#[test]
fn enhanced_ctrl_shift_keeps_reported_layout_identity_in_kitty_forwarding() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(
            KeyCode::Char('\u{447}'),
            KeyModifiers::CONTROL | KeyModifiers::SHIFT,
        ),
        shifted_key: Some('\u{427}'),
        base_layout_key: Some(';'),
        text: String::new(),
    };
    let input = key_input_from_enhanced(&event).unwrap();
    assert_eq!(input.shifted_codepoint, '\u{427}' as u32);
    assert_eq!(input.base_layout_codepoint, ';' as u32);
    assert!(input.utf8.is_empty());
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[>29u");
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();

    encoder.encode(&input, &mut encoded).unwrap();

    assert_eq!(encoded, b"\x1b[1095:1063:59;6u");
}

#[test]
fn enhanced_non_ascii_shortcut_keeps_shift_identity() {
    let input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('é'), KeyModifiers::SHIFT),
        shifted_key: Some('É'),
        base_layout_key: Some('e'),
        text: "É".to_string(),
    });

    let (logical, physical) = input.shortcut_keys();
    assert_eq!(logical, KeyEvent::new(KeyCode::Char('é'), KeyModifiers::SHIFT));
    assert_eq!(physical, Some(KeyEvent::new(KeyCode::Char('e'), KeyModifiers::SHIFT)));
}

#[test]
fn legacy_alt_shift_events_preserve_reported_text() {
    let encode = |shifted| {
        let event = KeyEvent::new(KeyCode::Char(shifted), KeyModifiers::ALT | KeyModifiers::SHIFT);
        let input = key_input_from(&event).unwrap();
        let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        terminal.vt_write(b"\x1b[?1036h");
        let mut encoder = KeyEncoder::new().unwrap();
        encoder.sync_from_terminal(&terminal);
        let mut encoded = Vec::new();
        encoder.encode(&input, &mut encoded).unwrap();
        encoded
    };

    for (base, shifted) in [('d', 'D'), ('1', '!')] {
        assert_eq!(
            encode(shifted),
            [b"\x1b".as_slice(), shifted.to_string().as_bytes()].concat(),
            "legacy Alt-Shift-{base} lost its reported text"
        );
    }
}

#[test]
fn enhanced_key_uses_reported_layout_text_and_physical_identity() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('&'), KeyModifiers::ALT | KeyModifiers::SHIFT),
        shifted_key: Some('1'),
        base_layout_key: Some('1'),
        text: "1".to_string(),
    };
    let input = key_input_from_enhanced(&event).unwrap();

    assert_eq!(input.key, sys::GHOSTTY_KEY_DIGIT_1);
    assert_eq!(input.unshifted_codepoint, '&' as u32);
    assert_eq!(input.utf8, "1");
    assert!(input.mods.contains(Mods::ALT | Mods::SHIFT));
    assert!(input.consumed_mods.contains(Mods::SHIFT));
    assert!(!input.consumed_mods.contains(Mods::ALT));
}

#[test]
fn nested_kitty_forwarding_preserves_duplicate_base_layout_identity() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('&'), KeyModifiers::ALT | KeyModifiers::SHIFT),
        shifted_key: Some('1'),
        base_layout_key: Some('1'),
        text: "1".to_string(),
    };
    let input = key_input_from_enhanced(&event).unwrap();
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[>29u");
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();

    encoder.encode(&input, &mut encoded).unwrap();

    assert_eq!(encoded, b"\x1b[38:49:49;4u");
}

#[test]
fn shifted_punctuation_does_not_invent_a_us_layout_identity() {
    let event = KeyEvent::new(KeyCode::Char('&'), KeyModifiers::ALT | KeyModifiers::SHIFT);
    let input = key_input_from(&event).unwrap();

    assert_eq!(input.key, sys::GHOSTTY_KEY_UNIDENTIFIED);
    assert_eq!(input.unshifted_codepoint, '&' as u32);
    assert_eq!(input.utf8, "&");
}

#[test]
fn enhanced_function_key_preserves_associated_text() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE),
        shifted_key: None,
        base_layout_key: None,
        text: "\u{6f22}".to_string(),
    };

    let input = key_input_from_enhanced(&event).unwrap();

    assert_eq!(input.key, sys::GHOSTTY_KEY_ENTER);
    assert_eq!(input.utf8, "\u{6f22}");
}

#[test]
fn unsupported_kitty_modifiers_fail_closed_for_terminal_input() {
    for modifier in [KeyModifiers::HYPER, KeyModifiers::META] {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('x'), modifier),
            shifted_key: None,
            base_layout_key: Some('x'),
            text: "x".to_string(),
        };

        assert!(
            key_input_from_enhanced(&event).is_none(),
            "{modifier:?} must not be downgraded to an unmodified key"
        );
    }
}

#[test]
fn enhanced_text_reuses_the_parser_owned_buffer() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('w'),
        text: "\u{2211}".to_string(),
    };
    let text_ptr = event.text.as_ptr();

    let input = KeyboardInput::from_enhanced(event).into_terminal_input().unwrap();

    assert_eq!(input.utf8, "\u{2211}");
    assert_eq!(input.utf8.as_ptr(), text_ptr);
    assert!(input.mods.contains(Mods::ALT));
    assert!(input.consumed_mods.contains(Mods::ALT));
}

#[test]
fn option_generated_text_consumes_alt_from_event_metadata() {
    let input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('w'),
        text: "\u{2211}".to_string(),
    });

    assert!(input.suppresses_alt_shortcut());
}

#[test]
fn caps_lock_keeps_alt_active_when_text_matches_shift_xor_caps() {
    for (modifiers, text) in
        [(KeyModifiers::ALT, "T"), (KeyModifiers::ALT | KeyModifiers::SHIFT, "t")]
    {
        let input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
            key_event: KeyEvent::new_with_kind_and_state(
                KeyCode::Char('t'),
                modifiers,
                KeyEventKind::Press,
                KeyEventState::CAPS_LOCK,
            ),
            shifted_key: Some('T'),
            base_layout_key: Some('t'),
            text: text.to_string(),
        });

        assert!(!input.suppresses_alt_shortcut(), "{modifiers:?} treated Alt as text-producing");
        assert!(input.shortcut_keys().0.modifiers.contains(KeyModifiers::ALT));
    }
}

#[test]
fn caps_lock_still_marks_option_generated_text_as_consuming_alt() {
    let input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new_with_kind_and_state(
            KeyCode::Char('t'),
            KeyModifiers::ALT,
            KeyEventKind::Press,
            KeyEventState::CAPS_LOCK,
        ),
        shifted_key: Some('T'),
        base_layout_key: Some('t'),
        text: "\u{2020}".to_string(),
    });

    assert!(input.suppresses_alt_shortcut());
}

#[test]
fn enhanced_non_character_alt_shortcut_without_text_remains_active() {
    let input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Left, KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: None,
        text: String::new(),
    });

    assert!(!input.suppresses_alt_shortcut());
    assert!(input.shortcut_keys().0.modifiers.contains(KeyModifiers::ALT));
}

#[test]
fn enhanced_character_alt_without_text_preserves_a_real_alt_chord() {
    let input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('j'),
        text: String::new(),
    });

    assert!(!input.suppresses_alt_shortcut());
    assert!(input.shortcut_keys().0.modifiers.contains(KeyModifiers::ALT));
    let input = input.into_terminal_input().unwrap();
    assert!(!input.composing);

    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[>29u");
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();
    encoder.encode(&input, &mut encoded).unwrap();

    assert_eq!(encoded, b"\x1b[106;3u");
}

#[test]
fn enhanced_dead_key_preserves_authoritative_empty_text() {
    let mut input = KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('e'), KeyModifiers::ALT),
        shifted_key: Some('E'),
        base_layout_key: Some('e'),
        text: String::new(),
    });
    input.resolve_macos_option_as_alt(false);
    assert!(input.suppresses_alt_shortcut());
    let input = input.into_terminal_input().unwrap();

    assert!(input.utf8.is_empty());
    assert!(input.composing);
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[?1036h");
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();
    encoder.encode(&input, &mut encoded).unwrap();
    assert!(encoded.is_empty());
}

#[test]
fn option_generated_text_keeps_associated_text_in_kitty_mode() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('w'),
        text: "\u{2211}".to_string(),
    };
    let input = KeyboardInput::from_enhanced(event).into_terminal_input().unwrap();
    let mut terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    terminal.vt_write(b"\x1b[>29u");
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();

    encoder.encode(&input, &mut encoded).unwrap();

    assert_eq!(encoded, b"\x1b[119;3;8721u");
}

#[test]
fn enhanced_keypad_identity_and_lock_state_reach_the_ghostty_encoder() {
    let state = KeyEventState::KEYPAD | KeyEventState::CAPS_LOCK | KeyEventState::NUM_LOCK;
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new_with_kind_and_state(
            KeyCode::Char('1'),
            KeyModifiers::NONE,
            KeyEventKind::Press,
            state,
        ),
        shifted_key: None,
        base_layout_key: None,
        text: String::new(),
    };

    let input = key_input_from_enhanced(&event).unwrap();

    assert_eq!(input.key, sys::GHOSTTY_KEY_NUMPAD_1);
    assert_ne!(input.mods.0 & sys::GHOSTTY_MODS_CAPS_LOCK as u16, 0);
    assert_ne!(input.mods.0 & sys::GHOSTTY_MODS_NUM_LOCK as u16, 0);
}

#[test]
fn enhanced_keypad_navigation_keeps_its_physical_identity() {
    let state = KeyEventState::KEYPAD;
    for (code, expected) in [
        (KeyCode::Enter, sys::GHOSTTY_KEY_NUMPAD_ENTER),
        (KeyCode::Up, sys::GHOSTTY_KEY_NUMPAD_UP),
        (KeyCode::PageDown, sys::GHOSTTY_KEY_NUMPAD_PAGE_DOWN),
        (KeyCode::KeypadBegin, sys::GHOSTTY_KEY_NUMPAD_BEGIN),
    ] {
        let event = EnhancedKeyEvent {
            key_event: KeyEvent::new_with_kind_and_state(
                code,
                KeyModifiers::NONE,
                KeyEventKind::Press,
                state,
            ),
            shifted_key: None,
            base_layout_key: None,
            text: String::new(),
        };

        assert_eq!(key_input_from_enhanced(&event).unwrap().key, expected);
    }
}

#[test]
fn shifted_option_generated_text_is_forwarded_as_text() {
    let event = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('2'), KeyModifiers::ALT | KeyModifiers::SHIFT),
        shifted_key: Some('@'),
        base_layout_key: Some('2'),
        text: "\u{20ac}".to_string(),
    };
    let input = KeyboardInput::from_enhanced(event).into_terminal_input().unwrap();
    let terminal = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(&terminal);
    let mut encoded = Vec::new();

    encoder.encode(&input, &mut encoded).unwrap();

    assert!(input.consumed_mods.contains(Mods::ALT));
    assert_eq!(encoded, "\u{20ac}".as_bytes());
}
