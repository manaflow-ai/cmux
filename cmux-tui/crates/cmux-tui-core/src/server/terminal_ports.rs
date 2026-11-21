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
//! The matching and the probe live in `cmux-local-url`.

use super::*;

// The URL matching and the probe are shared with acpmux's process previews.
pub(crate) use cmux_local_url::{Candidate, candidates, probe, tail};

/// The tail of the terminal text that is scanned.
pub(crate) const MAX_SCAN_BYTES: usize = 1 << 20;

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
