//! The launch contract between `--serve` and the app that starts it
//! (remote-tab-r2.md, local host): the app runs
//! `cmux-remote-browser-host --serve --listen 127.0.0.1:0 --lifeline`, reads
//! one [`listening_line`] from stdout to learn the port the OS gave, and
//! keeps the write end of the host's stdin open. When the app closes it (the
//! tab closed, the app quit or crashed), [`watch_lifeline`] sees end of file
//! and the host quits. No polling and no process scanning: the pipe is the
//! signal.

use std::io::Read;
use std::net::SocketAddr;

/// The stdout key of the readiness line.
pub const LISTENING_KEY: &str = "listening";

/// The one stdout line `--serve` writes once it accepts viewers: a JSON
/// object, for example `{"listening":"127.0.0.1:52144"}`, with the bound
/// address (the real port when the request was port 0).
pub fn listening_line(bound: SocketAddr) -> String {
    serde_json::json!({ LISTENING_KEY: bound.to_string() }).to_string()
}

/// Reads `input` until end of file or a read error, then calls `on_eof`
/// once. Bytes written to the lifeline are ignored.
pub fn watch_lifeline<R: Read>(mut input: R, on_eof: impl FnOnce()) {
    let mut buf = [0u8; 256];
    loop {
        match input.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
    on_eof();
}
