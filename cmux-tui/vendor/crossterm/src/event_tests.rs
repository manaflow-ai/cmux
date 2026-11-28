use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use super::*;
use KeyCode::*;
use MediaKeyCode::*;
use ModifierKeyCode::*;

#[test]
fn test_equality() {
    let lowercase_d_with_shift = KeyEvent::new(KeyCode::Char('d'), KeyModifiers::SHIFT);
    let uppercase_d_with_shift = KeyEvent::new(KeyCode::Char('D'), KeyModifiers::SHIFT);
    let uppercase_d = KeyEvent::new(KeyCode::Char('D'), KeyModifiers::NONE);
    assert_eq!(lowercase_d_with_shift, uppercase_d_with_shift);
    assert_eq!(uppercase_d, uppercase_d_with_shift);
}

#[test]
fn test_hash() {
    let lowercase_d_with_shift_hash = {
        let mut hasher = DefaultHasher::new();
        KeyEvent::new(KeyCode::Char('d'), KeyModifiers::SHIFT).hash(&mut hasher);
        hasher.finish()
    };
    let uppercase_d_with_shift_hash = {
        let mut hasher = DefaultHasher::new();
        KeyEvent::new(KeyCode::Char('D'), KeyModifiers::SHIFT).hash(&mut hasher);
        hasher.finish()
    };
    let uppercase_d_hash = {
        let mut hasher = DefaultHasher::new();
        KeyEvent::new(KeyCode::Char('D'), KeyModifiers::NONE).hash(&mut hasher);
        hasher.finish()
    };
    assert_eq!(lowercase_d_with_shift_hash, uppercase_d_with_shift_hash);
    assert_eq!(uppercase_d_hash, uppercase_d_with_shift_hash);
}

#[test]
fn keycode_display() {
    #[cfg(target_os = "macos")]
    {
        assert_eq!(format!("{}", Backspace), "Delete");
        assert_eq!(format!("{}", Delete), "Fwd Del");
        assert_eq!(format!("{}", Enter), "Return");
    }
    #[cfg(not(target_os = "macos"))]
    {
        assert_eq!(format!("{}", Backspace), "Backspace");
        assert_eq!(format!("{}", Delete), "Del");
        assert_eq!(format!("{}", Enter), "Enter");
    }
    assert_eq!(format!("{}", Left), "Left");
    assert_eq!(format!("{}", Right), "Right");
    assert_eq!(format!("{}", Up), "Up");
    assert_eq!(format!("{}", Down), "Down");
    assert_eq!(format!("{}", Home), "Home");
    assert_eq!(format!("{}", End), "End");
    assert_eq!(format!("{}", PageUp), "Page Up");
    assert_eq!(format!("{}", PageDown), "Page Down");
    assert_eq!(format!("{}", Tab), "Tab");
    assert_eq!(format!("{}", BackTab), "Back Tab");
    assert_eq!(format!("{}", Insert), "Insert");
    assert_eq!(format!("{}", F(1)), "F1");
    assert_eq!(format!("{}", Char('a')), "a");
    assert_eq!(format!("{}", Null), "Null");
    assert_eq!(format!("{}", Esc), "Esc");
    assert_eq!(format!("{}", CapsLock), "Caps Lock");
    assert_eq!(format!("{}", ScrollLock), "Scroll Lock");
    assert_eq!(format!("{}", NumLock), "Num Lock");
    assert_eq!(format!("{}", PrintScreen), "Print Screen");
    assert_eq!(format!("{}", KeyCode::Pause), "Pause");
    assert_eq!(format!("{}", Menu), "Menu");
    assert_eq!(format!("{}", KeypadBegin), "Begin");
}

