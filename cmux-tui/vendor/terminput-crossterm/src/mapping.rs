#[cfg(all(feature = "crossterm_0_28", not(feature = "crossterm_0_29")))]
use crossterm_0_28 as crossterm;
#[cfg(feature = "crossterm_0_29")]
use crossterm_0_29 as crossterm;
use terminput::{
    Event, KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers, MediaKeyCode,
    ModifierDirection, ModifierKeyCode, MouseButton, MouseEvent, MouseEventKind, ScrollDirection,
    UnsupportedEvent,
};

/// Converts the crossterm [`Event`](crossterm::event::Event) to a terminput [`Event`].
pub fn to_terminput(value: crossterm::event::Event) -> Result<Event, UnsupportedEvent> {
    Ok(match value {
        crossterm::event::Event::FocusGained => Event::FocusGained,
        crossterm::event::Event::FocusLost => Event::FocusLost,
        crossterm::event::Event::Key(key_event) => Event::Key(to_terminput_key(key_event)?),
        crossterm::event::Event::EnhancedKey(key_event) => {
            Event::Key(to_terminput_key(key_event.key_event)?)
        }
        crossterm::event::Event::Mouse(mouse_event) => {
            Event::Mouse(to_terminput_mouse(mouse_event))
        }
        crossterm::event::Event::Paste(value) => Event::Paste(value),
        crossterm::event::Event::Resize(cols, rows) => Event::Resize {
            cols: cols as u32,
            rows: rows as u32,
        },
    })
}

/// Converts the terminput [`Event`] to a crossterm [`Event`](crossterm::event::Event).
pub fn to_crossterm(value: Event) -> Result<crossterm::event::Event, UnsupportedEvent> {
    Ok(match value {
        Event::FocusGained => crossterm::event::Event::FocusGained,
        Event::FocusLost => crossterm::event::Event::FocusLost,
        Event::Key(key_event) => crossterm::event::Event::Key(to_crossterm_key(key_event)),
        Event::Mouse(mouse_event) => {
            crossterm::event::Event::Mouse(to_crossterm_mouse(mouse_event)?)
        }
        Event::Paste(value) => crossterm::event::Event::Paste(value),
        Event::Resize { cols, rows } => crossterm::event::Event::Resize(
            cols.try_into()
                .map_err(|e| UnsupportedEvent(format!("{e:?}")))?,
            rows.try_into()
                .map_err(|e| UnsupportedEvent(format!("{e:?}")))?,
        ),
    })
}

/// Converts the crossterm [`MouseEvent`](crossterm::event::MouseEvent) to a terminput
/// [`MouseEvent`].
pub fn to_terminput_mouse(value: crossterm::event::MouseEvent) -> MouseEvent {
    MouseEvent {
        kind: to_terminput_mouse_kind(value.kind),
        column: value.column,
        row: value.row,
        modifiers: to_terminput_key_modifiers(value.modifiers),
    }
}

/// Converts the terminput [`MouseEvent`] to a crossterm
/// [`MouseEvent`](crossterm::event::MouseEvent).
pub fn to_crossterm_mouse(
    value: MouseEvent,
) -> Result<crossterm::event::MouseEvent, UnsupportedEvent> {
    Ok(crossterm::event::MouseEvent {
        kind: to_crossterm_mouse_kind(value.kind)?,
        column: value.column,
        row: value.row,
        modifiers: to_crossterm_key_modifiers(value.modifiers),
    })
}

