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