#[test]
fn media_keycode_display() {
    assert_eq!(format!("{}", Media(Play)), "Play");
    assert_eq!(format!("{}", Media(MediaKeyCode::Pause)), "Pause");
    assert_eq!(format!("{}", Media(PlayPause)), "Play/Pause");
    assert_eq!(format!("{}", Media(Reverse)), "Reverse");
    assert_eq!(format!("{}", Media(Stop)), "Stop");
    assert_eq!(format!("{}", Media(FastForward)), "Fast Forward");
    assert_eq!(format!("{}", Media(Rewind)), "Rewind");
    assert_eq!(format!("{}", Media(TrackNext)), "Next Track");
    assert_eq!(format!("{}", Media(TrackPrevious)), "Previous Track");
    assert_eq!(format!("{}", Media(Record)), "Record");
    assert_eq!(format!("{}", Media(LowerVolume)), "Lower Volume");
    assert_eq!(format!("{}", Media(RaiseVolume)), "Raise Volume");
    assert_eq!(format!("{}", Media(MuteVolume)), "Mute Volume");
}

#[test]
fn modifier_keycode_display() {
    assert_eq!(format!("{}", Modifier(LeftShift)), "Left Shift");
    assert_eq!(format!("{}", Modifier(LeftHyper)), "Left Hyper");
    assert_eq!(format!("{}", Modifier(LeftMeta)), "Left Meta");
    assert_eq!(format!("{}", Modifier(RightShift)), "Right Shift");
    assert_eq!(format!("{}", Modifier(RightHyper)), "Right Hyper");
    assert_eq!(format!("{}", Modifier(RightMeta)), "Right Meta");
    assert_eq!(format!("{}", Modifier(IsoLevel3Shift)), "Iso Level 3 Shift");
    assert_eq!(format!("{}", Modifier(IsoLevel5Shift)), "Iso Level 5 Shift");
}

#[cfg(target_os = "macos")]
#[test]
fn modifier_keycode_display_macos() {
    assert_eq!(format!("{}", Modifier(LeftControl)), "Left Control");
    assert_eq!(format!("{}", Modifier(LeftAlt)), "Left Option");
    assert_eq!(format!("{}", Modifier(LeftSuper)), "Left Command");
    assert_eq!(format!("{}", Modifier(RightControl)), "Right Control");
    assert_eq!(format!("{}", Modifier(RightAlt)), "Right Option");
    assert_eq!(format!("{}", Modifier(RightSuper)), "Right Command");
}