fn to_terminput_mouse_kind(value: crossterm::event::MouseEventKind) -> MouseEventKind {
    match value {
        crossterm::event::MouseEventKind::Down(button) => {
            MouseEventKind::Down(to_terminput_mouse_button(button))
        }
        crossterm::event::MouseEventKind::Up(button) => {
            MouseEventKind::Up(to_terminput_mouse_button(button))
        }
        crossterm::event::MouseEventKind::Drag(button) => {
            MouseEventKind::Drag(to_terminput_mouse_button(button))
        }
        crossterm::event::MouseEventKind::Moved => MouseEventKind::Moved,
        crossterm::event::MouseEventKind::ScrollDown => {
            MouseEventKind::Scroll(ScrollDirection::Down)
        }
        crossterm::event::MouseEventKind::ScrollUp => MouseEventKind::Scroll(ScrollDirection::Up),
        crossterm::event::MouseEventKind::ScrollLeft => {
            MouseEventKind::Scroll(ScrollDirection::Left)
        }
        crossterm::event::MouseEventKind::ScrollRight => {
            MouseEventKind::Scroll(ScrollDirection::Right)
        }
    }
}

fn to_crossterm_mouse_kind(
    value: MouseEventKind,
) -> Result<crossterm::event::MouseEventKind, UnsupportedEvent> {
    Ok(match value {
        MouseEventKind::Down(button) => {
            crossterm::event::MouseEventKind::Down(to_crossterm_mouse_button(button)?)
        }
        MouseEventKind::Up(button) => {
            crossterm::event::MouseEventKind::Up(to_crossterm_mouse_button(button)?)
        }
        MouseEventKind::Drag(button) => {
            crossterm::event::MouseEventKind::Drag(to_crossterm_mouse_button(button)?)
        }
        MouseEventKind::Moved => crossterm::event::MouseEventKind::Moved,
        MouseEventKind::Scroll(ScrollDirection::Down) => {
            crossterm::event::MouseEventKind::ScrollDown
        }
        MouseEventKind::Scroll(ScrollDirection::Up) => crossterm::event::MouseEventKind::ScrollUp,
        MouseEventKind::Scroll(ScrollDirection::Left) => {
            crossterm::event::MouseEventKind::ScrollLeft
        }
        MouseEventKind::Scroll(ScrollDirection::Right) => {
            crossterm::event::MouseEventKind::ScrollRight
        }
    })
}

fn to_terminput_mouse_button(value: crossterm::event::MouseButton) -> MouseButton {
    match value {
        crossterm::event::MouseButton::Left => MouseButton::Left,
        crossterm::event::MouseButton::Right => MouseButton::Right,
        crossterm::event::MouseButton::Middle => MouseButton::Middle,
    }
}

fn to_crossterm_mouse_button(
    value: MouseButton,
) -> Result<crossterm::event::MouseButton, UnsupportedEvent> {
    Ok(match value {
        MouseButton::Left => crossterm::event::MouseButton::Left,
        MouseButton::Right => crossterm::event::MouseButton::Right,
        MouseButton::Middle => crossterm::event::MouseButton::Middle,
        val @ MouseButton::Unknown => Err(UnsupportedEvent(format!("{val:?}")))?,
    })
}

/// Converts the crossterm [`KeyEvent`](crossterm::event::KeyEvent) to a terminput [`KeyEvent`].
pub fn to_terminput_key(value: crossterm::event::KeyEvent) -> Result<KeyEvent, UnsupportedEvent> {
    Ok(KeyEvent {
        code: to_terminput_key_code(value.code)?,
        modifiers: to_terminput_key_modifiers(value.modifiers),
        kind: to_terminput_key_kind(value.kind),
        state: to_terminput_key_state(value.state),
    })
}

/// Converts the terminput [`KeyEvent`] to a crossterm [`KeyEvent`](crossterm::event::KeyEvent).
pub fn to_crossterm_key(value: KeyEvent) -> crossterm::event::KeyEvent {
    crossterm::event::KeyEvent {
        code: to_crossterm_key_code(value.code, value.modifiers.intersects(KeyModifiers::SHIFT)),
        modifiers: to_crossterm_key_modifiers(value.modifiers),
        kind: to_crossterm_key_kind(value.kind),
        state: to_crossterm_key_state(value.state),
    }
}

