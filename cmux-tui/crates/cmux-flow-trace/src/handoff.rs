//! The echo's thread handoffs on the Rust side (plans/cmux-next/chrome-parity/p09-observability.md,
//! task 102; ghostty-integration-DESIGN.md "Key to frame").
//!
//! Each handoff is named by the thread that queues the echo's item: [`queued`] on that thread when it
//! hands the item on (a flow out, `s`), [`taken`] on the next thread when it picks the item up (a flow
//! in, `f`), both with arg1 the press's flow id. The queue item itself carries that id, as Chrome's
//! `PendingTask` carries the id that `TaskAnnotator::WillQueueTask` writes as a flow out and
//! `TaskAnnotator::RunTask` as a flow in (base/task/common/task_annotator.cc). An item no press waits
//! for carries flow 0 and writes nothing. The app writes the handoffs after line-out.

use cmux_trace::{Phase, category};

use super::{id_key, on, terminal_key};

/// One of the echo's thread handoffs that a Rust thread queues or takes, as its `key.echo.*` catalog
/// name (frozen by p09-observability-000).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handoff {
    /// `key.echo.host_pty_read`: the host's PTY thread published its read; a client writer takes it.
    HostPtyRead,
    /// `key.echo.host_client_write`: the host's client writer writes the frame; the daemon's frames
    /// thread reads it.
    HostClientWrite,
    /// `key.echo.daemon_frames`: the daemon's frames thread queued the frame; the surface's reader
    /// takes it.
    DaemonFrames,
    /// `key.echo.surface_parse`: the surface's reader parsed the output and queued it to the attach
    /// viewers; a viewer's attach-out thread takes it.
    SurfaceParse,
    /// `key.echo.attach_encode`: the attach-out thread encoded the event and queued it on its
    /// connection; the connection's line-out thread takes it.
    AttachEncode,
    /// `key.echo.line_out`: the line-out thread writes the event; the app's transport reader reads it.
    LineOut,
}

impl Handoff {
    /// Every Rust handoff, in the echo's order.
    pub const ALL: [Handoff; 6] = [
        Handoff::HostPtyRead,
        Handoff::HostClientWrite,
        Handoff::DaemonFrames,
        Handoff::SurfaceParse,
        Handoff::AttachEncode,
        Handoff::LineOut,
    ];

    /// The handoff's catalog name.
    pub const fn text(self) -> &'static str {
        match self {
            Handoff::HostPtyRead => "key.echo.host_pty_read",
            Handoff::HostClientWrite => "key.echo.host_client_write",
            Handoff::DaemonFrames => "key.echo.daemon_frames",
            Handoff::SurfaceParse => "key.echo.surface_parse",
            Handoff::AttachEncode => "key.echo.attach_encode",
            Handoff::LineOut => "key.echo.line_out",
        }
    }

    /// The handoff's catalog id, resolved when the crate builds.
    const fn catalog_id(self) -> u16 {
        HANDOFF_IDS[self as usize]
    }
}

/// [`Handoff::ALL`]'s catalog ids, in their order; the build fails when one is not a catalog name.
const HANDOFF_IDS: [u16; 6] = {
    let mut ids = [0u16; 6];
    let mut index = 0;
    while index < Handoff::ALL.len() {
        let handoff = Handoff::ALL[index];
        assert!(handoff as usize == index, "Handoff::ALL is not in declaration order");
        let id = cmux_trace::names::catalog_id(handoff.text());
        assert!(id != 0, "a handoff is not a catalog name");
        ids[index] = id;
        index += 1;
    }
    ids
};

/// The terminal a handoff record names in arg0 (its terminal key), turned into the key only when the
/// record is written.
#[derive(Clone, Copy, Debug)]
pub enum Terminal<'a> {
    /// A lowercase hex terminal id (the daemon).
    Hex(&'a str),
    /// The 16 raw id bytes (the terminal host).
    Id(&'a [u8; 16]),
    /// A thread whose queue does not know its terminal: arg0 0. The flow id names the press.
    Unknown,
}

impl Terminal<'_> {
    fn key(self) -> u64 {
        match self {
            Terminal::Hex(hex) => terminal_key(hex.as_bytes()),
            Terminal::Id(id) => id_key(id),
            Terminal::Unknown => 0,
        }
    }
}

/// The calling thread queued key press `flow`'s item for `handoff`'s next thread: the flow out. Nothing
/// for flow 0; off, at most one relaxed load. No allocation, lock or system call.
#[inline]
pub fn queued(handoff: Handoff, flow: u64, terminal: Terminal<'_>) {
    if flow != 0 && on() {
        write(handoff, Phase::FlowOut, flow, terminal);
    }
}

/// `handoff`'s next thread (the caller) took key press `flow`'s item: the flow in. Nothing for flow 0;
/// off, at most one relaxed load.
#[inline]
pub fn taken(handoff: Handoff, flow: u64, terminal: Terminal<'_>) {
    if flow != 0 && on() {
        write(handoff, Phase::FlowIn, flow, terminal);
    }
}

#[inline(never)]
fn write(handoff: Handoff, phase: Phase, flow: u64, terminal: Terminal<'_>) {
    cmux_trace::write(category::KEY, handoff.catalog_id(), phase, 0, terminal.key(), flow);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_handoff_has_its_own_catalog_name() {
        let mut seen = std::collections::HashSet::new();
        for handoff in Handoff::ALL {
            let id = handoff.catalog_id();
            let name = cmux_trace::names::catalog_name(id).expect("a catalog id");
            assert_eq!(name.text, handoff.text());
            assert!(seen.insert(id), "{} shares an id", handoff.text());
        }
    }

    #[test]
    fn a_terminal_key_is_the_hop_key() {
        let id: [u8; 16] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 9, 9, 9, 9, 9, 9, 9, 9];
        let hex = crate::hex(&id);
        assert_eq!(Terminal::Id(&id).key(), 0x0123_4567_89ab_cdef);
        assert_eq!(Terminal::Hex(&hex).key(), 0x0123_4567_89ab_cdef);
        assert_eq!(Terminal::Unknown.key(), 0);
    }
}