#[cfg(target_os = "windows")]
#[test]
fn modifier_keycode_display_windows() {
    assert_eq!(format!("{}", Modifier(LeftControl)), "Left Ctrl");
    assert_eq!(format!("{}", Modifier(LeftAlt)), "Left Alt");
    assert_eq!(format!("{}", Modifier(LeftSuper)), "Left Windows");
    assert_eq!(format!("{}", Modifier(RightControl)), "Right Ctrl");
    assert_eq!(format!("{}", Modifier(RightAlt)), "Right Alt");
    assert_eq!(format!("{}", Modifier(RightSuper)), "Right Windows");
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
#[test]
fn modifier_keycode_display_other() {
    assert_eq!(format!("{}", Modifier(LeftControl)), "Left Ctrl");
    assert_eq!(format!("{}", Modifier(LeftAlt)), "Left Alt");
    assert_eq!(format!("{}", Modifier(LeftSuper)), "Left Super");
    assert_eq!(format!("{}", Modifier(RightControl)), "Right Ctrl");
    assert_eq!(format!("{}", Modifier(RightAlt)), "Right Alt");
    assert_eq!(format!("{}", Modifier(RightSuper)), "Right Super");
}

#[test]
fn key_modifiers_display() {
    let modifiers = KeyModifiers::SHIFT | KeyModifiers::CONTROL | KeyModifiers::ALT;

    #[cfg(target_os = "macos")]
    assert_eq!(modifiers.to_string(), "Shift+Control+Option");

    #[cfg(target_os = "windows")]
    assert_eq!(modifiers.to_string(), "Shift+Ctrl+Alt");

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    assert_eq!(modifiers.to_string(), "Shift+Control+Alt");
}

const ESC_PRESSED: KeyEvent =
    KeyEvent::new_with_kind(KeyCode::Esc, KeyModifiers::empty(), KeyEventKind::Press);
const ESC_RELEASED: KeyEvent =
    KeyEvent::new_with_kind(KeyCode::Esc, KeyModifiers::empty(), KeyEventKind::Release);
const ESC_REPEAT: KeyEvent =
    KeyEvent::new_with_kind(KeyCode::Esc, KeyModifiers::empty(), KeyEventKind::Repeat);
const MOUSE_CLICK: MouseEvent = MouseEvent {
    kind: MouseEventKind::Down(MouseButton::Left),
    column: 1,
    row: 1,
    modifiers: KeyModifiers::empty(),
};

#[cfg(feature = "derive-more")]
#[test]
fn event_is() {
    let event = Event::FocusGained;
    assert!(event.is_focus_gained());
    assert!(event.is_focus_gained());
    assert!(!event.is_key());

    let event = Event::FocusLost;
    assert!(event.is_focus_lost());
    assert!(!event.is_focus_gained());
    assert!(!event.is_key());

    let event = Event::Resize(1, 1);
    assert!(event.is_resize());
    assert!(!event.is_key());

    let event = Event::Key(ESC_PRESSED);
    assert!(event.is_key());
    assert!(event.is_key_press());
    assert!(!event.is_key_release());
    assert!(!event.is_key_repeat());
    assert!(!event.is_focus_gained());

    let event = Event::Key(ESC_RELEASED);
    assert!(event.is_key());
    assert!(!event.is_key_press());
    assert!(event.is_key_release());
    assert!(!event.is_key_repeat());
    assert!(!event.is_focus_gained());

    let event = Event::Key(ESC_REPEAT);
    assert!(event.is_key());
    assert!(!event.is_key_press());
    assert!(!event.is_key_release());
    assert!(event.is_key_repeat());
    assert!(!event.is_focus_gained());

    let event = Event::Mouse(MOUSE_CLICK);
    assert!(event.is_mouse());
    assert!(!event.is_key());

    #[cfg(feature = "bracketed-paste")]
    {
        let event = Event::Paste("".to_string());
        assert!(event.is_paste());
        assert!(!event.is_key());
    }
}

#[test]
fn event_as() {
    let event = Event::FocusGained;
    assert_eq!(event.as_key_event(), None);

    let event = Event::Key(ESC_PRESSED);
    assert_eq!(event.as_key_event(), Some(ESC_PRESSED));
    assert_eq!(event.as_key_press_event(), Some(ESC_PRESSED));
    assert_eq!(event.as_key_release_event(), None);
    assert_eq!(event.as_key_repeat_event(), None);
    assert_eq!(event.as_resize_event(), None);

    let event = Event::Key(ESC_RELEASED);
    assert_eq!(event.as_key_event(), Some(ESC_RELEASED));
    assert_eq!(event.as_key_release_event(), Some(ESC_RELEASED));
    assert_eq!(event.as_key_press_event(), None);
    assert_eq!(event.as_key_repeat_event(), None);
    assert_eq!(event.as_resize_event(), None);

    let event = Event::Key(ESC_REPEAT);
    assert_eq!(event.as_key_event(), Some(ESC_REPEAT));
    assert_eq!(event.as_key_repeat_event(), Some(ESC_REPEAT));
    assert_eq!(event.as_key_press_event(), None);
    assert_eq!(event.as_key_release_event(), None);
    assert_eq!(event.as_resize_event(), None);

    let event = Event::Resize(1, 1);
    assert_eq!(event.as_resize_event(), Some((1, 1)));
    assert_eq!(event.as_key_event(), None);

    let event = Event::Mouse(MOUSE_CLICK);
    assert_eq!(event.as_mouse_event(), Some(MOUSE_CLICK));
    assert_eq!(event.as_key_event(), None);

    #[cfg(feature = "bracketed-paste")]
    {
        let event = Event::Paste("".to_string());
        assert_eq!(event.as_paste_event(), Some(""));
        assert_eq!(event.as_key_event(), None);
    }
}
