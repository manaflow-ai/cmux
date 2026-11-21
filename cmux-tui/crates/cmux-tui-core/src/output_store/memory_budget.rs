//! The total RAM budget for terminal scrollback
//! (`terminal.scrollback.maxTotalMemoryBytes`, default 256 MiB).
//!
//! Each terminal's own cap is Ghostty's `scrollback-limit` (cmux adds no key
//! for it). Past the total, the terminals that printed least recently give
//! back scrollback first: their Ghostty scrollback limit is lowered, which
//! drops their oldest pages at once. When the total falls well under the
//! budget again, the most recently active terminals get their configured
//! limit back (history that was dropped does not return; full mode still has
//! it in its segment files).
//!
//! The pass runs on the output store's writer thread, after output (memory
//! only grows when a terminal prints), so an idle session runs nothing. It
//! runs as soon as the measured total crosses the budget. Each PTY read
//! reports its terminal's history row count (O(1), `OutputStore::append`);
//! when the history moved by a step (`HistoryRows`), the writer wakes,
//! measures that terminal's resident bytes ([`measure_due`], a page walk on
//! the writer thread, never on the reader) and runs [`enforce`] when the
//! total is over the trigger. The writer's snapshot pass (every
//! `SNAPSHOT_INTERVAL`) also runs it, and gives limits back. Before P-AUSTIN
//! B8 only that 30 s pass ran it: 16 terminals at 1 MB/s with a 1 GB
//! `scrollback-limit` took the daemon to 2.25 GB against this 256 MiB budget
//! before the pass cut it back.
//!
//! Owner: the output store (PL-daemon). The bound is the budget, plus per
//! terminal the history grown since its last measurement (up to
//! max(1/16 of its measured history rows, one screen of rows)), plus what
//! prints during one pass on the writer thread. When every terminal is at
//! its 1 MiB floor the total can stay over it; the next pass then waits for
//! growth past where the last one left it. Not covered: the alternate
//! screen's pages (as before), terminals with no journal capture (they keep
//! no output log), and the terminal hosts' own copies (each capped at
//! `HostLaunch::host_scrollback`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use super::{OutputStore, TerminalLog};
use crate::Mux;
use crate::resource::TerminalPublicId;

/// `cmux-next.json` key: total scrollback RAM across terminals in bytes.
pub(crate) const MEMORY_TOTAL_SETTING: &str = "terminal.scrollback.maxTotalMemoryBytes";
/// Process override of the budget (tests). Bytes.
pub(super) const MEMORY_TOTAL_ENV: &str = "CMUX_TUI_TERMINAL_SCROLLBACK_MEMORY_BYTES";
pub(crate) const DEFAULT_MEMORY_TOTAL_BYTES: u64 = 256 * 1024 * 1024;
const MIN_MEMORY_TOTAL_BYTES: u64 = 16 * 1024 * 1024;
/// The least scrollback a shrunk terminal keeps.
const MIN_TERMINAL_SCROLLBACK_BYTES: usize = 1024 * 1024;
/// Limits are given back only below this share of the budget (no flapping).
const RESTORE_BELOW_PERCENT: u64 = 80;

/// Limits this budget set, by terminal: (configured limit, applied limit).
#[derive(Default)]
pub(super) struct MemoryBudget {
    limited: Mutex<HashMap<TerminalPublicId, (usize, usize)>>,
    /// The last pass left the total over the budget (its warning is printed
    /// once per episode, not once per pass).
    over: std::sync::atomic::AtomicBool,
}

impl MemoryBudget {
    pub(super) fn forget(&self, terminal_id: &TerminalPublicId) {
        self.limited.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
    }
}

/// One terminal's place in the pass.
struct Entry {
    log: Arc<TerminalLog>,
    surface: Arc<crate::Surface>,
    resident: u64,
    last_output: Instant,
}

/// The budget a setting of `budget` bytes enforces (it has a floor).
pub(super) fn effective(budget: u64) -> u64 {
    budget.max(MIN_MEMORY_TOTAL_BYTES)
}

/// Measure the terminals whose history grew by a step since their last
/// measurement (`OutputStore::append` marked them), then run [`enforce`]
/// when the total is over the trigger. On the writer thread.
pub(super) fn measure_due(mux: &Mux, store: &OutputStore, budget: u64) {
    let due: Vec<Arc<TerminalLog>> = store
        .logs
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .values()
        .filter(|log| {
            std::mem::take(
                &mut log.state.lock().unwrap_or_else(PoisonError::into_inner).measure_due,
            )
        })
        .cloned()
        .collect();
    for log in &due {
        let measured = mux
            .terminal_resource_surface(&log.terminal_id)
            .and_then(|surface| surface.try_with_terminal(measure).ok().flatten());
        let (resident, rows) = measured.unwrap_or((0, None));
        store.set_resident(log, resident, rows);
    }
    if store.resident_over_trigger() {
        enforce(mux, store, budget);
    }
}

