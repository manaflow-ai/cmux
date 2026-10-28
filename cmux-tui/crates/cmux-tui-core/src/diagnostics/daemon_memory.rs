//! The `memory` section of `server-stats`: the daemon's own large in-memory
//! owners, as byte and item counts, so a footprint that grows over a soak
//! points at the owner that holds it. Each number comes from a length,
//! capacity or counter its owner already keeps, read when the request
//! arrives (server/memory_stats.rs, which says how long each read holds
//! which lock); the daemon keeps no sampler or timer for it.
//!
//! Measured: the daemon's libghostty-vt terminals (pages, Kitty images,
//! cold state, holder ring copies, scrollback rows), the output store's
//! per-terminal buffers, the journal kernel's decoded record ring, and the
//! encoded outbound text the listeners' byte budgets count.
//!
//! Not measured, because the owner keeps no byte count and a walk would cost
//! more than this diagnostic may: the workspace registry's resource store and
//! presentation snapshot (parsed resource documents), the journal writer's
//! queues (their item counts are `journal_writer.terminal_queued` and
//! `durable_queued`; their bytes are not kept), each connection's queue
//! bookkeeping beyond the encoded text, the agent records, presence,
//! notification ledger and posts, closed-history, sidebar and agent inventory
//! caches, the conversation store, the history search index, SQLite page
//! caches, thread stacks, and allocator overhead. The process footprint is in
//! `memory-report`; `server-stats` makes no system call for it.

use ghostty_vt::ScreenMemory;
use serde::Serialize;

use crate::surface::{SurfaceMemory, TerminalMemory};

/// How many terminals `terminals.top` lists, largest first.
pub const MEMORY_TOP_TERMINALS: usize = 5;

/// The `memory` section of `server-stats`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct MemorySnapshot {
    pub terminals: TerminalMemorySection,
    pub output_store: OutputStoreMemory,
    pub journal_ring: JournalRingMemory,
    pub outbound: OutboundMemory,
}

/// Sums over the daemon's PTY terminals; `memory-report` reports the same
/// sums as its `totals`. A terminal libghostty-vt could not measure adds
/// only to `terminals` (and `holder_ring_bytes`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct TerminalMemoryTotals {
    pub terminals: u64,
    pub cold_terminals: u64,
    /// A cold terminal's compressed snapshot and Kitty replay.
    pub cold_held_bytes: u64,
    /// The primary screen's pages that are not compressed.
    pub scrollback_live_bytes: u64,
    /// The primary screen's compressed pages, at their compressed size.
    pub scrollback_compressed_bytes: u64,
    pub alternate_screen_bytes: u64,
    pub kitty_image_bytes: u64,
    /// The holder ring segments the daemon keeps a copy of.
    pub holder_ring_bytes: u64,
}

impl TerminalMemoryTotals {
    pub(crate) fn add(&mut self, memory: &SurfaceMemory) {
        self.terminals += 1;
        match &memory.terminal {
            Some(TerminalMemory::Hot { usage, .. }) => {
                self.scrollback_live_bytes += live_page_bytes(&usage.primary);
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
        self.holder_ring_bytes += memory.ring_bytes();
    }
}

/// Physical bytes of the pages that are not compressed.
pub(crate) fn live_page_bytes(screen: &ScreenMemory) -> u64 {
    screen.resident_bytes.saturating_sub(screen.compressed_bytes)
}

/// `memory.terminals`: the sums, the terminals that could not be read, the
/// scrollback rows of the hot ones, and the largest terminals.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct TerminalMemorySection {
    #[serde(flatten)]
    pub totals: TerminalMemoryTotals,
    /// PTY terminals whose terminal was moving between hot and cold, or that
    /// libghostty-vt could not report; counted in `terminals` only.
    pub unmeasured: u64,
    /// Scrollback rows above the viewport of the hot terminals, on each
    /// terminal's active screen: a terminal on its alternate screen counts
    /// about 0 here while its primary history stays in `bytes`. A cold
    /// terminal's rows are inside its compressed snapshot and are not read.
    pub scrollback_rows: u64,
    /// Every byte the daemon holds for its terminals: the sum of the rows'
    /// `bytes`, which is the sum of the byte fields above.
    pub bytes: u64,
    /// The [`MEMORY_TOP_TERMINALS`] terminals that hold the most, largest
    /// first (ties by surface id).
    pub top: Vec<TerminalMemoryRow>,
}

/// One terminal of `memory.terminals.top`. Like `memory-report`, it names
/// the terminal by surface and terminal id only.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct TerminalMemoryRow {
    pub surface: u64,
    pub terminal_id: Option<String>,
    /// `hot`, `cold`, or `unknown` (moving between them, or unreadable).
    pub state: &'static str,
    /// Its pages of both screens and Kitty images (hot), or its compressed
    /// state (cold), plus its holder ring copy.
    pub bytes: u64,
    /// Scrollback rows above the viewport of the active screen (about 0 on
    /// the alternate screen); `None` unless hot.
    pub scrollback_rows: Option<u64>,
}