fn to_terminput_key_code(value: crossterm::event::KeyCode) -> Result<KeyCode, UnsupportedEvent> {
    Ok(match value {
        crossterm::event::KeyCode::Backspace => KeyCode::Backspace,
        crossterm::event::KeyCode::Enter => KeyCode::Enter,
        crossterm::event::KeyCode::Left => KeyCode::Left,
        crossterm::event::KeyCode::Right => KeyCode::Right,
        crossterm::event::KeyCode::Up => KeyCode::Up,
        crossterm::event::KeyCode::Down => KeyCode::Down,
        crossterm::event::KeyCode::Home => KeyCode::Home,
        crossterm::event::KeyCode::End => KeyCode::End,
        crossterm::event::KeyCode::PageUp => KeyCode::PageUp,
        crossterm::event::KeyCode::PageDown => KeyCode::PageDown,
        crossterm::event::KeyCode::Tab => KeyCode::Tab,
        crossterm::event::KeyCode::BackTab => KeyCode::Tab,
        crossterm::event::KeyCode::Delete => KeyCode::Delete,
        crossterm::event::KeyCode::Insert => KeyCode::Insert,
        crossterm::event::KeyCode::F(f) => KeyCode::F(f),
        crossterm::event::KeyCode::Char(c) => KeyCode::Char(c),
        crossterm::event::KeyCode::Esc => KeyCode::Esc,
        crossterm::event::KeyCode::CapsLock => KeyCode::CapsLock,
        crossterm::event::KeyCode::ScrollLock => KeyCode::ScrollLock,
        crossterm::event::KeyCode::NumLock => KeyCode::NumLock,
        crossterm::event::KeyCode::PrintScreen => KeyCode::PrintScreen,
        crossterm::event::KeyCode::Pause => KeyCode::Pause,
        crossterm::event::KeyCode::Menu => KeyCode::Menu,
        crossterm::event::KeyCode::KeypadBegin => KeyCode::KeypadBegin,
        crossterm::event::KeyCode::Media(m) => KeyCode::Media(to_terminput_media_code(m)),
        crossterm::event::KeyCode::Modifier(m) => {
            let (code, direction) = to_terminput_modifier_key_code(m);
            KeyCode::Modifier(code, direction)
        }
        crossterm::event::KeyCode::Null => Err(UnsupportedEvent(format!("{value:?}")))?,
    })
}

fn to_crossterm_key_code(value: KeyCode, shift: bool) -> crossterm::event::KeyCode {
    match value {
        KeyCode::Backspace => crossterm::event::KeyCode::Backspace,
        KeyCode::Enter => crossterm::event::KeyCode::Enter,
        KeyCode::Left => crossterm::event::KeyCode::Left,
        KeyCode::Right => crossterm::event::KeyCode::Right,
        KeyCode::Up => crossterm::event::KeyCode::Up,
        KeyCode::Down => crossterm::event::KeyCode::Down,
        KeyCode::Home => crossterm::event::KeyCode::Home,
        KeyCode::End => crossterm::event::KeyCode::End,
        KeyCode::PageUp => crossterm::event::KeyCode::PageUp,
        KeyCode::PageDown => crossterm::event::KeyCode::PageDown,
        KeyCode::Tab if shift => crossterm::event::KeyCode::BackTab,
        KeyCode::Tab => crossterm::event::KeyCode::Tab,
        KeyCode::Delete => crossterm::event::KeyCode::Delete,
        KeyCode::Insert => crossterm::event::KeyCode::Insert,
        KeyCode::F(f) => crossterm::event::KeyCode::F(f),
        KeyCode::Char(c) => crossterm::event::KeyCode::Char(c),
        KeyCode::Esc => crossterm::event::KeyCode::Esc,
        KeyCode::CapsLock => crossterm::event::KeyCode::CapsLock,
        KeyCode::ScrollLock => crossterm::event::KeyCode::ScrollLock,
        KeyCode::NumLock => crossterm::event::KeyCode::NumLock,
        KeyCode::PrintScreen => crossterm::event::KeyCode::PrintScreen,
        KeyCode::Pause => crossterm::event::KeyCode::Pause,
        KeyCode::Menu => crossterm::event::KeyCode::Menu,
        KeyCode::KeypadBegin => crossterm::event::KeyCode::KeypadBegin,
        KeyCode::Media(m) => crossterm::event::KeyCode::Media(to_crossterm_media_code(m)),
        KeyCode::Modifier(code, direction) => {
            crossterm::event::KeyCode::Modifier(to_crossterm_modifier_key_code(code, direction))
        }
    }
}

