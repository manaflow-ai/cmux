//! The `unsafe impl Send` of each libghostty wrapper under test: the value is
//! made and used on one thread, then used and dropped on another, as the
//! daemon does when a `Mutex` hands a terminal or its encoders to the next
//! worker. Each SAFETY comment names its test here.

use std::thread;

use ghostty_vt::{
    Callbacks, KeyEncoder, Mods, MouseAction, MouseButton, MouseEncoder, MouseInput, RenderState,
    Terminal, key_input_from_chord,
};

fn on_another_thread<T: Send + 'static, R: Send + 'static>(
    value: T,
    work: impl FnOnce(T) -> R + Send + 'static,
) -> R {
    thread::spawn(move || work(value)).join().expect("worker thread")
}

fn terminal() -> Terminal {
    let mut terminal = Terminal::new(20, 4, 1 << 16, Callbacks::default()).expect("terminal");
    terminal.vt_write(b"first line\r\n");
    terminal
}

#[test]
fn a_terminal_moves_between_threads() {
    let terminal = terminal();
    let mut terminal = on_another_thread(terminal, |mut terminal| {
        terminal.vt_write(b"second line\r\n");
        terminal
    });
    terminal.vt_write(b"third line");
    let text = terminal.viewport_text().expect("viewport text");
    assert!(text.contains("first line") && text.contains("third line"), "{text:?}");
    on_another_thread(terminal, drop);
}

#[test]
fn a_render_state_moves_between_threads() {
    let mut terminal = terminal();
    let mut state = RenderState::new().expect("render state");
    state.update(&mut terminal).expect("update");
    let (state, size) = on_another_thread(state, |state| {
        let size = state.size();
        (state, size)
    });
    assert_eq!(size, (20, 4));
    let mut state = state;
    terminal.vt_write(b"more");
    state.update(&mut terminal).expect("update after the move");
    on_another_thread(state, drop);
}

#[test]
fn a_key_encoder_moves_between_threads() {
    let terminal = terminal();
    let mut encoder = KeyEncoder::new().expect("key encoder");
    encoder.sync_from_terminal(&terminal);
    let input = key_input_from_chord("ctrl+c").expect("chord");
    let (encoder, bytes) = on_another_thread(encoder, move |mut encoder| {
        let mut bytes = Vec::new();
        encoder.encode(&input, &mut bytes).expect("encode");
        (encoder, bytes)
    });
    assert_eq!(bytes, [0x03]);
    on_another_thread(encoder, drop);
}

#[test]
fn a_mouse_encoder_moves_between_threads() {
    let mut terminal = terminal();
    terminal.vt_write(b"\x1b[?1000h\x1b[?1006h");
    let mut encoder = MouseEncoder::new().expect("mouse encoder");
    encoder.sync_from_terminal(&terminal);
    let press = MouseInput {
        action: MouseAction::Press,
        button: Some(MouseButton::Left),
        mods: Mods::default(),
        position: (5.0, 5.0),
        screen_size: (200, 80),
        cell_size: (10, 20),
        any_button_pressed: false,
    };
    let (encoder, bytes) = on_another_thread(encoder, move |mut encoder| {
        let mut bytes = Vec::new();
        encoder.encode(press, &mut bytes).expect("encode");
        (encoder, bytes)
    });
    assert!(bytes.starts_with(b"\x1b[<0;"), "an SGR press: {bytes:?}");
    on_another_thread(encoder, drop);
}
