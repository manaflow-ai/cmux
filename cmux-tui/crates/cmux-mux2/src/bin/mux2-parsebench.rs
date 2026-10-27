//! `mux2-parsebench FILE [CHUNK]`: parse cost of the same bytes through the
//! ghostty-vt wrapper and through the raw libghostty-vt call, in CHUNK-sized
//! writes (default 16384). One JSON line.

#![cfg_attr(not(test), deny(clippy::disallowed_methods))]

use std::time::Instant;

use ghostty_vt::sys;
use ghostty_vt::{Callbacks, Terminal};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let data =
        std::fs::read(args.first().expect("usage: mux2-parsebench FILE [CHUNK]")).expect("read");
    let chunk: usize = args.get(1).and_then(|c| c.parse().ok()).unwrap_or(16384);
    let mut bytes = Vec::with_capacity(data.len() + data.len() / 16);
    for &b in &data {
        if b == b'\n' {
            bytes.push(b'\r');
        }
        bytes.push(b);
    }
    let (cols, rows, scrollback) = (200u16, 50u16, 10_000_000usize);

    let mut wrapped =
        Terminal::new(cols, rows, scrollback, Callbacks::default()).expect("terminal");
    let t = Instant::now();
    for c in bytes.chunks(chunk) {
        wrapped.vt_write(c);
    }
    let wrapper_s = t.elapsed().as_secs_f64();

    let mut raw: sys::GhosttyTerminal = std::ptr::null_mut();
    // SAFETY: creating and configuring a terminal through the C API; the
    // pointer stays valid until ghostty_terminal_free below.
    unsafe {
        assert_eq!(sys::ghostty_terminal_new(std::ptr::null(), &mut raw, cols, rows), 0);
        sys::ghostty_terminal_set(
            raw,
            sys::GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
            (&raw const scrollback).cast(),
        );
    }
    let t = Instant::now();
    for c in bytes.chunks(chunk) {
        // SAFETY: raw is a live terminal and c a valid slice.
        unsafe { sys::ghostty_terminal_vt_write(raw, c.as_ptr(), c.len()) };
    }
    let raw_s = t.elapsed().as_secs_f64();
    // SAFETY: freeing the terminal created above.
    unsafe { sys::ghostty_terminal_free(raw) };

    let mb = bytes.len() as f64 / 1e6;
    println!(
        "{{\"parsebench\":\"{}\",\"chunk\":{chunk},\"mb\":{mb:.1},\"wrapper_mb_s\":{:.1},\"raw_mb_s\":{:.1},\"wrapper_overhead\":{:.2}}}",
        args[0],
        mb / wrapper_s,
        mb / raw_s,
        wrapper_s / raw_s
    );
}