fn to_terminput_key_modifiers(value: crossterm::event::KeyModifiers) -> KeyModifiers {
    let mut res = KeyModifiers::empty();
    if value.intersects(crossterm::event::KeyModifiers::ALT) {
        res |= KeyModifiers::ALT;
    }
    if value.intersects(crossterm::event::KeyModifiers::SHIFT) {
        res |= KeyModifiers::SHIFT;
    }
    if value.intersects(crossterm::event::KeyModifiers::CONTROL) {
        res |= KeyModifiers::CTRL;
    }
    if value.intersects(crossterm::event::KeyModifiers::SUPER) {
        res |= KeyModifiers::SUPER;
    }

    res
}

fn to_crossterm_key_modifiers(value: KeyModifiers) -> crossterm::event::KeyModifiers {
    let mut res = crossterm::event::KeyModifiers::empty();
    if value.intersects(KeyModifiers::ALT) {
        res |= crossterm::event::KeyModifiers::ALT;
    }
    if value.intersects(KeyModifiers::SHIFT) {
        res |= crossterm::event::KeyModifiers::SHIFT;
    }
    if value.intersects(KeyModifiers::CTRL) {
        res |= crossterm::event::KeyModifiers::CONTROL;
    }
    if value.intersects(KeyModifiers::SUPER) {
        res |= crossterm::event::KeyModifiers::SUPER;
    }

    res
}

fn to_terminput_key_kind(value: crossterm::event::KeyEventKind) -> KeyEventKind {
    match value {
        crossterm::event::KeyEventKind::Press => KeyEventKind::Press,
        crossterm::event::KeyEventKind::Repeat => KeyEventKind::Repeat,
        crossterm::event::KeyEventKind::Release => KeyEventKind::Release,
    }
}

fn to_crossterm_key_kind(value: KeyEventKind) -> crossterm::event::KeyEventKind {
    match value {
        KeyEventKind::Press => crossterm::event::KeyEventKind::Press,
        KeyEventKind::Repeat => crossterm::event::KeyEventKind::Repeat,
        KeyEventKind::Release => crossterm::event::KeyEventKind::Release,
    }
}

fn to_terminput_media_code(value: crossterm::event::MediaKeyCode) -> MediaKeyCode {
    match value {
        crossterm::event::MediaKeyCode::Play => MediaKeyCode::Play,
        crossterm::event::MediaKeyCode::Pause => MediaKeyCode::Pause,
        crossterm::event::MediaKeyCode::PlayPause => MediaKeyCode::PlayPause,
        crossterm::event::MediaKeyCode::Reverse => MediaKeyCode::Reverse,
        crossterm::event::MediaKeyCode::Stop => MediaKeyCode::Stop,
        crossterm::event::MediaKeyCode::FastForward => MediaKeyCode::FastForward,
        crossterm::event::MediaKeyCode::Rewind => MediaKeyCode::Rewind,
        crossterm::event::MediaKeyCode::TrackNext => MediaKeyCode::TrackNext,
        crossterm::event::MediaKeyCode::TrackPrevious => MediaKeyCode::TrackPrevious,
        crossterm::event::MediaKeyCode::Record => MediaKeyCode::Record,
        crossterm::event::MediaKeyCode::LowerVolume => MediaKeyCode::LowerVolume,
        crossterm::event::MediaKeyCode::RaiseVolume => MediaKeyCode::RaiseVolume,
        crossterm::event::MediaKeyCode::MuteVolume => MediaKeyCode::MuteVolume,
    }
}

