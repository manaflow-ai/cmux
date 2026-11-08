//! The loopback URLs a dev server prints, and the TCP connect that confirms
//! one listens (plans/cmux-next/workspace-proxy-DESIGN.md section 6).
//!
//! No process scanning (plans/cmux-next/pty-holder.md section 4): a server
//! prints where it listens (`http://localhost:5173/`, `127.0.0.1:8000`), and
//! [`candidates`] finds each port named on a loopback or wildcard host in that
//! text. [`probe`] then connects to 127.0.0.1 and ::1: only a port that
//! accepts is a server. The daemon's `terminal-ports` reads a terminal's text
//! this way (cmux-tui-core), and acpmux a background process's output file.

use std::borrow::Cow;
use std::net::{Ipv6Addr, SocketAddr, TcpStream};
use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;

/// Distinct ports [`candidates`] returns, most recently printed first.
pub const MAX_CANDIDATES: usize = 32;
const PROBE_TIMEOUT: Duration = Duration::from_millis(150);

/// A port the text names on a loopback or wildcard host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub port: u16,
    /// The host as printed: `localhost`, `127.0.0.1`, `0.0.0.0`, `[::1]`...
    pub host: String,
    /// The printed URL, or `http://<host>:<port>/` when the text had no scheme.
    pub url: String,
}

/// The address pattern: a constant that compiles (`terminal_ports_tests.rs` match with it), so a
/// failure only means no candidates, never a panic.
static ADDRESS: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(?P<scheme>https?://)?(?P<host>localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1?\]|\[::ffff:127(?:\.\d{1,3}){3}\]|\*):(?P<port>\d{1,5})\b(?P<path>/[^\s'\x22<>()\[\],]*)?",
    )
    .ok()
});

/// Ports named in `text` on a loopback or wildcard host, the last printed
/// first, each port once, at most [`MAX_CANDIDATES`]. `text` is plain: pass
/// a program's raw output through [`strip_ansi`] first.
pub fn candidates(text: &str) -> Vec<Candidate> {
    let Some(address) = ADDRESS.as_ref() else {
        return Vec::new();
    };
    let mut found: Vec<Candidate> = Vec::new();
    for capture in address.captures_iter(text) {
        let Ok(port) = capture["port"].parse::<u16>() else {
            continue;
        };
        if port == 0 {
            continue;
        }
        let host = capture["host"].to_ascii_lowercase();
        let scheme = capture.name("scheme").map_or("http://", |m| m.as_str());
        let path = capture.name("path").map_or("/", |m| m.as_str());
        let url_host = if host == "*" { "localhost" } else { host.as_str() };
        let url = format!("{}{url_host}:{port}{path}", scheme.to_ascii_lowercase());
        found.retain(|candidate| candidate.port != port);
        found.push(Candidate { port, host, url });
    }
    found.reverse();
    found.truncate(MAX_CANDIDATES);
    found
}

/// The tail of `text` that is at most `max` bytes, cut on a char boundary.
pub fn tail(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    text.get(start..).unwrap_or_default()
}

/// `text` without its terminal escapes: CSI sequences (colors, `ESC [ 1 m`),
/// OSC sequences (titles, links; ended by BEL or `ESC \`) and other
/// two-byte escapes. Vite prints `localhost:\x1b[1m5173\x1b[22m/`, which only
/// matches once its color codes are gone. An escape cut off at the end of
/// `text` is dropped.
pub fn strip_ansi(text: &str) -> Cow<'_, str> {
    if !text.contains('\x1b') {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match chars.next() {
            // CSI: parameter and intermediate bytes, then one final byte in @..~.
            Some('[') => {
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            // OSC: up to BEL or ST (`ESC \`).
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\x07' {
                        break;
                    }
                    if c == '\x1b' {
                        if chars.peek() == Some(&'\\') {
                            chars.next();
                        }
                        break;
                    }
                }
            }
            // Any other escape is two bytes.
            _ => {}
        }
    }
    Cow::Owned(out)
}

/// The loopback address that accepts a TCP connect on `port`, if any. It
/// blocks for up to 300 ms: call it off an async runtime's threads.
pub fn probe(port: u16) -> Option<&'static str> {
    let v4 = SocketAddr::from(([127, 0, 0, 1], port));
    if TcpStream::connect_timeout(&v4, PROBE_TIMEOUT).is_ok() {
        return Some("127.0.0.1");
    }
    let v6 = SocketAddr::from((Ipv6Addr::LOCALHOST, port));
    TcpStream::connect_timeout(&v6, PROBE_TIMEOUT).is_ok().then_some("::1")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_ansi_removes_color_and_title_escapes() {
        let vite = "  \x1b[32m➜\x1b[39m  \x1b[1mLocal\x1b[22m:   \x1b[36mhttp://localhost:\x1b[1m5173\x1b[22m/\x1b[39m";
        assert_eq!(strip_ansi(vite), "  ➜  Local:   http://localhost:5173/");
        assert_eq!(strip_ansi("\x1b]0;title\x07a\x1b]8;;x\x1b\\b\x1b=c"), "abc");
        assert_eq!(strip_ansi("cut \x1b[1"), "cut ");
        assert!(matches!(strip_ansi("plain"), Cow::Borrowed("plain")));
    }
}
