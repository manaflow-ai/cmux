//! The key path of Ctrl-C (dogfood chrome-parity-v1: "ctrl c is broken").
//! The app sends Ctrl-C to Ghostty as the physical C key with Control and no
//! text (`TerminalSurfaceView.sendKey` leaves the control character out), and
//! the daemon's `send-key ctrl+c` builds the same input: both must reach the
//! PTY as the one byte 0x03 (ETX), which the line discipline turns into
//! SIGINT. A program that asked for the Kitty keyboard protocol gets the
//! CSI-u form instead and handles the key itself, as Ghostty sends it.

use ghostty_vt::{Callbacks, KeyEncoder, Terminal, key_input_from_chord};

fn encode(term: &Terminal, chord: &str) -> Vec<u8> {
    let mut encoder = KeyEncoder::new().unwrap();
    encoder.sync_from_terminal(term);
    let input = key_input_from_chord(chord).expect(chord);
    let mut out = Vec::new();
    encoder.encode(&input, &mut out).unwrap();
    out
}

#[test]
fn ctrl_c_encodes_as_etx_for_a_shell() {
    let term = Terminal::new(80, 24, 1000, Callbacks::default()).unwrap();
    assert_eq!(encode(&term, "ctrl+c"), b"\x03");
    assert_eq!(encode(&term, "control+c"), b"\x03");
}

#[test]
fn ctrl_c_is_csi_u_only_for_a_kitty_keyboard_program() {
    let mut term = Terminal::new(80, 24, 1000, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b[>1u");
    assert_eq!(encode(&term, "ctrl+c"), b"\x1b[99;5u");
    term.vt_write(b"\x1b[<u");
    assert_eq!(encode(&term, "ctrl+c"), b"\x03");
}
