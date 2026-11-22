// Temporary probe (not for merge): which step of cloud_replay crashes.
use ghostty_vt::{Callbacks, RenderState, Terminal};
use std::io::Write;
fn step(s: &str) {
    eprintln!("PROBE {s}");
    std::io::stderr().flush().unwrap();
}
#[test]
fn probe() {
    step("new");
    let mut t = Terminal::new(80, 40, 1024 * 1024, Callbacks::default()).unwrap();
    step("write plain");
    t.vt_write(b"hello\r\n");
    step("render new");
    let mut state = RenderState::new().unwrap();
    step("render update");
    state.update(&mut t).unwrap();
    step("render build_frame");
    let _ = state.build_frame().unwrap();
    step("write styled");
    t.vt_write("\x1b[48;2;243;243;243m\x1b[33;1H\x1b[38;2;130;130;130m› Ask\x1b[0m╭──╮".as_bytes());
    step("render styled");
    state.update(&mut t).unwrap();
    let _ = state.build_frame().unwrap();
    step("vt_replay_bounded_theme_portable");
    let replay = t.vt_replay_bounded_theme_portable(128 * 1024).unwrap();
    step(&format!("replay {} bytes", replay.len()));
    let mut r = Terminal::new(80, 40, 1024 * 1024, Callbacks::default()).unwrap();
    r.vt_write(&replay);
    step("restored render");
    let mut s2 = RenderState::new().unwrap();
    s2.update(&mut r).unwrap();
    let _ = s2.build_frame().unwrap();
    step("done");
}