impl TerminalMemorySection {
    /// Adds one PTY surface's memory.
    pub(crate) fn add(&mut self, surface: u64, terminal_id: Option<&str>, memory: &SurfaceMemory) {
        self.totals.add(memory);
        let (state, scrollback_rows) = match memory.terminal {
            Some(TerminalMemory::Hot { scrollback_rows, .. }) => ("hot", Some(scrollback_rows)),
            Some(TerminalMemory::Cold { .. }) => ("cold", None),
            None => ("unknown", None),
        };
        if memory.terminal.is_none() {
            self.unmeasured += 1;
        }
        self.scrollback_rows = self.scrollback_rows.saturating_add(scrollback_rows.unwrap_or(0));
        let bytes = memory.bytes();
        self.bytes = self.bytes.saturating_add(bytes);
        self.top.push(TerminalMemoryRow {
            surface,
            terminal_id: terminal_id.map(str::to_owned),
            state,
            bytes,
            scrollback_rows,
        });
        self.top.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.surface.cmp(&b.surface)));
        self.top.truncate(MEMORY_TOP_TERMINALS);
    }
}

/// `memory.output_store`: the terminal output store's in-memory buffers
/// (output_store.rs).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct OutputStoreMemory {
    /// Per-terminal logs: one for each terminal that printed since the
    /// store started, until the terminal is forgotten.
    pub logs: u64,
    /// Raw output kept for `terminal.output_read`, at most 64 KiB a log.
    pub tail_bytes: u64,
    /// Full persistence mode: output not yet in a segment file.
    pub pending_bytes: u64,
    /// The allocated capacity of those two buffers, at least their sum;
    /// each log's own bookkeeping is not counted.
    pub capacity_estimate_bytes: u64,
}

/// `memory.journal_ring`: the journal kernel's ring of decoded records that
/// live subscribers share (journal_kernel.rs).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct JournalRingMemory {
    pub records: u64,
    pub max_records: u64,
    /// The ring's own budget: per record, the decoded record plus an upper
    /// bound of its wire and search encodings, built or not.
    pub resident_estimate_bytes: u64,
    /// The budget past which the ring drops its oldest records.
    pub max_estimate_bytes: u64,
}

/// `memory.outbound`: encoded text on its way to clients. Every connection
/// writer shares its listener's render service, whose byte budgets count
/// each encoded message at its allocated capacity from encode until the
/// last copy (queued, or in a write) drops.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct OutboundMemory {
    /// Registered client connections.
    pub connections: u64,
    /// The distinct render services those connections share (one per
    /// listener). A listener with no registered connection is not seen.
    pub budgets: u64,
    /// Events, stream items and attach frames.
    pub retained_bytes: u64,
    /// Replies and stream terminals (the control reserve).
    pub control_retained_bytes: u64,
    /// The render graphic base64 caches: entries and encoded bytes.
    pub graphic_cache_entries: u64,
    pub graphic_cache_bytes: u64,
}
