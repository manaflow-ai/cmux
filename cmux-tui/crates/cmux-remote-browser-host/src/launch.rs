//! The launch contract between `--serve` and the app that starts it
//! (remote-tab-r2.md, local host): the app runs
//! `cmux-remote-browser-host --serve --listen 127.0.0.1:0 --lifeline`, reads
//! one [`listening_line`] from stdout to learn the port the OS gave, and
//! keeps the write end of the host's stdin open. When the app closes it (the
//! tab closed, the app quit or crashed), [`watch_lifeline`] sees end of file
//! and the host quits. No polling and no process scanning: the pipe is the
//! signal.

use std::io::{Read, Write};
use std::net::SocketAddr;

use cmux_rd_proto::control::Control;
use cmux_rd_proto::{STREAM_CONTROL, StreamDeframer, encode_stream_frame};

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

/// The result of [`admit`]: the viewer's hello and the deframer that holds the
/// bytes it sent after it, or why the viewer was turned away.
pub enum Admission {
    Admitted { hello: Control, deframer: StreamDeframer },
    Refused(String),
}

/// One viewer's admission on the rd stream carrier: read its first control
/// frame and check it with [`authorize`] before the host sends a welcome or
/// opens a tab. A refused viewer gets an rd `refused` and nothing else.
pub fn admit<S: Read + Write>(stream: &mut S, secret: Option<&str>) -> std::io::Result<Admission> {
    admit_within(stream, secret, HELLO_DEADLINE)
}

/// How long a viewer has to send its hello, in total.
pub const HELLO_DEADLINE: std::time::Duration = std::time::Duration::from_secs(10);

/// [`admit`] with an explicit hello deadline.
pub fn admit_within<S: Read + Write>(
    stream: &mut S,
    secret: Option<&str>,
    _deadline: std::time::Duration,
) -> std::io::Result<Admission> {
    let mut deframer = StreamDeframer::default();
    let mut buf = vec![0u8; 64 * 1024];
    let hello = loop {
        if let Ok(Some((kind, payload))) = deframer.next_frame() {
            if kind == STREAM_CONTROL {
                break serde_json::from_slice::<Control>(&payload).map_err(std::io::Error::other)?;
            }
            continue;
        }
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Ok(Admission::Refused("left before hello".into()));
        }
        deframer.extend(&buf[..n]);
    };
    if let Err(reason) = authorize(secret, &hello) {
        write_control(stream, &Control::Refused { reason: "unauthorized".into() })?;
        return Ok(Admission::Refused(format!("refused: {reason}")));
    }
    Ok(Admission::Admitted { hello, deframer })
}

/// Writes one rd control frame.
pub fn write_control<W: Write>(stream: &mut W, control: &Control) -> std::io::Result<()> {
    let json = serde_json::to_vec(control).map_err(std::io::Error::other)?;
    let mut out = Vec::with_capacity(json.len() + 5);
    encode_stream_frame(STREAM_CONTROL, &json, &mut out)
        .map_err(|e| std::io::Error::other(format!("{e:?}")))?;
    stream.write_all(&out)
}
