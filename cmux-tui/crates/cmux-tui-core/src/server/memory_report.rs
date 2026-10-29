//! `memory-report`: where this daemon's memory goes, read
//! when the request arrives. Per PTY terminal: its scrollback pages, live and
//! compressed, its alternate screen, its Kitty images and the holder ring the
//! daemon keeps a copy of, or, for a cold terminal, the bytes its compressed
//! state holds (the report reads it without restoring it); then the memory
//! registry's consumers and level and the process's own footprint. The
//! daemon keeps no sampler, cache or timer for it, like Chrome's memory-infra
//! dump (`chrome://tracing` memory-infra,
//! base/trace_event/memory_dump_manager.cc), which asks each provider for its
//! size only when a dump is requested.
//!
//! Read only and owner only (`cmd_server::memory_report`): a WebSocket or
//! remote relay client is refused before anything is read (a remote relay
//! client is refused earlier by its frame gate, `remote_relay/gate.rs`, as
//! every command off its allowlist).
//! The reply names no title, path, URL or command: terminals appear by
//! surface and terminal id only.

use super::*;
use crate::process_resources::{MemoryFootprint, own_memory_footprint};
use crate::surface::{PtyHome, SurfaceMemory, TerminalMemory};
use cmux_memory::{ConsumerReport, PressureLevel, Retention};
use ghostty_vt::ScreenMemory;

/// The reply's `schema`; a change to its shape bumps it.
pub(crate) const MEMORY_REPORT_SCHEMA: u32 = 1;

/// Why `memory-report` was refused.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum MemoryReportRefused {
    /// A WebSocket or remote relay client asked.
    NotLocal,
}

impl std::fmt::Display for MemoryReportRefused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::NotLocal => "memory report requires a trusted local connection",
        })
    }
}

impl std::error::Error for MemoryReportRefused {}

/// The report. The caller checked the client is the owner
/// (`cmd_server::memory_report`). No mux lock is held while a terminal is
/// measured.
pub(super) fn report(mux: &Mux) -> Value {
    let mut surfaces = mux.with_state(|state| {
        state
            .surfaces
            .iter()
            .filter(|(_, surface)| surface.kind() == SurfaceKind::Pty)
            .map(|(id, surface)| (*id, surface.clone()))
            .collect::<Vec<_>>()
    });
    surfaces.sort_by_key(|(id, _)| *id);
    let mut totals = Totals::default();
    let terminals = surfaces
        .iter()
        .filter_map(|(id, surface)| {
            let memory = surface.memory_usage()?;
            totals.add(&memory);
            let terminal_id = surface.terminal_public_id().map(|terminal| terminal.as_str());
            Some(terminal_json(*id, terminal_id, &memory))
        })
        .collect::<Vec<_>>();
    let registry = mux.memory.registry();
    let consumers = registry.report().iter().map(consumer_json).collect::<Vec<_>>();
    json!({
        "schema": MEMORY_REPORT_SCHEMA,
        "pid": std::process::id(),
        "process": own_memory_footprint().map(footprint_json),
        "pressure": pressure_name(registry.level()),
        "terminals": terminals,
        "totals": totals.json(),
        "consumers": consumers,
    })
}

/// Sums of the terminal fields; a terminal libghostty-vt could not measure
/// adds nothing.
#[derive(Default)]
struct Totals {
    terminals: u64,
    cold_terminals: u64,
    cold_held_bytes: u64,
    scrollback_live_bytes: u64,
    scrollback_compressed_bytes: u64,
    alternate_screen_bytes: u64,
    kitty_image_bytes: u64,
    holder_ring_bytes: u64,
}

impl Totals {
    fn add(&mut self, memory: &SurfaceMemory) {
        self.terminals += 1;
        match &memory.terminal {
            Some(TerminalMemory::Hot(usage)) => {
                self.scrollback_live_bytes += live_bytes(&usage.primary);
                self.scrollback_compressed_bytes += usage.primary.compressed_bytes;
                self.alternate_screen_bytes += usage.alternate.resident_bytes;
                self.kitty_image_bytes += usage.primary.image_bytes + usage.alternate.image_bytes;
            }
            Some(TerminalMemory::Cold { held_bytes, .. }) => {
                self.cold_terminals += 1;
                self.cold_held_bytes += held_bytes;
            }
            None => {}
        }
        if let PtyHome::Holder { ring_bytes: Some(bytes) } = memory.home {
            self.holder_ring_bytes += bytes;
        }
    }

    fn json(&self) -> Value {
        json!({
            "terminals": self.terminals,
            "cold_terminals": self.cold_terminals,
            "cold_held_bytes": self.cold_held_bytes,
            "scrollback_live_bytes": self.scrollback_live_bytes,
            "scrollback_compressed_bytes": self.scrollback_compressed_bytes,
            "alternate_screen_bytes": self.alternate_screen_bytes,
            "kitty_image_bytes": self.kitty_image_bytes,
            "holder_ring_bytes": self.holder_ring_bytes,
        })
    }
}

/// Physical bytes of the pages that are not compressed.
fn live_bytes(screen: &ScreenMemory) -> u64 {
    screen.resident_bytes.saturating_sub(screen.compressed_bytes)
}

fn terminal_json(surface: SurfaceId, terminal_id: Option<&str>, memory: &SurfaceMemory) -> Value {
    let (state, usage, cold) = match memory.terminal {
        Some(TerminalMemory::Hot(usage)) => ("hot", Some(usage), None),
        Some(TerminalMemory::Cold { held_bytes, snapshot_bytes }) => (
            "cold",
            None,
            Some(json!({ "held_bytes": held_bytes, "snapshot_bytes": snapshot_bytes })),
        ),
        None => ("unknown", None, None),
    };
    let ring_bytes = match memory.home {
        PtyHome::Holder { ring_bytes } => ring_bytes,
        PtyHome::Daemon | PtyHome::Host | PtyHome::Exited => None,
    };
    json!({
        "surface": surface,
        "terminal_id": terminal_id,
        "home": memory.home.as_str(),
        "state": state,
        "cold": cold,
        "scrollback": usage.map(|usage| json!({
            "live_bytes": live_bytes(&usage.primary),
            "compressed_bytes": usage.primary.compressed_bytes,
            "virtual_bytes": usage.primary.virtual_bytes,
            "pages": usage.primary.pages,
            "compressed_pages": usage.primary.compressed_pages,
        })),
        "compression_supported": usage.map(|usage| usage.compression_supported),
        "alternate_screen_bytes": usage.map(|usage| usage.alternate.resident_bytes),
        "kitty_image_bytes":
            usage.map(|usage| usage.primary.image_bytes + usage.alternate.image_bytes),
        "holder_ring_bytes": ring_bytes,
    })
}

fn consumer_json(consumer: &ConsumerReport) -> Value {
    json!({
        "name": consumer.name,
        "retention": match consumer.retention {
            Retention::Lossless => "lossless",
            Retention::Lossy => "lossy",
        },
        "bytes": consumer.bytes,
    })
}

fn footprint_json(footprint: MemoryFootprint) -> Value {
    json!({
        "private_footprint_bytes": footprint.private_footprint_bytes,
        "resident_bytes": footprint.resident_bytes,
    })
}

fn pressure_name(level: PressureLevel) -> &'static str {
    match level {
        PressureLevel::Normal => "normal",
        PressureLevel::Warning => "warning",
        PressureLevel::Critical => "critical",
    }
}

#[cfg(test)]
#[path = "memory_report_tests.rs"]
mod tests;