fn to_crossterm_media_code(value: MediaKeyCode) -> crossterm::event::MediaKeyCode {
    match value {
        MediaKeyCode::Play => crossterm::event::MediaKeyCode::Play,
        MediaKeyCode::Pause => crossterm::event::MediaKeyCode::Pause,
        MediaKeyCode::PlayPause => crossterm::event::MediaKeyCode::PlayPause,
        MediaKeyCode::Reverse => crossterm::event::MediaKeyCode::Reverse,
        MediaKeyCode::Stop => crossterm::event::MediaKeyCode::Stop,
        MediaKeyCode::FastForward => crossterm::event::MediaKeyCode::FastForward,
        MediaKeyCode::Rewind => crossterm::event::MediaKeyCode::Rewind,
        MediaKeyCode::TrackNext => crossterm::event::MediaKeyCode::TrackNext,
        MediaKeyCode::TrackPrevious => crossterm::event::MediaKeyCode::TrackPrevious,
        MediaKeyCode::Record => crossterm::event::MediaKeyCode::Record,
        MediaKeyCode::LowerVolume => crossterm::event::MediaKeyCode::LowerVolume,
        MediaKeyCode::RaiseVolume => crossterm::event::MediaKeyCode::RaiseVolume,
        MediaKeyCode::MuteVolume => crossterm::event::MediaKeyCode::MuteVolume,
    }
}

fn to_terminput_modifier_key_code(
    value: crossterm::event::ModifierKeyCode,
) -> (ModifierKeyCode, ModifierDirection) {
    match value {
        crossterm::event::ModifierKeyCode::LeftShift => {
            (ModifierKeyCode::Shift, ModifierDirection::Left)
        }
        crossterm::event::ModifierKeyCode::LeftControl => {
            (ModifierKeyCode::Control, ModifierDirection::Left)
        }
        crossterm::event::ModifierKeyCode::LeftAlt => {
            (ModifierKeyCode::Alt, ModifierDirection::Left)
        }
        crossterm::event::ModifierKeyCode::LeftSuper => {
            (ModifierKeyCode::Super, ModifierDirection::Left)
        }
        crossterm::event::ModifierKeyCode::LeftHyper => {
            (ModifierKeyCode::Hyper, ModifierDirection::Left)
        }
        crossterm::event::ModifierKeyCode::LeftMeta => {
            (ModifierKeyCode::Meta, ModifierDirection::Left)
        }
        crossterm::event::ModifierKeyCode::RightShift => {
            (ModifierKeyCode::Shift, ModifierDirection::Right)
        }
        crossterm::event::ModifierKeyCode::RightControl => {
            (ModifierKeyCode::Control, ModifierDirection::Right)
        }
        crossterm::event::ModifierKeyCode::RightAlt => {
            (ModifierKeyCode::Alt, ModifierDirection::Right)
        }
        crossterm::event::ModifierKeyCode::RightSuper => {
            (ModifierKeyCode::Super, ModifierDirection::Right)
        }
        crossterm::event::ModifierKeyCode::RightHyper => {
            (ModifierKeyCode::Hyper, ModifierDirection::Right)
        }
        crossterm::event::ModifierKeyCode::RightMeta => {
            (ModifierKeyCode::Meta, ModifierDirection::Right)
        }
        crossterm::event::ModifierKeyCode::IsoLevel3Shift => {
            (ModifierKeyCode::IsoLevel3Shift, ModifierDirection::Unknown)
        }
        crossterm::event::ModifierKeyCode::IsoLevel5Shift => {
            (ModifierKeyCode::IsoLevel5Shift, ModifierDirection::Unknown)
        }
    }
}

