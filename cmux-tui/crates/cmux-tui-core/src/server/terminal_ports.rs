//! `terminal-ports`: the dev-server ports a terminal shows, confirmed by a
//! loopback connect (plans/cmux-next/workspace-proxy-DESIGN.md section 6).
//!
//! No process scanning (plans/cmux-next/pty-holder.md section 4): the daemon
//! reads only the PTY it holds and connects to its own loopback. A server
//! prints where it listens (`http://localhost:5173/`, `127.0.0.1:8000`), and
//! the text reaches this terminal even from a tmux pane, because tmux draws
//! its panes into the client's PTY. Each port named on loopback or a wildcard
//! address is then probed with a TCP connect to 127.0.0.1 and ::1: only a port
//! that accepts is reported. A program that prints nothing is not found; an
//! OSC 7501 report is the follow-up for those.
//!
//! The text is the active screen with its scrollback, cut to the last
//! [`MAX_SCAN_BYTES`], read once per request. Nothing is cached or polled.

use std::net::{Ipv6Addr, SocketAddr, TcpStream};
use std::sync::LazyLock;
use std::time::Duration;

use regex::Regex;

use super::*;

/// The tail of the terminal text that is scanned.
pub(crate) const MAX_SCAN_BYTES: usize = 1 << 20;
/// Distinct ports probed per request, most recently printed first.
pub(crate) const MAX_CANDIDATES: usize = 32;
const PROBE_TIMEOUT: Duration = Duration::from_millis(150);

/// A port the terminal text names on a loopback or wildcard host.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Candidate {
    pub port: u16,
    /// The host as printed: `localhost`, `127.0.0.1`, `0.0.0.0`, `[::1]`...
    pub host: String,
    /// The printed URL, or `http://<host>:<port>/` when the text had no scheme.
    pub url: String,
}

static ADDRESS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(?P<scheme>https?://)?(?P<host>localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1?\]|\[::ffff:127(?:\.\d{1,3}){3}\]|\*):(?P<port>\d{1,5})\b(?P<path>/[^\s'\x22<>()\[\],]*)?",
    )
    .expect("static regex") // crash-allow: constant pattern
});

/// Ports named in `text` on a loopback or wildcard host, the last printed
/// first, each port once, at most [`MAX_CANDIDATES`].
pub(crate) fn candidates(text: &str) -> Vec<Candidate> {
    let mut found: Vec<Candidate> = Vec::new();
    for capture in ADDRESS.captures_iter(text) {
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
pub(crate) fn tail(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut start = text.len() - max;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

/// The loopback address that accepts a TCP connect on `port`, if any.
pub(crate) fn probe(port: u16) -> Option<&'static str> {
    let v4 = SocketAddr::from(([127, 0, 0, 1], port));
    if TcpStream::connect_timeout(&v4, PROBE_TIMEOUT).is_ok() {
        return Some("127.0.0.1");
    }
    let v6 = SocketAddr::from((Ipv6Addr::LOCALHOST, port));
    TcpStream::connect_timeout(&v6, PROBE_TIMEOUT).is_ok().then_some("::1")
}

pub(crate) fn report_json(
    surface: SurfaceId,
    candidates: &[Candidate],
    mut probe: impl FnMut(u16) -> Option<&'static str>,
) -> Value {
    let mut listeners = Vec::new();
    let mut closed = Vec::new();
    for candidate in candidates {
        match probe(candidate.port) {
            Some(bound) => listeners.push(json!({
                "port": candidate.port,
                "host": candidate.host,
                "url": candidate.url,
                "bound": bound,
            })),
            None => closed.push(candidate.port),
        }
    }
    json!({"surface": surface, "listeners": listeners, "closed": closed})
}

pub(super) fn terminal_ports(mux: &Arc<Mux>, surface_id: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface_id)?;
    require_pty(&surface)?;
    let text = surface.try_with_terminal(|terminal| terminal.plain_text())??;
    drop(surface);
    let candidates = candidates(tail(&text, MAX_SCAN_BYTES));
    Ok(report_json(surface_id, &candidates, probe))
}

#[cfg(test)]
#[path = "terminal_ports_tests.rs"]
mod tests;
