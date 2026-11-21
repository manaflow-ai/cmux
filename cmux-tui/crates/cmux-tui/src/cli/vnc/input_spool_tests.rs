use super::*;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

#[test]
fn large_pastes_and_thousands_of_events_replay_in_order() {
    let mut spool = InputSpool::default();
    let text = "λ🙂\r\n\"".repeat(1_048_577);
    assert!(text.len() > 9 * 1024 * 1024);
    spool.push(&DeferredInput::Event(Event::Paste(text.clone()))).unwrap();
    spool.push(&DeferredInput::ToggleViewOnly).unwrap();
    for index in 0..4097 {
        spool.push(&DeferredInput::Event(Event::Resize(index, index + 1))).unwrap();
    }
    let key =
        DeferredInput::Event(Event::Key(KeyEvent::new(KeyCode::Char('z'), KeyModifiers::CONTROL)));
    spool.push(&key).unwrap();
    assert!(!spool.is_empty());
    assert!(spool.write_at > text.len() as u64);
    assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::Paste(text))));
    assert_eq!(spool.pop().unwrap(), Some(DeferredInput::ToggleViewOnly));
    for index in 0..4097 {
        assert_eq!(
            spool.pop().unwrap(),
            Some(DeferredInput::Event(Event::Resize(index, index + 1)))
        );
    }
    assert_eq!(spool.pop().unwrap(), Some(key));
    assert!(spool.is_empty());
    assert!(spool.file.is_none(), "drain releases the temporary file");
    assert_eq!(spool.pop().unwrap(), None);
}

#[test]
fn append_after_partial_replay_and_cancel_release_the_fifo() {
    let mut spool = InputSpool::default();
    spool.push(&DeferredInput::Event(Event::FocusLost)).unwrap();
    spool.push(&DeferredInput::Event(Event::FocusGained)).unwrap();
    assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::FocusLost)));
    spool.push(&DeferredInput::Event(Event::Resize(80, 24))).unwrap();
    assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::FocusGained)));
    assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::Resize(80, 24))));
    spool.push(&DeferredInput::Event(Event::Paste("cancelled".into()))).unwrap();
    spool.clear();
    assert!(spool.file.is_none());
    assert_eq!(spool.pop().unwrap(), None);
    spool.push(&DeferredInput::Event(Event::FocusGained)).unwrap();
    assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::FocusGained)));
}