fn to_crossterm_modifier_key_code(
    code: ModifierKeyCode,
    direction: ModifierDirection,
) -> crossterm::event::ModifierKeyCode {
    match (code, direction) {
        (ModifierKeyCode::Shift, ModifierDirection::Left | ModifierDirection::Unknown) => {
            crossterm::event::ModifierKeyCode::LeftShift
        }
        (ModifierKeyCode::Control, ModifierDirection::Left | ModifierDirection::Unknown) => {
            crossterm::event::ModifierKeyCode::LeftControl
        }
        (ModifierKeyCode::Alt, ModifierDirection::Left | ModifierDirection::Unknown) => {
            crossterm::event::ModifierKeyCode::LeftAlt
        }
        (ModifierKeyCode::Super, ModifierDirection::Left | ModifierDirection::Unknown) => {
            crossterm::event::ModifierKeyCode::LeftSuper
        }
        (ModifierKeyCode::Hyper, ModifierDirection::Left | ModifierDirection::Unknown) => {
            crossterm::event::ModifierKeyCode::LeftHyper
        }
        (ModifierKeyCode::Meta, ModifierDirection::Left | ModifierDirection::Unknown) => {
            crossterm::event::ModifierKeyCode::LeftMeta
        }
        (ModifierKeyCode::Shift, ModifierDirection::Right) => {
            crossterm::event::ModifierKeyCode::RightShift
        }
        (ModifierKeyCode::Control, ModifierDirection::Right) => {
            crossterm::event::ModifierKeyCode::RightControl
        }
        (ModifierKeyCode::Alt, ModifierDirection::Right) => {
            crossterm::event::ModifierKeyCode::RightAlt
        }
        (ModifierKeyCode::Super, ModifierDirection::Right) => {
            crossterm::event::ModifierKeyCode::RightSuper
        }
        (ModifierKeyCode::Hyper, ModifierDirection::Right) => {
            crossterm::event::ModifierKeyCode::RightHyper
        }
        (ModifierKeyCode::Meta, ModifierDirection::Right) => {
            crossterm::event::ModifierKeyCode::RightMeta
        }
        (ModifierKeyCode::IsoLevel3Shift, _) => crossterm::event::ModifierKeyCode::IsoLevel3Shift,
        (ModifierKeyCode::IsoLevel5Shift, _) => crossterm::event::ModifierKeyCode::IsoLevel5Shift,
    }
}

fn to_terminput_key_state(value: crossterm::event::KeyEventState) -> KeyEventState {
    let mut state = KeyEventState::empty();
    if value.intersects(crossterm::event::KeyEventState::KEYPAD) {
        state |= KeyEventState::KEYPAD;
    }
    if value.intersects(crossterm::event::KeyEventState::CAPS_LOCK) {
        state |= KeyEventState::CAPS_LOCK;
    }
    if value.intersects(crossterm::event::KeyEventState::NUM_LOCK) {
        state |= KeyEventState::NUM_LOCK;
    }
    state
}

fn to_crossterm_key_state(value: KeyEventState) -> crossterm::event::KeyEventState {
    let mut state = crossterm::event::KeyEventState::empty();
    if value.intersects(KeyEventState::KEYPAD) {
        state |= crossterm::event::KeyEventState::KEYPAD;
    }
    if value.intersects(KeyEventState::CAPS_LOCK) {
        state |= crossterm::event::KeyEventState::CAPS_LOCK;
    }
    if value.intersects(KeyEventState::NUM_LOCK) {
        state |= crossterm::event::KeyEventState::NUM_LOCK;
    }
    state
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enhanced_key_converts_through_its_embedded_key_event() {
        let key_event = crossterm::event::KeyEvent::new(
            crossterm::event::KeyCode::Char('a'),
            crossterm::event::KeyModifiers::SHIFT,
        );
        let enhanced = crossterm::event::EnhancedKeyEvent {
            key_event,
            shifted_key: Some('A'),
            base_layout_key: Some('a'),
            text: "A".to_owned(),
        };

        let converted = to_terminput(crossterm::event::Event::EnhancedKey(enhanced));

        assert!(matches!(
            converted,
            Ok(Event::Key(KeyEvent {
                code: KeyCode::Char('a'),
                modifiers,
                ..
            })) if modifiers == KeyModifiers::SHIFT
        ));
    }
}
