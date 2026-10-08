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

/// Reads the per-launch secret: the first line the app writes to the
/// lifeline (stdin), never the command line or the environment. `None` when
/// stdin ends first or the line is empty.
pub fn read_secret<R: std::io::BufRead>(input: &mut R) -> Option<String> {
    let mut line = String::new();
    input.read_line(&mut line).ok()?;
    let secret = line.trim_end_matches(['\n', '\r']);
    (!secret.is_empty()).then(|| secret.to_string())
}

/// Whether a viewer may join: with a secret, its rd `hello` must carry it as
/// the per-launch session token. Checked before the welcome, so a refused
/// viewer never opens the tab or sends input.
pub fn authorize(
    secret: Option<&str>,
    hello: &cmux_rd_proto::control::Control,
) -> Result<(), &'static str> {
    let Some(secret) = secret else { return Ok(()) };
    let cmux_rd_proto::control::Control::Hello { token: Some(token), .. } = hello else {
        return Err("the viewer's hello carries no session token");
    };
    // Constant time (subtle), so timing does not leak the secret. A length
    // mismatch returns early; the length (64 hex characters) is public.
    use subtle::ConstantTimeEq;
    if bool::from(secret.as_bytes().ct_eq(token.0.as_bytes())) {
        Ok(())
    } else {
        Err("the viewer's session token is not the host's secret")
    }
}

/// `--listen` must be a loopback address: a host never serves other machines.
pub fn loopback_only(addr: SocketAddr) -> Result<SocketAddr, &'static str> {
    if addr.ip().is_loopback() { Ok(addr) } else { Err("--listen must be a loopback address") }
}