/// A terminal's primary-screen resident bytes (0 when libghostty-vt cannot
/// report them) and its history rows (`None` on the alternate screen, which
/// keeps the last primary measurement's rows as the next step's base).
/// Returning the rows even when the bytes are unknown keeps such a terminal
/// from asking for a measurement on every read.
fn measure(terminal: &mut ghostty_vt::Terminal) -> Option<(u64, Option<u64>)> {
    let rows = crate::output_store::HistoryRows::of(terminal).map(|history| history.rows);
    Some((terminal.primary_resident_bytes().unwrap_or(0), rows))
}

/// Keep the terminals' scrollback RAM under `budget` bytes, then record the
/// next pass's trigger in the store.
pub(super) fn enforce(mux: &Mux, store: &OutputStore, budget: u64) {
    let budget = effective(budget);
    shrink_or_restore(mux, store, budget);
    // The store's total, not this pass's sum: output during the pass moved
    // it on, and the trigger must sit at what the store now counts.
    store.set_resident_trigger(store.resident_total().max(budget));
}

/// One pass: shrink the least recently active terminals past the budget,
/// or give limits back well under it. Returns the resident total after it.
fn shrink_or_restore(mux: &Mux, store: &OutputStore, budget: u64) -> u64 {
    let logs: Vec<Arc<TerminalLog>> =
        store.logs.lock().unwrap_or_else(PoisonError::into_inner).values().cloned().collect();
    // The pass measures every terminal, and the store's total restarts from
    // these values; a log it cannot measure (its terminal left, or Ghostty
    // cannot report) counts 0, so nothing stale stays in the total.
    let mut entries = logs
        .into_iter()
        .filter_map(|log| {
            // Cleared before the read: an append after it asks again.
            log.state.lock().unwrap_or_else(PoisonError::into_inner).measure_due = false;
            let measured = mux.terminal_resource_surface(&log.terminal_id).and_then(|surface| {
                let measured = surface.try_with_terminal(measure).ok().flatten()?;
                Some((surface, measured))
            });
            let Some((surface, (resident, rows))) = measured else {
                store.set_resident(&log, 0, None);
                return None;
            };
            store.set_resident(&log, resident, rows);
            let last_output = log.state.lock().unwrap_or_else(PoisonError::into_inner).last_output;
            Some(Entry { log, surface, resident, last_output })
        })
        .collect::<Vec<_>>();
    let mut total = entries.iter().map(|entry| entry.resident).sum::<u64>();
    // Ghostty's `scrollback-limit`, the per-terminal cap.
    let configured = mux.surface_options.lock().unwrap_or_else(PoisonError::into_inner).scrollback;
    let mut limited = store.memory_budget.limited.lock().unwrap_or_else(PoisonError::into_inner);
    if total > budget {
        // Least recently active first.
        entries.sort_by_key(|entry| entry.last_output);
        for entry in &entries {
            if total <= budget {
                break;
            }
            let excess = total - budget;
            let keep = usize::try_from(entry.resident.saturating_sub(excess))
                .unwrap_or(usize::MAX)
                .max(MIN_TERMINAL_SCROLLBACK_BYTES);
            let current =
                limited.get(&entry.log.terminal_id).map_or(configured, |(_, applied)| *applied);
            if keep >= current {
                continue;
            }
            let after = entry
                .surface
                .try_with_terminal(|terminal| {
                    terminal.set_scrollback_max_bytes(keep).ok()?;
                    measure(terminal)
                })
                .ok()
                .flatten();
            let Some((after, rows)) = after else { continue };
            total = total.saturating_sub(entry.resident.saturating_sub(after));
            store.set_resident(&entry.log, after, rows);
            limited.insert(entry.log.terminal_id.clone(), (configured, keep));
        }
        let over = total > budget;
        if over && !store.memory_budget.over.swap(true, std::sync::atomic::Ordering::AcqRel) {
            eprintln!(
                "cmux-tui: terminal scrollback uses {total} bytes, over the {budget} byte budget \
                 after shrinking idle terminals"
            );
        }
        if !over {
            store.memory_budget.over.store(false, std::sync::atomic::Ordering::Release);
        }
        return total;
    }
    store.memory_budget.over.store(false, std::sync::atomic::Ordering::Release);
    if limited.is_empty() || total * 100 >= budget * RESTORE_BELOW_PERCENT {
        return total;
    }
    // Room again: the most recently active terminals get their limit back
    // while the room lasts (a limit only bounds growth).
    entries.sort_by_key(|entry| std::cmp::Reverse(entry.last_output));
    let mut room = budget * RESTORE_BELOW_PERCENT / 100 - total;
    for entry in &entries {
        let Some((configured, applied)) = limited.get(&entry.log.terminal_id).copied() else {
            continue;
        };
        let growth = u64::try_from(configured.saturating_sub(applied)).unwrap_or(u64::MAX);
        let restored =
            if growth <= room { configured } else { applied + usize::try_from(room).unwrap_or(0) };
        if entry
            .surface
            .try_with_terminal(|terminal| terminal.set_scrollback_max_bytes(restored).is_ok())
            .unwrap_or(false)
        {
            room = room.saturating_sub(
                u64::try_from(restored.saturating_sub(applied)).unwrap_or(u64::MAX),
            );
            if restored == configured {
                limited.remove(&entry.log.terminal_id);
            } else {
                limited.insert(entry.log.terminal_id.clone(), (configured, restored));
            }
        }
        if room == 0 {
            break;
        }
    }
    total
}
