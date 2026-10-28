//! `server-stats` `memory` (diagnostics/daemon_memory.rs): each owner read
//! under its own lock, one at a time, when the request arrives. No read
//! takes the workspace registry lock, and none holds a lock while it reads
//! another owner.
//!
//! - Terminals: the mux state lock while the PTY surface handles are cloned
//!   (the list `memory-report` reads, server/memory_report.rs); then, per
//!   terminal, its runtime lock for its home and its terminal lock for
//!   libghostty-vt's memory-usage read and its scrollback row count
//!   (`Surface::memory_usage`), the same reads `memory-report` makes.
//! - Output store: its logs map lock while the log handles are cloned, then
//!   each log's lock for its buffer lengths (`OutputStore::memory`).
//! - Journal ring: the fanout lock for two loads
//!   (`JournalKernel::ring_memory`).
//! - Outbound: the client registry lock while the connection writers'
//!   render services are cloned; then atomic loads of their byte budgets,
//!   and each graphic cache's lock for two loads.

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use super::Mux;
use super::memory_report::pty_surfaces;
use super::render_service::RenderService;
use crate::diagnostics::{MemorySnapshot, OutboundMemory, TerminalMemorySection};
use crate::panic_free::RecoverPoison;

/// The `memory` section.
pub(super) fn memory(mux: &Mux) -> MemorySnapshot {
    MemorySnapshot {
        terminals: terminals(mux),
        output_store: mux.output_store.memory(),
        journal_ring: mux.shared_journal_handle().ring_memory(),
        outbound: outbound(mux),
    }
}

fn terminals(mux: &Mux) -> TerminalMemorySection {
    let mut section = TerminalMemorySection::default();
    for (id, surface) in pty_surfaces(mux) {
        let Some(memory) = surface.memory_usage() else { continue };
        let terminal_id = surface.terminal_public_id().map(|terminal| terminal.as_str());
        section.add(id, terminal_id, &memory);
    }
    section
}

fn outbound(mux: &Mux) -> OutboundMemory {
    let (connections, services) = {
        let state = mux.control_clients.state.lock().recover_poison();
        let services: Vec<Arc<RenderService>> =
            state.clients.values().map(|record| record.writer.render_service.clone()).collect();
        (state.clients.len(), services)
    };
    let mut seen = HashSet::new();
    let mut memory = OutboundMemory { connections: connections as u64, ..Default::default() };
    for service in services {
        if !seen.insert(Arc::as_ptr(&service)) {
            continue;
        }
        memory.budgets += 1;
        memory.retained_bytes +=
            service.outbound_budget.retained_bytes.load(Ordering::Relaxed) as u64;
        memory.control_retained_bytes +=
            service.control_budget.retained_bytes.load(Ordering::Relaxed) as u64;
        let cache = service.graphic_base64.lock().recover_poison();
        memory.graphic_cache_entries += cache.entries.len() as u64;
        memory.graphic_cache_bytes += cache.retained_bytes as u64;
    }
    memory
}
