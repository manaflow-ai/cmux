//! The ports a workspace's hover card offers to open: one link per port its
//! status entry `ports` names (":3000, :5173", which each machine's daemon
//! writes for the dev servers its terminals show, `terminal_port_watch.rs` in
//! cmux-tui-core, or a hook's `cmux workspace status set ports ...`).
//!
//! A click on a link opens `http://localhost:PORT/` in a browser tab of that
//! workspace (`workspace.open_url` on the workspace's own daemon). A workspace
//! on another machine needs no other address: a browser tab there reaches that
//! machine's localhost through the Remote carrier (`loopback-forward-v1`), so
//! the link is the same on every machine.
//!
//! The rule lives here; the app draws the links and sends the click. It
//! reaches this once per card show through `cmux_layout_reducer_json`
//! (`workspace_port_links`), never per frame or pointer move.

use serde::{Deserialize, Serialize};

/// A card lists at most this many ports; a longer entry still reads whole in
/// the row's own `ports` element.
pub const MAX_LINKS: usize = 6;

/// One `workspace_port_links` call.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    /// The workspace's `ports` status entry, as written.
    pub ports: String,
}

/// One port the card offers to open.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortLink {
    pub port: u16,
    /// What the link reads ("localhost:5173").
    pub label: String,
    /// What it opens ("http://localhost:5173/").
    pub url: String,
}

/// The links for `ports`, in the entry's order, each port once, at most
/// [`MAX_LINKS`]. An entry with any part that names no loopback port (a word,
/// a port out of range, another host's address) gets none: it is a hook's
/// own words ("3 dev servers", "web :3000"), which the card shows as written.
pub fn links(ports: &str) -> Vec<PortLink> {
    let mut seen = Vec::new();
    for part in ports.split(|c: char| c == ',' || c.is_whitespace()).filter(|p| !p.is_empty()) {
        let Some(port) = loopback_port(part) else { return Vec::new() };
        if !seen.contains(&port) {
            seen.push(port);
        }
    }
    seen.truncate(MAX_LINKS);
    seen.into_iter()
        .map(|port| PortLink {
            port,
            label: format!("localhost:{port}"),
            url: format!("http://localhost:{port}/"),
        })
        .collect()
}

/// The answer to one call.
pub fn respond(request: &Request) -> Vec<PortLink> {
    links(&request.ports)
}

/// The port one part names: ":5173", "5173", or a loopback address with a
/// port ("localhost:5173", "127.0.0.1:5173", "[::1]:5173", "0.0.0.0:5173"),
/// with or without `http://` and a trailing slash.
fn loopback_port(part: &str) -> Option<u16> {
    let part = part.trim();
    let part = part
        .strip_prefix("http://")
        .or_else(|| part.strip_prefix("https://"))
        .unwrap_or(part)
        .trim_end_matches('/');
    let (host, port) = match part.rsplit_once(':') {
        Some((host, port)) => (host, port),
        None => ("", part),
    };
    if !is_loopback(host) || port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    port.parse::<u16>().ok().filter(|port| *port != 0)
}

/// No host (":5173" names this workspace's machine) or a loopback one.
fn is_loopback(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host.is_empty()
        || host == "localhost"
        || host.ends_with(".localhost")
        || host == "[::1]"
        || host == "0.0.0.0"
        || host.strip_prefix("127.").is_some_and(|rest| {
            let octets: Vec<&str> = rest.split('.').collect();
            octets.len() == 3 && octets.iter().all(|o| o.parse::<u8>().is_ok())
        })
}

#[cfg(test)]
#[path = "workspace_port_links_tests.rs"]
mod tests;
